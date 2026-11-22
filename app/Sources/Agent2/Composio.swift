import AppKit
import Foundation

/// Composio links the person's apps (Gmail, Slack, GitHub, X, LinkedIn, Notion…)
/// so any agent Agent2 talks to can act in them. Agent2 drives the official
/// `composio` CLI, which handles OAuth and stores the connections.
@MainActor
final class ComposioService: ObservableObject {
    static let shared = ComposioService()

    struct Connection: Identifiable, Hashable { let id: String; let toolkit: String; let status: String; let alias: String? }
    struct Toolkit: Identifiable, Hashable { let id: String; let name: String; let symbol: String }

    @Published var cliPath: String?
    @Published var account: String?           // whoami output, nil when signed out
    @Published var connections: [Connection] = []
    @Published var linkedInClaudeCode = false
    @Published var linkedInCodex = false
    @Published var busy: String?
    @Published var lastError: String?

    static let popular: [Toolkit] = [
        .init(id: "gmail", name: "Gmail", symbol: "envelope"),
        .init(id: "googlecalendar", name: "Google Calendar", symbol: "calendar"),
        .init(id: "googledrive", name: "Google Drive", symbol: "externaldrive"),
        .init(id: "slack", name: "Slack", symbol: "number"),
        .init(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "notion", name: "Notion", symbol: "doc.text"),
        .init(id: "linear", name: "Linear", symbol: "checklist"),
        .init(id: "twitter", name: "X (Twitter)", symbol: "at"),
        .init(id: "linkedin", name: "LinkedIn", symbol: "person.2"),
        .init(id: "instagram", name: "Instagram", symbol: "camera"),
        .init(id: "facebook", name: "Facebook", symbol: "hand.thumbsup"),
        .init(id: "youtube", name: "YouTube", symbol: "play.rectangle"),
        .init(id: "discord", name: "Discord", symbol: "bubble.left.and.bubble.right"),
        .init(id: "spotify", name: "Spotify", symbol: "music.note"),
        .init(id: "hubspot", name: "HubSpot", symbol: "chart.bar"),
        .init(id: "airtable", name: "Airtable", symbol: "tablecells"),
    ]

    var isInstalled: Bool { cliPath != nil }
    var isSignedIn: Bool { account != nil }

    func refresh() async {
        cliPath = Shell.which("composio")
        detectAgentLinks()
        guard let cli = cliPath else { account = nil; connections = []; return }
        if let who = try? await Shell.run(cli, ["whoami"]), who.status == 0 {
            let text = who.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            account = text.isEmpty ? "Signed in" : String(text.split(separator: "\n").first ?? "Signed in")
        } else {
            account = nil
        }
        if isSignedIn, let res = try? await Shell.run(cli, ["connections", "list"]), res.status == 0 {
            connections = Self.parseConnections(res.stdout)
        }
    }

    /// The CLI prints JSON; accept either a bare array or an object wrapping one.
    static func parseConnections(_ json: String) -> [Connection] {
        guard let start = json.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let obj = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) else { return [] }
        var items: [[String: Any]] = obj as? [[String: Any]] ?? []
        if items.isEmpty, let dict = obj as? [String: Any] {
            for key in ["items", "connections", "data", "connected_accounts"] {
                if let arr = dict[key] as? [[String: Any]] { items = arr; break }
            }
        }
        return items.map { i in
            let toolkit = (i["toolkit"] as? [String: Any])?["slug"] as? String
                ?? i["toolkit"] as? String ?? i["toolkit_slug"] as? String ?? i["app"] as? String ?? i["slug"] as? String ?? "app"
            return Connection(id: i["id"] as? String ?? UUID().uuidString, toolkit: toolkit,
                              status: (i["status"] as? String ?? "active").lowercased(),
                              alias: i["alias"] as? String ?? i["word_id"] as? String)
        }
    }

    /// Composio may already be connected to the person's agents, in which case
    /// they can use their apps without anything extra in Agent2.
    func detectAgentLinks() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func contains(_ path: String) -> Bool {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").lowercased().contains("composio")
        }
        linkedInClaudeCode = ["\(home)/.claude.json", "\(home)/.claude/settings.json",
                              "\(home)/.claude/plugins/installed_plugins.json"].contains(where: contains)
        linkedInCodex = contains("\(home)/.codex/config.toml")
    }

    func openInstallPage() { NSWorkspace.shared.open(URL(string: "https://docs.composio.dev/docs/cli")!) }

    func signIn() async { await runCLI(["login"], label: "Opening Composio sign-in in your browser…") }
    func link(_ toolkit: String) async { await runCLI(["link", toolkit], label: "Finish connecting \(toolkit) in your browser…") }
    func connectAgents() async { await runCLI(["setup", "--target", "auto", "--yes"], label: "Adding Composio to Claude Code and Codex…") }

    private func runCLI(_ args: [String], label: String) async {
        guard let cli = cliPath else { openInstallPage(); return }
        busy = label; lastError = nil
        do {
            let res = try await Shell.run(cli, args)
            if res.status != 0 { lastError = (res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300).description }
        } catch { lastError = error.localizedDescription }
        busy = nil
        await refresh()
    }

    // MARK: Tools for API-based agents

    nonisolated static func searchTools(_ query: String) async -> String {
        guard let cli = await MainActor.run(body: { Shell.which("composio") }) else { return "Composio CLI is not installed." }
        let res = try? await Shell.run(cli, ["search", query])
        return String((res?.stdout ?? res?.stderr ?? "No result").prefix(12000))
    }

    nonisolated static func execute(_ slug: String, _ arguments: [String: Any]) async -> String {
        guard let cli = await MainActor.run(body: { Shell.which("composio") }) else { return "Composio CLI is not installed." }
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        let res = try? await Shell.run(cli, ["execute", slug, "-d", String(decoding: data, as: UTF8.self)])
        let out = (res?.stdout ?? "") + (res?.status == 0 ? "" : "\n" + (res?.stderr ?? ""))
        return String(out.prefix(12000))
    }
}
