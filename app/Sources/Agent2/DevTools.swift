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
        // Notch and menu bar pill in each state.
        let m = IndicatorModel.shared
        for phase in [IndicatorPhase.idle, .listening, .thinking, .speaking] {
            m.phase = phase
            m.level = 0.7
            m.tick = 5
            let ear = phase == .idle ? NotchPanel.idleEar : NotchPanel.activeEar
            let notch = ZStack(alignment: .top) {
                Color(white: 0.85)
                NotchView(model: m, notchWidth: 190, height: 32).frame(width: 190 + ear * 2, height: 32)
            }.frame(width: 190 + NotchPanel.activeEar * 2 + 40, height: 56)
            render(notch, "notch-\(phase)", dir)
            let pill = MenuBarPill.image(for: m)
            let bar = Image(nsImage: pill).padding(8).background(Color(white: 0.92))
            render(bar, "menubar-\(phase)", dir)
        }
        m.phase = .idle
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

    static func ask(_ message: String, spoken: Bool = false) {
        AgentRegistry.shared.refresh()
        let reg = AgentRegistry.shared
        print("Agents found: \(reg.agents.map { "\($0.name) [\($0.kind.rawValue)]" }.joined(separator: ", "))")
        print("Source: \(reg.source?.name ?? "none")  Delegates: \(reg.delegates.map(\.name))")
        let o = Orchestrator.shared
        let wasSpeaking = AppSettings.shared.speakVoiceReplies
        if spoken { AppSettings.shared.speakVoiceReplies = false }   // print instead of playing audio
        o.send(message, spoken: spoken)
        Task {
            var lastStatus = ""
            while o.isWorking {
                if o.status != lastStatus { lastStatus = o.status; print("… \(o.status)") }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            for t in o.conversation.turns { print("\n[\(t.role.rawValue)] \(t.agent):\n\(t.text)") }
            if spoken, let last = o.conversation.turns.last { print("\nWould say: \(Speaker.spoken(last.text))") }
            print("\nSaved to: \(o.conversation.fileURL?.path ?? "-")")
            AppSettings.shared.speakVoiceReplies = wasSpeaking
            exit(0)
        }
    }
}
