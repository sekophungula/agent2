import AppKit
import Foundation

/// Keeps Agent2 up to date from GitHub Releases: checks for a newer release,
/// downloads its Agent2-macOS.zip, swaps the app in place and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "sekophungula/agent2"
    static let asset = "Agent2-macOS.zip"
    static let bundleID = "za.co.shakatec.agent2"
    /// Releases are signed with the self-signed "Agent2 Code Signing (Shakatec)" certificate.
    static let requirement = #"identifier "za.co.shakatec.agent2" and certificate root = H"32f85530436c518c3575b88f6b6a7b1781b3f69d""#

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?

    /// Snapshot tool only: show a given state.
    func preview(_ s: State) { state = s }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var available: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    /// Check shortly after launch, then every six hours.
    func startAutomaticChecks() {
        guard Self.currentVersion != "dev" else { return }
        Task { try? await Task.sleep(for: .seconds(8)); if AppSettings.shared.autoUpdateCheck { await check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in if AppSettings.shared.autoUpdateCheck { await Updater.shared.check() } }
        }
    }

    // MARK: - Check

    func check() async {
        switch state { case .checking, .downloading, .installing: return; default: break }
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Agent2/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub didn't answer") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let zipString = assets.first(where: { $0["name"] as? String == Self.asset })?["browser_download_url"] as? String,
                  let zip = URL(string: zipString),
                  let page = URL(string: json["html_url"] as? String ?? "https://github.com/\(Self.repo)/releases/latest")
            else { throw UpdateError("The latest release has no download") }
            lastChecked = Date()
            if Self.isNewer(tag, than: Self.currentVersion) {
                state = .available(Release(version: tag, notes: json["body"] as? String ?? "", zip: zip, page: page))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed((error as? UpdateError)?.message ?? "Couldn't reach GitHub")
        }
    }

    /// Compares dotted versions numerically: 0.1.10 is newer than 0.1.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        guard !x.isEmpty, b != "dev" else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Install

    /// Where the running app lives, and whether it can be replaced in place.
    static var appURL: URL { Bundle.main.bundleURL }
    static var canReplaceInPlace: Bool {
        let path = appURL.path
        // Running from the disk image or from macOS's read-only "translocated" copy.
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") { return false }
        return FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    func install(_ release: Release, relaunch: Bool = true) async {
        guard Self.canReplaceInPlace else {
            state = .failed("Move Agent2 to Applications first, then update")
            return
        }
        do {
            state = .downloading(0)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("Agent2-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent(Self.asset)
            try await download(release.zip, to: zip)

            state = .installing
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("Agent2.app")
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            guard info["CFBundleIdentifier"] as? String == Self.bundleID else { throw UpdateError("The download isn't Agent2") }
            guard info["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError("The download has the wrong version") }
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
            // Once this copy is signed with the Agent2 certificate, only accept updates signed with it too.
            if (try? await Self.run("/usr/bin/codesign", ["--verify", "-R=\(Self.requirement)", Self.appURL.path])) != nil {
                do { try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "-R=\(Self.requirement)", newApp.path]) }
                catch { throw UpdateError("The download isn't signed by Agent2") }
            }

            try Self.swap(newApp: newApp, into: Self.appURL, work: work, relaunch: relaunch)
            if relaunch { NSApp.terminate(nil) } else { state = .upToDate }
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    /// A tiny script waits for Agent2 to quit, replaces the bundle (keeping the
    /// old one until the new one is in place) and opens the new version.
    private static func swap(newApp: URL, into target: URL, work: URL, relaunch: Bool) throws {
        let script = work.appendingPathComponent("swap.sh")
        let backup = target.deletingLastPathComponent().appendingPathComponent(".Agent2-previous.app")
        let pid = ProcessInfo.processInfo.processIdentifier
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = [
            "#!/bin/sh",
            relaunch ? "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done" : "",
            "rm -rf \(q(backup.path))",
            "mv \(q(target.path)) \(q(backup.path)) || exit 1",
            "if mv \(q(newApp.path)) \(q(target.path)); then rm -rf \(q(backup.path)); else mv \(q(backup.path)) \(q(target.path)); fi",
            "xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null",
        ]
        if relaunch { lines.append("open \(q(target.path))") }
        lines.append("rm -rf \(q(work.path))")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        if !relaunch { p.waitUntilExit() }
    }

    private func download(_ url: URL, to dest: URL) async throws {
        if url.isFileURL { return try FileManager.default.copyItem(at: url, to: dest) }  // dev testing only
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
        let total = max(resp.expectedContentLength, 1)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0, lastShown = 0.0
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                let p = Double(written) / Double(total)
                if p - lastShown > 0.02 { lastShown = p; state = .downloading(min(p, 1)) }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? c.resume() : c.resume(throwing: UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed"))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}

struct UpdateError: Error {
    let message: String
    init(_ m: String) { message = m }
}
