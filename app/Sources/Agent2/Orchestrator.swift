import AVFoundation
import Foundation

/// The middleman. The user's chosen *source* agent is the brain; Agent2 tells it
/// which other agents and tools exist, runs whatever it delegates (in parallel),
/// feeds the results back, and records everything in the Markdown history.
@MainActor
final class Orchestrator: ObservableObject {
    static let shared = Orchestrator()

    @Published var conversation = Conversation()
    @Published var isWorking = false
    @Published var status: String = ""
    private var cancel: CancelToken?
    private let speech = AVSpeechSynthesizer()

    private let delegatePattern = try! NSRegularExpression(
        pattern: #"<delegate\s+agent="([^"]+)"\s*>([\s\S]*?)</delegate>"#)

    func newConversation() {
        stop()
        conversation = Conversation()
        status = ""
    }

    func open(_ url: URL) {
        guard let c = HistoryStore.load(url) else { return }
        stop()
        conversation = c
    }

    func stop() {
        cancel?.cancel()
        cancel = nil
        isWorking = false
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        let registry = AgentRegistry.shared
        guard let source = registry.source else {
            append(.init(role: .assistant, agent: "Agent2", text: "Pick a source agent in Settings first. Agent2 found none on this Mac yet: install Claude Code or Codex, or add an API key."))
            return
        }
        if conversation.turns.isEmpty { conversation.title = String(text.prefix(60)) }
        let history = conversation.turns
        append(.init(role: .user, agent: "You", text: text))

        let token = CancelToken()
        cancel = token
        isWorking = true
        status = "\(source.name) is thinking…"

        let settings = AppSettings.shared
        let delegates = registry.delegates
        let system = systemPrompt(source: source, delegates: delegates)
        let prompt = promptWithContext(history: history, message: text, turns: settings.contextTurns)
        let ctx = makeContext(token: token, delegates: delegates)

        Task {
            do {
                var reply = try await Runner.run(source, prompt: prompt, system: system, model: nil, ctx: ctx)
                // CLI agents delegate with <delegate> tags; API agents use the delegate tool inside their own loop.
                var round = 0
                while source.kind == .cli, round < 3, case let tasks = parseDelegations(reply), !tasks.isEmpty {
                    round += 1
                    let visible = stripDelegations(reply)
                    if !visible.isEmpty { append(.init(role: .activity, agent: source.name, text: visible)) }
                    let results = await runDelegations(tasks, ctx: ctx)
                    status = "\(source.name) is combining the results…"
                    let followUp = "Results from the agents you delegated to:\n\n" + results
                        + "\n\nNow give the person the final answer. Delegate again only if something essential is still missing."
                    reply = try await Runner.run(source, prompt: promptWithContext(history: conversation.turns, message: followUp, turns: settings.contextTurns),
                                                 system: system, model: nil, ctx: ctx)
                }
                finish(reply: stripDelegations(reply), from: source)
            } catch is CancellationError {
                finish(reply: "Stopped.", from: source)
            } catch {
                finish(reply: "⚠️ \(error.localizedDescription)", from: source)
            }
        }
    }

    private func finish(reply: String, from source: AgentInfo) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        append(.init(role: .assistant, agent: source.name, text: text.isEmpty ? "(no reply)" : text))
        isWorking = false
        status = ""
        cancel = nil
        if AppSettings.shared.speakReplies, !text.isEmpty {
            speech.speak(AVSpeechUtterance(string: String(text.prefix(600))))
        }
    }

    func logActivity(_ agent: String, _ text: String) {
        append(.init(role: .activity, agent: agent, text: text))
    }

    private func append(_ t: Turn) {
        conversation.turns.append(t)
        HistoryStore.save(&conversation)
    }

    // MARK: Prompts

    private func systemPrompt(source: AgentInfo, delegates: [AgentInfo]) -> String {
        let s = AppSettings.shared
        var p = """
        You are the brain of Agent2, a menu-bar assistant on the person's Mac. Agent2 is a middleman: it does not do the heavy lifting itself, it gets the right agents and tools to do it well. The person usually talks to you by voice (they hold Control+Option), so their words may be loose: work out what they want.

        Reply in plain, warm, short Markdown. Lead with the result. Never invent facts, files or links.

        Workspace for files you make: \(s.workspaceFolder)
        Past conversations (Markdown, one file per conversation) are in: \(s.historyFolder)
        Read them when the person refers to earlier work ("like last time", "that thing we did").
        """
        if !delegates.isEmpty {
            p += "\n\nOther agents on this Mac you can hand work to:\n"
            for d in delegates { p += "- \(d.id): \(d.name). \(d.strengths)\n" }
            if source.kind == .cli {
                p += """

                To hand work to them, write one line per task:
                <delegate agent="AGENT_ID">a complete, self-contained brief</delegate>
                then stop. Agent2 runs them in parallel and sends you the results, and you then write the final answer.
                Delegate only when another agent is clearly better suited or tasks can run in parallel; do simple things yourself.
                """
            } else {
                p += "\nUse the delegate tool to hand work to them. Do simple things yourself."
            }
        }
        if Shell.which("composio") != nil {
            p += source.kind == .cli
                ? "\n\nThe person's apps (Gmail, Slack, GitHub, socials, calendars…) are reachable through the Composio CLI: run `composio search \"<task>\"` to find a tool, then `composio execute <TOOL_SLUG> -d '<json>'`. If an app isn't connected, tell them to link it in Agent2 → Settings → Apps."
                : "\n\nUse composio_search and composio_execute to act in the person's connected apps (Gmail, Slack, GitHub, socials, calendars…)."
            p += " Before sending, posting or deleting anything for them, show the exact draft and get a yes."
        }
        return p
    }

