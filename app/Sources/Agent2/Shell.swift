import Foundation

/// Runs command-line agents. GUI apps launch with a bare PATH, so we add the
/// places agent CLIs are usually installed.
enum Shell {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
                "\(home)/.cargo/bin", "\(home)/.opencode/bin", "\(home)/.volta/bin", "\(home)/Library/pnpm",
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }()

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (searchPaths + existing).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }

    static func which(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Result { let status: Int32; let stdout: String; let stderr: String }

    /// Run to completion, streaming stdout lines to `onLine`.
    static func run(_ executable: String, _ args: [String], cwd: String? = nil, stdin: String? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil,
                    cancel: CancelToken? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.environment = environment
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = inp

            let collector = OutputCollector(onLine: onLine)
            out.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
            err.fileHandleForReading.readabilityHandler = { h in collector.appendErr(h.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                collector.flush()
                cont.resume(returning: Result(status: proc.terminationStatus, stdout: collector.out, stderr: collector.err))
            }
            do {
                try p.run()
                cancel?.onCancel { if p.isRunning { p.terminate() } }
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data(), errData = Data(), lineBuf = Data()
    private let onLine: (@Sendable (String) -> Void)?
    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); outData.append(d); lineBuf.append(d)
        var lines: [String] = []
        while let nl = lineBuf.firstIndex(of: 0x0A) {
            lines.append(String(decoding: lineBuf[lineBuf.startIndex..<nl], as: UTF8.self))
            lineBuf.removeSubrange(lineBuf.startIndex...nl)
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }
    func appendErr(_ d: Data) { lock.lock(); errData.append(d); lock.unlock() }
    func flush() {
        lock.lock(); let rest = String(decoding: lineBuf, as: UTF8.self); lineBuf.removeAll(); lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }
    var out: String { lock.lock(); defer { lock.unlock() }; return String(decoding: outData, as: UTF8.self) }
    var err: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
}

/// Lets the UI stop a running agent.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [() -> Void] = []
    private(set) var isCancelled = false
    func onCancel(_ h: @escaping () -> Void) {
        lock.lock(); let c = isCancelled; if !c { handlers.append(h) }; lock.unlock()
        if c { h() }
    }
    func cancel() {
        lock.lock(); isCancelled = true; let hs = handlers; handlers = []; lock.unlock()
        hs.forEach { $0() }
    }
}
