import Foundation

struct Turn: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant, activity }
    var id = UUID()
    var role: Role
    var agent: String          // agent name that produced it ("You" for the user)
    var text: String
    var date = Date()
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = "New conversation"
    var started = Date()
    var turns: [Turn] = []
    var fileURL: URL?
}

/// Every conversation is a Markdown file on disk, owned by Agent2 and not by any
/// agent. Switching between Claude Code, Codex, an API key or another session
/// keeps the same history, because the history lives here.
enum HistoryStore {
    @MainActor static var folder: URL { URL(fileURLWithPath: (AppSettings.shared.historyFolder as NSString).expandingTildeInPath) }

    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f }()
    private static let monthFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()
    private static let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    private static let iso = ISO8601DateFormatter()

    static func slug(_ s: String) -> String {
        let cleaned = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).split(separator: "-").prefix(7).joined(separator: "-")
    }

    @MainActor
    static func save(_ c: inout Conversation) {
        let fm = FileManager.default
        if c.fileURL == nil {
            let dir = folder.appendingPathComponent(monthFormat.string(from: c.started))
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(dayFormat.string(from: c.started)) \(slug(c.title)).md"
            c.fileURL = dir.appendingPathComponent(name)
        }
        try? render(c).write(to: c.fileURL!, atomically: true, encoding: .utf8)
        writeReadme()
    }

    static func render(_ c: Conversation) -> String {
        let agents = Array(Set(c.turns.filter { $0.role == .assistant }.map(\.agent))).sorted()
        var md = """
        ---
        id: \(c.id.uuidString)
        title: "\(c.title.replacingOccurrences(of: "\"", with: "'"))"
        started: \(iso.string(from: c.started))
        agents: [\(agents.map { "\"\($0)\"" }.joined(separator: ", "))]
        app: Agent2
        ---

        # \(c.title)

        """
        for t in c.turns {
            switch t.role {
            case .user: md += "\n### You · \(timeFormat.string(from: t.date))\n\n\(t.text)\n"
            case .assistant: md += "\n### \(t.agent) · \(timeFormat.string(from: t.date))\n\n\(t.text)\n"
            case .activity:
                let quoted = t.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
                md += "\n> **\(t.agent)** · \(timeFormat.string(from: t.date))\n\(quoted)\n"
            }
        }
        return md
    }

    /// Lists saved conversations, newest first.
    @MainActor
    static func list() -> [(title: String, date: Date, url: URL)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [(String, Date, URL)] = []
        for case let url as URL in en where url.pathExtension == "md" && url.lastPathComponent != "README.md" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var title = url.deletingPathExtension().lastPathComponent
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let line = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) {
                title = String(line.dropFirst(2))
            }
            out.append((title, date, url))
        }
        return out.sorted { $0.1 > $1.1 }.map { (title: $0.0, date: $0.1, url: $0.2) }
    }

    /// Reads a saved conversation back so it can be continued with any agent.
    static func load(_ url: URL) -> Conversation? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var c = Conversation()
        c.fileURL = url
        var current: Turn?
        var inFront = false
        func flush() {
            if var t = current { t.text = t.text.trimmingCharacters(in: .whitespacesAndNewlines); c.turns.append(t) }
            current = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = String(raw)
            if line == "---" { inFront.toggle(); continue }
            if inFront {
                if line.hasPrefix("id: "), let u = UUID(uuidString: String(line.dropFirst(4))) { c.id = u }
                if line.hasPrefix("started: "), let d = iso.date(from: String(line.dropFirst(9))) { c.started = d }
                continue
            }
            if line.hasPrefix("# ") && c.turns.isEmpty && current == nil { c.title = String(line.dropFirst(2)); continue }
            if line.hasPrefix("### ") {
                flush()
                let head = line.dropFirst(4).components(separatedBy: " · ")
                let who = head.first ?? ""
                let date = head.count > 1 ? timeFormat.date(from: head[1]) ?? Date() : Date()
                current = Turn(role: who == "You" ? .user : .assistant, agent: who, text: "", date: date)
                continue
            }
            if line.hasPrefix("> **") {
                flush()
                let who = line.dropFirst(4).components(separatedBy: "**").first ?? "Agent2"
                current = Turn(role: .activity, agent: who, text: "")
                continue
            }
            if current?.role == .activity {
                if line.hasPrefix("> ") { current?.text += String(line.dropFirst(2)) + "\n" } else if line.isEmpty { flush() }
            } else {
                current?.text += line + "\n"
            }
        }
        flush()
        return c
    }

    /// Plain-text search across all saved conversations (offered to agents as a tool).
    @MainActor
    static func search(_ query: String, limit: Int = 8) -> String {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var hits: [String] = []
        for item in list() {
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            if words.allSatisfy({ lower.contains($0) }) {
                hits.append("## \(item.title)\nfile: \(item.url.path)\n\(text.prefix(1500))")
            }
            if hits.count >= limit { break }
        }
        return hits.isEmpty ? "No past conversations match \"\(query)\"." : hits.joined(separator: "\n\n---\n\n")
    }

    @MainActor
    private static func writeReadme() {
        let url = folder.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? """
        # Agent2 history

        Every conversation you have with Agent2 is saved here as Markdown, one file per conversation,
        grouped by month. The history belongs to Agent2, not to any one agent, so it stays the same
        when you switch between Claude Code, Codex, an API key or a different session.
        Agents can read these files for reference when you mention earlier work.
        """.write(to: url, atomically: true, encoding: .utf8)
    }
}
