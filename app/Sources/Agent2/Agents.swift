import AppKit
import Foundation

enum AgentKind: String, Codable { case cli, api, desktop }

/// Something Agent2 can hand work to.
struct AgentInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: AgentKind
    let detail: String          // binary path, "API key", or app path
    let strengths: String       // shown to the source agent so it can route work
    /// Desktop apps can't be driven headlessly: Agent2 hands the prompt over instead.
    var canRunHeadless: Bool { kind != .desktop }
}

/// Finds the agents on this Mac: command-line agents (which use the person's
/// Claude / ChatGPT / Gemini subscription), API keys, and desktop chat apps.
@MainActor
final class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()
    @Published private(set) var agents: [AgentInfo] = []

    private struct CLISpec { let id, bin, name, strengths: String }
    private let cliSpecs: [CLISpec] = [
        .init(id: "claude-code", bin: "claude", name: "Claude Code",
              strengths: "Strong all-rounder for coding, files, terminal work, writing and multi-step tasks. Uses the person's Claude subscription."),
        .init(id: "codex", bin: "codex", name: "Codex CLI",
              strengths: "OpenAI's coding agent: implementing features, refactors, running tests and scripts. Uses the person's ChatGPT subscription."),
        .init(id: "gemini", bin: "gemini", name: "Gemini CLI",
              strengths: "Google's agent: very long documents, large codebases, research with Google Search."),
        .init(id: "cursor-agent", bin: "cursor-agent", name: "Cursor Agent",
              strengths: "Cursor's coding agent for editing code in a project."),
        .init(id: "opencode", bin: "opencode", name: "OpenCode",
              strengths: "Open-source coding agent that can use many model providers."),
    ]

    private struct AppSpec { let id, bundleID, name: String }
    private let appSpecs: [AppSpec] = [
        .init(id: "claude-desktop", bundleID: "com.anthropic.claudefordesktop", name: "Claude (desktop)"),
        .init(id: "chatgpt-desktop", bundleID: "com.openai.chat", name: "ChatGPT (desktop)"),
        .init(id: "codex-desktop", bundleID: "com.openai.codex", name: "Codex (desktop)"),
        .init(id: "cursor-desktop", bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        .init(id: "perplexity-desktop", bundleID: "ai.perplexity.mac", name: "Perplexity"),
    ]

    func refresh() {
        var found: [AgentInfo] = []
        for s in cliSpecs {
            if let path = Shell.which(s.bin) {
                found.append(AgentInfo(id: s.id, name: s.name, kind: .cli, detail: path, strengths: s.strengths))
            }
        }
        let settings = AppSettings.shared
        if !settings.anthropicKey.isEmpty {
            found.append(AgentInfo(id: "anthropic-api", name: "Claude API", kind: .api,
                                   detail: settings.anthropicModel,
                                   strengths: "Claude through your Anthropic API key: reasoning, writing, analysis. Can use Composio tools."))
        }
        if !settings.openAIKey.isEmpty {
            found.append(AgentInfo(id: "openai-api", name: "OpenAI API", kind: .api,
                                   detail: settings.openAIModel,
                                   strengths: "OpenAI models through your API key: reasoning, writing, analysis. Can use Composio tools."))
        }
        var seenApps = Set<String>()
        for a in appSpecs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleID), seenApps.insert(url.path).inserted {
                // Name it the way the person sees it (ChatGPT.app now carries Codex's bundle id).
                let shown = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                found.append(AgentInfo(id: a.id, name: "\(shown) (desktop)", kind: .desktop, detail: url.path,
                                       strengths: "Desktop chat app (hand-off only)."))
            }
        }
        agents = found
        // First run: pick a sensible source. After that only the user changes it.
        if settings.sourceAgentID.isEmpty || !found.contains(where: { $0.id == settings.sourceAgentID }) {
            if settings.sourceAgentID.isEmpty, let first = found.first(where: { $0.canRunHeadless }) ?? found.first {
                settings.sourceAgentID = first.id
            }
        }
    }

    var source: AgentInfo? { agents.first { $0.id == AppSettings.shared.sourceAgentID } }

    /// Agents the source may delegate to.
    var delegates: [AgentInfo] {
        let s = AppSettings.shared
        guard s.delegatesEnabled else { return [] }
        return agents.filter { $0.canRunHeadless && $0.id != s.sourceAgentID && !s.disabledDelegateIDs.contains($0.id) }
    }

    func agent(_ id: String) -> AgentInfo? { agents.first { $0.id == id } }
}
