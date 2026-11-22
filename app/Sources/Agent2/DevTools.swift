import AppKit
import SwiftUI

/// Developer helpers: `Agent2 --snapshot <dir>` renders the UI to PNGs and
/// `Agent2 --ask "<message>"` runs one request through the orchestrator headlessly.
@MainActor
enum DevTools {
    static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AgentRegistry.shared.refresh()
        let voice = VoiceInput()
        render(ChatView(voice: voice, openSettings: {}, openHistory: {}, toggleMic: {}), "popover-empty", dir)

        let o = Orchestrator.shared
        o.conversation.turns = [
            Turn(role: .user, agent: "You", text: "Have Codex add tests to my project while you review the README"),
            Turn(role: .activity, agent: "Agent2 → Codex CLI", text: "Add unit tests for src/parser.ts covering empty input and nested blocks. Run them and report results."),
            Turn(role: .activity, agent: "Codex CLI", text: "Added 6 tests in tests/parser.test.ts. All pass (npm test)."),
            Turn(role: .assistant, agent: "Claude Code", text: "Done. **Codex** added 6 parser tests (all passing), and I tightened the README: fixed the install command and added a *Quick start*."),
        ]
        render(ChatView(voice: voice, openSettings: {}, openHistory: {}, toggleMic: {}), "popover-chat", dir)
        o.conversation = Conversation()
        for tab in [SettingsTab.source, .agents, .apps, .voice] {
            render(SettingsView(tab: tab).frame(width: 820, height: 640), "settings-\(tab.id.split(separator: " ").first!.lowercased())", dir)
        }
        print("Snapshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func ask(_ message: String) {
        AgentRegistry.shared.refresh()
        let reg = AgentRegistry.shared
        print("Agents found: \(reg.agents.map { "\($0.name) [\($0.kind.rawValue)]" }.joined(separator: ", "))")
        print("Source: \(reg.source?.name ?? "none")  Delegates: \(reg.delegates.map(\.name))")
        let o = Orchestrator.shared
        o.send(message)
        Task {
            var lastStatus = ""
            while o.isWorking {
                if o.status != lastStatus { lastStatus = o.status; print("… \(o.status)") }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            for t in o.conversation.turns { print("\n[\(t.role.rawValue)] \(t.agent):\n\(t.text)") }
            print("\nSaved to: \(o.conversation.fileURL?.path ?? "-")")
            exit(0)
        }
    }
}
