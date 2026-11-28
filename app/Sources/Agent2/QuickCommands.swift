import AppKit
import Foundation

/// Simple requests Agent2 carries out itself, at once, without asking an agent
/// (which takes several seconds even for "open Safari"): opening, quitting and
/// hiding apps, opening websites, and the volume.
///
/// Only a request that is *just* one of these is handled here. Anything more
/// ("open Safari and look up…", "open the file I made yesterday") goes to the
/// agent as usual, as does an app name that doesn't match an installed app.
@MainActor
enum QuickCommands {
    struct Action {
        let reply: String
        let run: () -> Bool
    }

    /// The action for `text`, if it's a quick command.
    static func match(_ text: String) -> Action? {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Politeness and wake words around the command.
        for p in ["hey agent2", "hey agent 2", "hey agent two", "agent2", "agent two", "okay", "ok", "please", "can you", "could you",
                  "would you", "will you", "go ahead and", "just", "quickly", "for me", "i want you to", "i'd like you to"] {
            s = s.replacingOccurrences(of: "^\(p)\\b,?\\s*", with: "", options: .regularExpression)
        }
        for p in ["please", "for me", "now", "right now", "thanks", "thank you"] {
            s = s.replacingOccurrences(of: ",?\\s*\\b\(p)$", with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !s.isEmpty, s.split(separator: " ").count <= 7 else { return nil }
        // More than one thing asked: leave it to the agent.
        if s.range(of: #"\b(and|then|after|also|but|with|to search|search for|look up|find|type|write)\b"#, options: .regularExpression) != nil
            && !s.hasPrefix("turn") { return nil }

        if let a = volume(s) { return a }
        if let name = strip(s, verbs: ["open up", "open", "launch", "start up", "start", "run", "bring up", "switch to", "go to", "show me", "show"]) {
            if let site = website(name) {
                return Action(reply: "Opening \(site.host ?? name).") { NSWorkspace.shared.open(site) }
            }
            if let app = AppIndex.find(name) {
                return Action(reply: "Opening \(app.name).") {
                    NSWorkspace.shared.openApplication(at: app.url, configuration: .init(), completionHandler: nil)
                    return true
                }
            }
            return nil
        }
        if let name = strip(s, verbs: ["quit", "close", "exit", "kill"]) {
            guard let (app, label) = running(name) else { return notOpen(name) }
            return Action(reply: "Closing \(label).") { app.terminate() }
        }
        if let name = strip(s, verbs: ["hide", "minimize", "minimise"]) {
            guard let (app, label) = running(name) else { return notOpen(name) }
            return Action(reply: "Hid \(label).") { app.hide() }
        }
        return nil
    }

    /// What follows one of `verbs` at the start of `s`, minus "the … app".
    private static func strip(_ s: String, verbs: [String]) -> String? {
        for v in verbs where s.hasPrefix(v + " ") {
            var rest = String(s.dropFirst(v.count + 1))
            rest = rest.replacingOccurrences(of: #"^(the|my|up)\s+"#, with: "", options: .regularExpression)
            rest = rest.replacingOccurrences(of: #"\s+(app|application|website|site|page|program)$"#, with: "", options: .regularExpression)
            rest = rest.trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: Websites

    private static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com", "google": "https://www.google.com",
        "google drive": "https://drive.google.com", "google docs": "https://docs.google.com", "google calendar": "https://calendar.google.com",
        "github": "https://github.com", "twitter": "https://x.com", "x": "https://x.com", "linkedin": "https://www.linkedin.com",
        "instagram": "https://www.instagram.com", "facebook": "https://www.facebook.com", "reddit": "https://www.reddit.com",
        "netflix": "https://www.netflix.com", "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "outlook": "https://outlook.live.com", "whatsapp web": "https://web.whatsapp.com", "tiktok": "https://www.tiktok.com",
        "amazon": "https://www.amazon.com", "wikipedia": "https://www.wikipedia.org", "spotify web": "https://open.spotify.com",
    ]

    private static func website(_ name: String) -> URL? {
        // An installed app wins over its website ("open Spotify", "open Claude").
        if AppIndex.find(name, exactOnly: true) != nil { return nil }
        if let u = sites[name] { return URL(string: u) }
        let bare = name.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " ", with: "")
        if bare.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://" + bare)
        }
        return nil
    }

    // MARK: Volume

    private static func volume(_ s: String) -> Action? {
        func set(_ script: String, _ reply: String) -> Action {
            Action(reply: reply) {
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                return err == nil
            }
        }
        if s.range(of: #"^(un ?mute|turn (the )?sound (back )?on)( the)?( sound| volume| audio)?$"#, options: .regularExpression) != nil {
            return set("set volume without output muted", "Sound on.")
        }
        if s.range(of: #"^(mute|silence|turn (the )?sound off)( the)?( sound| volume| audio| mac)?$"#, options: .regularExpression) != nil {
            return set("set volume with output muted", "Muted.")
        }
        if s.range(of: #"^(turn (it |the volume |the sound )?up|volume up|louder|increase (the )?volume)$"#, options: .regularExpression) != nil {
            return set("set volume output volume ((output volume of (get volume settings)) + 15) without output muted", "Louder.")
        }
        if s.range(of: #"^(turn (it |the volume |the sound )?down|volume down|quieter|softer|lower (the )?volume|decrease (the )?volume)$"#, options: .regularExpression) != nil {
            return set("set volume output volume ((output volume of (get volume settings)) - 15)", "Quieter.")
        }
        if let r = s.range(of: #"^(set )?(the )?volume (to )?(\d{1,3})( percent|%)?$"#, options: .regularExpression) {
            let n = min(100, Int(s[r].filter(\.isNumber)) ?? 50)
            return set("set volume output volume \(n) without output muted", "Volume \(n).")
        }
        return nil
    }

    // MARK: Running apps

    /// An installed app that isn't running: nothing to do, say so at once.
    private static func notOpen(_ name: String) -> Action? {
        guard let app = AppIndex.find(name) else { return nil }
        return Action(reply: "\(app.name) isn't open.") { true }
    }

    /// Lists the installed apps ahead of the first command.
    static func warmUp() { _ = AppIndex.find("finder") }

    private static func running(_ name: String) -> (NSRunningApplication, String)? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        let wanted = AppIndex.find(name)?.name.lowercased() ?? AppIndex.normalize(name)
        let hit = apps.first { AppIndex.normalize($0.localizedName ?? "") == wanted }
            ?? apps.first { AppIndex.normalize($0.localizedName ?? "") == AppIndex.normalize(name) }
        guard let hit else { return nil }
        return (hit, hit.localizedName ?? name)
    }
}

/// Installed apps by name, for quick commands.
@MainActor
enum AppIndex {
    struct App { let name: String; let url: URL }
    private static var apps: [App] = []
    private static var built = Date.distantPast

    /// What people call apps, mapped to their real names.
    private static let aliases: [String: String] = [
        "chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
        "settings": "system settings", "system preferences": "system settings", "preferences": "system settings",
        "app store": "app store", "word": "microsoft word", "excel": "microsoft excel", "powerpoint": "microsoft powerpoint",
        "outlook": "microsoft outlook", "teams": "microsoft teams", "calculator": "calculator", "terminal": "terminal",
        "files": "finder", "itunes": "music", "apple music": "music", "camera": "photo booth", "imessage": "messages",
        "texts": "messages", "text edit": "textedit", "quick time": "quicktime player", "quicktime": "quicktime player",
        "activity monitor": "activity monitor", "task manager": "activity monitor", "whatsapp": "whatsapp",
        "chat gpt": "chatgpt", "face time": "facetime",
    ]

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: ".app", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    static func find(_ spoken: String, exactOnly: Bool = false) -> App? {
        refreshIfStale()
        let q = normalize(spoken)
        guard !q.isEmpty else { return nil }
        let target = aliases[q] ?? q
        let byName = { (n: String) in apps.first { normalize($0.name) == n } }
        if let a = byName(target) { return a }
        // "Visual Studio Code" said as "visual studio code" without spaces, etc.
        let squashed = target.replacingOccurrences(of: " ", with: "")
        if let a = apps.first(where: { normalize($0.name).replacingOccurrences(of: " ", with: "") == squashed }) { return a }
        if exactOnly { return nil }
        // A unique app whose name starts with what was said ("photo" → Photos).
        let starts = apps.filter { normalize($0.name).hasPrefix(target) }
        if target.count >= 3, starts.count == 1 { return starts[0] }
        // Misheard by speech recognition by a letter or two ("safary").
        if target.count >= 5 {
            let close = apps.filter { distance(normalize($0.name), target) <= (target.count >= 8 ? 2 : 1) }
            if close.count == 1 { return close[0] }
        }
        return nil
    }

    private static func refreshIfStale() {
        guard Date().timeIntervalSince(built) > 120 else { return }
        built = Date()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var found: [String: App] = [:]
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    "\(home)/Applications", "/System/Library/CoreServices/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    found[name.lowercased()] = found[name.lowercased()] ?? App(name: name, url: url)
                } else if let sub = try? fm.contentsOfDirectory(atPath: url.path) {
                    // One level of folders (e.g. /Applications/Microsoft Office/…).
                    for s in sub where s.hasSuffix(".app") {
                        let u = url.appendingPathComponent(s)
                        let name = fm.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
                        found[name.lowercased()] = found[name.lowercased()] ?? App(name: name, url: u)
                    }
                }
            }
        }
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            found["finder"] = App(name: "Finder", url: finder)
        }
        apps = Array(found.values)
    }

    /// Edit distance between two short strings.
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > 2 { return 3 }
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
