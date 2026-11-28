import Foundation

/// Long-term memory across conversations: a knowledge graph of the history, built
/// into Agent2 (the approach graphify takes, without needing it installed).
///
/// - Building: a while after a conversation goes quiet, each conversation that
///   changed is read once by the person's own source agent (Claude Code, Codex or
///   an API key), which pulls out what's worth remembering: the people, projects,
///   apps, files, decisions and preferences in it and how they relate, plus a
///   one-line summary. Unchanged conversations are never read again.
/// - Recalling: matching a request against the graph runs on this Mac in a few
///   milliseconds. The best-matching things, and what's connected to them, point
///   to the earlier conversations that matter, and their summaries and facts go
///   in front of the request.
///
/// The graph is saved in graphify's `graph.json` format, so graphify itself can
/// open it (`graphify query "…" --graph <file>`). It lives in Application Support,
/// so the history folder stays plain Markdown.
@MainActor
final class HistoryMemory: ObservableObject {
    static let shared = HistoryMemory()

    enum State: Equatable { case unavailable(String), empty, ready, updating(Int, Int), failed(String) }
    @Published private(set) var state: State = .empty
    @Published private(set) var nodes = 0
    @Published private(set) var conversations = 0
    @Published private(set) var updated: Date?

    /// How long a conversation has to be quiet before the graph is brought up to date.
    static let quietDelay: TimeInterval = 90
    /// Most of a conversation sent for reading (its start and end are kept).
    static let maxChars = 14_000

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent2/Memory")
    }
    static var graphURL: URL { folder.appendingPathComponent("graph.json") }
    static var manifestURL: URL { folder.appendingPathComponent("manifest.json") }

    private var graph = Graph()
    /// Conversation file (relative to the history folder) → its size and date when read.
    private var manifest: [String: String] = [:]
    private var refreshTimer: Timer?
    private var running = false
    private var again = false

    private init() { load() }

    var enabled: Bool { AppSettings.shared.historyMemory }

    /// The agent that reads conversations, or why there isn't one.
    static func reader() -> (AgentInfo?, String?) {
        guard let source = AgentRegistry.shared.source else { return (nil, "Pick a source agent first.") }
        guard source.canRunHeadless else {
            return (nil, "\(source.name) can't run in the background. Pick a command-line agent or an API key as the source.")
        }
        return (source, nil)
    }

    // MARK: - Graph (graphify's graph.json shape)

    struct Node: Codable {
        var id: String
        var label: String
        var norm_label: String
        var kind: String
        var rationale: String?        // a short fact about it
        var source_file: String
        var file_type = "document"
        var captured_at: String?
        var community: Int?
    }

    struct Link: Codable {
        var source: String
        var target: String
        var relation: String
        var confidence = "EXTRACTED"
        var confidence_score = 1.0
        var source_file: String
        var weight = 1.0
    }

    struct Graph: Codable {
        var directed = false
        var multigraph = false
        var graph: [String: String] = [:]
        var nodes: [Node] = []
        var links: [Link] = []
        var hyperedges: [String] = []
    }

    // MARK: - Recall

    /// Past context related to `question`, or nil when there's none (or memory is off).
    func recall(_ question: String) async -> String? {
        guard enabled, !graph.nodes.isEmpty else { return nil }
        let current = Orchestrator.shared.conversation.fileURL.map { relativePath($0) }
        return Self.context(for: question, in: graph, history: HistoryStore.folder, excluding: current)
    }

    /// The conversations in `graph` that relate to `question`, as context for an agent.
    nonisolated static func context(for question: String, in graph: Graph, history: URL,
                                     excluding current: String? = nil, maxFiles: Int = 3) -> String? {
        let asked = Set(keywords(question))
        guard !asked.isEmpty else { return nil }

        // Things whose names match the question.
        var score: [String: Double] = [:]
        for n in graph.nodes where n.kind != "conversation" {
            let hit = matches(keywords(n.label), asked)
            if hit > 0 { score[n.id] = Double(hit) }
        }
        // Conversation summaries count too, but less than named things.
        for n in graph.nodes where n.kind == "conversation" {
            let hit = matches(keywords(n.label + " " + (n.rationale ?? "")), asked)
            if hit >= 2 { score[n.id, default: 0] += Double(hit) * 0.5 }
        }
        guard !score.isEmpty else { return nil }

        // Spread along the graph two steps (things linked to them, and the same
        // thing named in other conversations), fading each step.
        var neighbours: [String: [String]] = [:]
        for l in graph.links { neighbours[l.source, default: []].append(l.target); neighbours[l.target, default: []].append(l.source) }
        let byLabel = Dictionary(grouping: graph.nodes, by: \.norm_label)
        let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var frontier = score
        for _ in 0..<2 {
            var next: [String: Double] = [:]
            for (id, s) in frontier {
                guard let n = byID[id] else { continue }
                var linked = neighbours[id] ?? []
                if n.kind != "conversation" { linked += (byLabel[n.norm_label] ?? []).map(\.id).filter { $0 != id } }
                for m in linked where score[m] == nil { next[m] = max(next[m] ?? 0, s * 0.35) }
            }
            for (m, s) in next { score[m] = s }
            frontier = next
        }

        // Rank conversations by what matched in them.
        var fileScore: [String: Double] = [:], fileHits: [String: [Node]] = [:]
        for (id, s) in score {
            guard let n = byID[id], n.source_file != current else { continue }
            fileScore[n.source_file, default: 0] += s
            if n.kind != "conversation", s >= 0.35 { fileHits[n.source_file, default: []].append(n) }
        }
        let files = fileScore.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.prefix(maxFiles).map(\.key)
        guard !files.isEmpty else { return nil }

        var out = ""
        for file in files {
            let summary = graph.nodes.first { $0.source_file == file && $0.kind == "conversation" }
            let url = history.appendingPathComponent(file)
            out += "\n## \(summary?.label ?? file)"
            if let day = summary?.captured_at.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                out += " (\(day.formatted(date: .abbreviated, time: .omitted)))"
            }
            out += "\nfile: \(url.path)\n"
            if let s = summary?.rationale, !s.isEmpty { out += "\(s)\n" }
            let facts = (fileHits[file] ?? []).sorted { (score[$0.id] ?? 0) > (score[$1.id] ?? 0) }.prefix(6)
            for n in facts { out += "- \(n.label)\(n.rationale.map { ": \($0)" } ?? "")\n" }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static let stopwords: Set<String> = [
        "the", "and", "for", "you", "your", "that", "this", "with", "what", "was", "are", "can", "could", "would", "should",
        "have", "has", "had", "did", "does", "about", "from", "into", "then", "than", "them", "they", "there", "their",
        "just", "like", "want", "need", "make", "please", "also", "some", "any", "all", "not", "but", "how", "why",
        "when", "where", "which", "who", "will", "now", "again", "last", "time", "thing", "things", "agent2", "agent",
        "hey", "okay", "yeah", "yes", "know", "let", "get", "got", "one", "out", "our", "its", "it's", "i'm", "me", "my",
    ]

    nonisolated static func keywords(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// How many of `words` the question asked about (a shared 5-letter start counts:
    /// "deploy"/"deployed").
    nonisolated static func matches(_ words: [String], _ asked: Set<String>) -> Int {
        Set(words).filter { w in asked.contains(w) || (w.count >= 5 && asked.contains { $0.count >= 5 && $0.prefix(5) == w.prefix(5) }) }.count
    }

    /// Names of remembered things of these kinds (for speech recognition to spell right).
    func namedThings(kinds: Set<String>) -> [String] {
        graph.nodes.filter { kinds.contains($0.kind) }.map(\.label)
    }

    // MARK: - Building

    /// A conversation changed: bring the graph up to date once things are quiet.
    func historyChanged() {
        guard enabled else { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.quietDelay, repeats: false) { _ in
            Task { @MainActor in HistoryMemory.shared.update() }
        }
    }

    /// At launch: catch up on anything that changed since the graph was built.
    func start() {
        load()
        guard enabled else { return }
        if !changedFiles().isEmpty { historyChanged() }
    }

    /// Reads the conversations that changed since last time.
    func update() {
        refreshTimer?.invalidate(); refreshTimer = nil
        guard enabled else { return }
        let (reader, why) = Self.reader()
        guard let reader else { state = .unavailable(why ?? ""); return }
        if running { again = true; return }
        let todo = changedFiles()
        dropMissing()
        guard !todo.isEmpty else { state = graph.nodes.isEmpty ? .empty : .ready; save(); return }
        running = true
        Task {
            var failures: [String] = []
            for (i, item) in todo.enumerated() {
                guard enabled else { break }
                state = .updating(i + 1, todo.count)
                do {
                    try await read(item.url, rel: item.rel, with: reader)
                    manifest[item.rel] = item.stamp
                    save()
                } catch {
                    failures.append(error.localizedDescription)
                    if failures.count >= 3 { break }   // the agent isn't working: try again later
                }
            }
            running = false
            Parakeet.shared.refreshVocabulary()
            if let last = failures.last, failures.count >= min(3, todo.count) {
                state = .failed(String(last.prefix(160)))
            } else {
                state = graph.nodes.isEmpty ? .empty : .ready
            }
            if again { again = false; update() }
        }
    }

    /// Asks the agent what's worth remembering from one conversation, and puts it in the graph.
    private func read(_ url: URL, rel: String, with agent: AgentInfo) async throws {
        guard let c = HistoryStore.load(url) else { return }
        let said = c.turns.filter { $0.role != .activity }
            .map { "\($0.role == .user ? "Person" : $0.agent): \($0.text)" }.joined(separator: "\n\n")
        var text = said
        if text.count > Self.maxChars {
            text = String(said.prefix(Self.maxChars / 2)) + "\n\n[…]\n\n" + String(said.suffix(Self.maxChars / 2))
        }
        let system = """
        You index a person's past conversations with their assistant, Agent2, so it can remember them later. \
        Reply with one JSON object only: no prose, no Markdown fences, and don't use any tools.
        """
        let prompt = """
        From the conversation below, pull out what would help the assistant in a later conversation.

        Return JSON shaped like this:
        {"title": "short name for the conversation",
         "summary": "one or two sentences: what the person wanted, what was done or decided, what's still open",
         "nodes": [{"label": "a specific thing, named the way the person would say it", "kind": "person|project|app|file|place|task|decision|preference|topic", "note": "one short fact about it from this conversation"}],
         "edges": [{"from": "label", "to": "label", "relation": "short verb phrase"}]}

        Up to 12 nodes. Only concrete things (names, projects, apps, files, decisions, preferences, open tasks), \
        not small talk. If nothing is worth remembering, return empty lists.

        <conversation title="\(c.title)">
        \(text)
        </conversation>
        """
        let ctx = RunContext(cwd: Self.folder.path, autonomy: .readOnly, cancel: CancelToken(),
                             progress: { _ in }, tools: nil, fast: true, background: true)
        let reply = try await Runner.run(agent, prompt: prompt, system: system,
                                         model: agent.id == "claude-code" ? "haiku" : nil, ctx: ctx)
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else {
            throw RunnerError.failed("\(agent.name) didn't reply with the memory notes: \(reply.prefix(120))")
        }
        replace(rel, with: json, conversation: c)
    }

    private func replace(_ rel: String, with json: [String: Any], conversation c: Conversation) {
        graph.nodes.removeAll { $0.source_file == rel }
        graph.links.removeAll { $0.source_file == rel }
        let base = Self.slug(rel)
        let day = ISO8601DateFormatter().string(from: c.started)
        let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c.title
        let convID = base
        graph.nodes.append(Node(id: convID, label: title, norm_label: title.lowercased(), kind: "conversation",
                                rationale: json["summary"] as? String, source_file: rel, captured_at: day))
        var ids: [String: String] = [:]
        for n in json["nodes"] as? [[String: Any]] ?? [] {
            guard let label = (n["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { continue }
            let norm = label.lowercased()
            guard ids[norm] == nil else { continue }
            var id = base + "_" + Self.slug(label)
            while ids.values.contains(id) { id += "_" }
            ids[norm] = id
            graph.nodes.append(Node(id: id, label: label, norm_label: norm, kind: n["kind"] as? String ?? "topic",
                                    rationale: n["note"] as? String, source_file: rel, captured_at: day))
            graph.links.append(Link(source: convID, target: id, relation: "mentions", source_file: rel))
        }
        for e in json["edges"] as? [[String: Any]] ?? [] {
            guard let a = (e["from"] as? String).flatMap({ ids[$0.lowercased()] }),
                  let b = (e["to"] as? String).flatMap({ ids[$0.lowercased()] }), a != b else { continue }
            graph.links.append(Link(source: a, target: b, relation: e["relation"] as? String ?? "related_to", source_file: rel))
        }
    }

    private struct Item { let url: URL; let rel: String; let stamp: String }

    /// Conversations that are new or changed since they were read, newest first.
    private func changedFiles() -> [Item] {
        HistoryStore.list().compactMap { item in
            let rel = relativePath(item.url)
            let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let stamp = "\(size)@\(Int(item.date.timeIntervalSince1970))"
            return manifest[rel] == stamp ? nil : Item(url: item.url, rel: rel, stamp: stamp)
        }
    }

    /// Forgets conversations whose files were deleted.
    private func dropMissing() {
        let history = HistoryStore.folder
        for rel in manifest.keys where !FileManager.default.fileExists(atPath: history.appendingPathComponent(rel).path) {
            manifest[rel] = nil
            graph.nodes.removeAll { $0.source_file == rel }
            graph.links.removeAll { $0.source_file == rel }
        }
    }

    private func relativePath(_ url: URL) -> String {
        let root = HistoryStore.folder.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : url.lastPathComponent
    }

    nonisolated static func slug(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { out, ch in
            if ch != "_" || out.last != "_" { out.append(ch) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - Disk

    private func load() {
        // Earlier builds kept a graph made by the graphify command here.
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("graphify-out"))
        if let d = try? Data(contentsOf: Self.graphURL), let g = try? JSONDecoder().decode(Graph.self, from: d) { graph = g }
        if let d = try? Data(contentsOf: Self.manifestURL),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { manifest = m }
        refreshCounts()
        updated = (try? Self.graphURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if case .empty = state, !graph.nodes.isEmpty { state = .ready }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try? enc.encode(graph).write(to: Self.graphURL, options: .atomic)
        try? enc.encode(manifest).write(to: Self.manifestURL, options: .atomic)
        refreshCounts()
        updated = Date()
    }

    private func refreshCounts() {
        nodes = graph.nodes.filter { $0.kind != "conversation" }.count
        conversations = graph.nodes.filter { $0.kind == "conversation" }.count
    }

    /// Forgets everything (the history itself is untouched).
    func reset() {
        graph = Graph(); manifest = [:]
        save()
        state = .empty
    }
}