    private func promptWithContext(history: [Turn], message: String, turns: Int) -> String {
        let recent = history.filter { $0.role != .activity }.suffix(turns)
        guard !recent.isEmpty else { return message }
        let transcript = recent.map { "\($0.role == .user ? "Person" : $0.agent): \($0.text)" }.joined(separator: "\n\n")
        return "<conversation_so_far>\n\(transcript)\n</conversation_so_far>\n\n\(message)"
    }

    // MARK: Delegation

    struct DelegateTask { let agentID: String; let brief: String }

    private func parseDelegations(_ text: String) -> [DelegateTask] {
        let ns = text as NSString
        return delegatePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            DelegateTask(agentID: ns.substring(with: $0.range(at: 1)),
                         brief: ns.substring(with: $0.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func stripDelegations(_ text: String) -> String {
        delegatePattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runDelegations(_ tasks: [DelegateTask], ctx: RunContext) async -> String {
        for t in tasks {
            let name = AgentRegistry.shared.agent(t.agentID)?.name ?? t.agentID
            append(.init(role: .activity, agent: "Agent2 → \(name)", text: t.brief))
        }
        status = "Working with \(Set(tasks.map(\.agentID)).count) agent(s)…"
        var outputs: [(Int, String, String)] = []
        await withTaskGroup(of: (Int, String, String).self) { group in
            for (i, t) in tasks.enumerated() {
                group.addTask { await (i, t.agentID, self.runOne(t, ctx: ctx)) }
            }
            for await r in group { outputs.append(r) }
        }
        outputs.sort { $0.0 < $1.0 }
        for (_, id, out) in outputs {
            append(.init(role: .activity, agent: AgentRegistry.shared.agent(id)?.name ?? id, text: String(out.prefix(4000))))
        }
        return outputs.map { "## \($0.1)\n\($0.2)" }.joined(separator: "\n\n")
    }

    func runOne(_ t: DelegateTask, ctx: RunContext) async -> String {
        guard let agent = AgentRegistry.shared.agent(t.agentID), agent.canRunHeadless else {
            return "Agent \(t.agentID) isn't available."
        }
        let system = "You are a worker agent that Agent2 called for one task. Do it completely, then reply with the result only: what you found or made, file paths, and anything that didn't work."
        let workerCtx = RunContext(cwd: ctx.cwd, autonomy: ctx.autonomy, cancel: ctx.cancel, progress: ctx.progress, tools: nil)
        do { return try await Runner.run(agent, prompt: t.brief, system: system, model: nil, ctx: workerCtx) }
        catch { return "Failed: \(error.localizedDescription)" }
    }

    private func makeContext(token: CancelToken, delegates: [AgentInfo]) -> RunContext {
        let s = AppSettings.shared
        let host = AgentTools(orchestrator: self, delegateIDs: delegates.map(\.id),
                              composio: Shell.which("composio") != nil)
        return RunContext(cwd: (s.workspaceFolder as NSString).expandingTildeInPath, autonomy: s.autonomy, cancel: token,
                          progress: { [weak self] msg in Task { @MainActor in self?.status = msg } },
                          tools: host)
    }
}

/// Tools offered to API-based source agents (the CLI agents have their own).
struct AgentTools: ToolHost {
    let orchestrator: Orchestrator
    let delegateIDs: [String]
    let composio: Bool

    var specs: [ToolSpec] {
        var s: [ToolSpec] = [
            ToolSpec("search_history", "Search the person's past Agent2 conversations (Markdown files) for words.",
                     ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]),
        ]
        if !delegateIDs.isEmpty {
            s.append(ToolSpec("delegate", "Hand a self-contained task to another agent on the person's Mac and get its result. Several calls in one turn run in parallel.",
                              ["type": "object",
                               "properties": ["agent": ["type": "string", "enum": delegateIDs],
                                              "task": ["type": "string", "description": "A complete brief the agent can act on alone."]],
                               "required": ["agent", "task"]]))
        }
        if composio {
            s.append(ToolSpec("composio_search", "Find Composio tools for a task in the person's connected apps (Gmail, Slack, GitHub, socials, calendars…). Returns tool slugs and schemas.",
                              ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]))
            s.append(ToolSpec("composio_execute", "Run a Composio tool by slug with JSON arguments. Confirm with the person before sending, posting or deleting.",
                              ["type": "object",
                               "properties": ["slug": ["type": "string"], "arguments": ["type": "object"]],
                               "required": ["slug", "arguments"]]))
        }
        return s
    }

    func call(_ name: String, _ args: [String: Any]) async -> String {
        switch name {
        case "search_history":
            let q = args["query"] as? String ?? ""
            return await MainActor.run { HistoryStore.search(q) }
        case "delegate":
            let task = Orchestrator.DelegateTask(agentID: args["agent"] as? String ?? "", brief: args["task"] as? String ?? "")
            let ctx = await MainActor.run {
                RunContext(cwd: (AppSettings.shared.workspaceFolder as NSString).expandingTildeInPath,
                           autonomy: AppSettings.shared.autonomy, cancel: CancelToken(),
                           progress: { msg in Task { @MainActor in Orchestrator.shared.status = msg } }, tools: nil)
            }
            let name = await MainActor.run { AgentRegistry.shared.agent(task.agentID)?.name ?? task.agentID }
            await orchestrator.logActivity("Agent2 → \(name)", task.brief)
            let out = await orchestrator.runOne(task, ctx: ctx)
            await orchestrator.logActivity(name, String(out.prefix(4000)))
            return out
        case "composio_search":
            return await ComposioService.searchTools(args["query"] as? String ?? "")
        case "composio_execute":
            return await ComposioService.execute(args["slug"] as? String ?? "", args["arguments"] as? [String: Any] ?? [:])
        default:
            return "Unknown tool \(name)."
        }
    }
}
