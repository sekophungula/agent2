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
        Updater.shared.preview(.available(.init(version: "0.1.6",
            notes: "**A natural voice, on your Mac.**\n\n- Agent2 now speaks with Kokoro, run on your Mac.\n- Replies start in about half a second.",
            zip: URL(string: "https://example.com")!, page: URL(string: "https://example.com")!)))
        render(ChatView(voice: voice, openSettings: {}, openHistory: {}, toggleMic: {}), "popover-update", dir)
        for tab in [SettingsTab.source, .agents, .apps, .voice, .about] {
            render(SettingsView(tab: tab).frame(width: 820, height: tab == .voice ? 1080 : 640), "settings-\(tab.id.split(separator: " ").first!.lowercased())", dir)
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

    /// `Agent2 --say "text"`: loads Kokoro (downloading it if needed), speaks the
    /// text and prints how long the model took to load and the voice took to start.
    static func say(_ text: String) {
        let k = Kokoro.shared
        let t0 = Date()
        k.prepare()
        Task { @MainActor in
            while k.state == .downloading { try? await Task.sleep(for: .milliseconds(100)) }
            print(String(format: "Kokoro: %@ after %.1fs, %.0f MB on disk", "\(k.state)", Date().timeIntervalSince(t0),
                         Double(Kokoro.diskSize()) / 1_000_000))
            guard k.isReady else { exit(1) }
            let t1 = Date()
            let first = try? await k.synthesize(KokoroPlayer.sentences(text).first ?? text, voice: AppSettings.shared.kokoroVoice)
            print(String(format: "First sentence generated in %.2fs (%.1fs of audio)", Date().timeIntervalSince(t1),
                         Double(first?.count ?? 0) / 24_000))
            let t2 = Date()
            _ = try? await k.synthesize(KokoroPlayer.sentences(text).first ?? text, voice: AppSettings.shared.kokoroVoice)
            print(String(format: "Same sentence again (warm): %.2fs", Date().timeIntervalSince(t2)))
            let sp = Speaker.shared
            sp.speak(text)
            try? await Task.sleep(for: .milliseconds(300))
            while sp.isSpeaking { try? await Task.sleep(for: .milliseconds(100)) }
            print(String(format: "Done in %.1fs", Date().timeIntervalSince(t1)))
            exit(0)
        }
    }

    /// `Agent2 --check-update`: asks GitHub for the latest release and prints the result.
    static func checkUpdate() {
        Task { @MainActor in
            await Updater.shared.check()
            print("Running v\(Updater.currentVersion) from \(Updater.appURL.path): \(Updater.shared.state)")
            exit(0)
        }
    }

    /// `Agent2 --update-from <zip path or https URL> <version> [--relaunch]`: installs that build over this copy.
    static func updateFrom(zip: String, version: String, relaunch: Bool) {
        let r = Updater.Release(version: version, notes: "", zip: zip.hasPrefix("https://") ? URL(string: zip)! : URL(fileURLWithPath: zip),
                                page: URL(string: "https://github.com/\(Updater.repo)/releases")!)
        Task { @MainActor in
            await Updater.shared.install(r, relaunch: relaunch)
            print("Result: \(Updater.shared.state)")
            exit(0)
        }
    }

    /// `Agent2 --talk "message"`: sends a typed message to the source and speaks the
    /// reply as it streams, printing when each sentence was queued and when the agent finished.
    static func talk(_ message: String) {
        AgentRegistry.shared.refresh()
        Kokoro.shared.loadIfInstalled()
        Task { @MainActor in
            while Kokoro.shared.state == .downloading { try? await Task.sleep(for: .milliseconds(100)) }
            let o = Orchestrator.shared
            let t0 = Date()
            var first: Double?
            Speaker.trace = { text in
                let t = Date().timeIntervalSince(t0)
                if first == nil { first = t }
                print(String(format: "%6.1fs  speak: %@", t, text))
            }
            print("Source: \(AgentRegistry.shared.source?.name ?? "none"), voice: \(Kokoro.shared.isReady ? "Kokoro" : "macOS")")
            o.send(message)
            while o.isWorking { try? await Task.sleep(for: .milliseconds(50)) }
            let done = Date().timeIntervalSince(t0)
            print(String(format: "%6.1fs  agent finished", done))
            try? await Task.sleep(for: .milliseconds(500))
            while Speaker.shared.isSpeaking { try? await Task.sleep(for: .milliseconds(100)) }
            print(String(format: "First speech %.1fs after sending; agent took %.1fs; all speech done at %.1fs",
                         first ?? -1, done, Date().timeIntervalSince(t0)))
            exit(0)
        }
    }

    /// `Agent2 --stream-test`: feeds a sample reply to SpeechStream in small pieces and
    /// prints what would be spoken (nothing is played).
    static func streamTest() {
        var said: [String] = []
        Speaker.trace = { said.append($0) }
        let reply = "I'll ask Codex to write the tests now. <delegate agent=\"codex\">Add parser tests in tests/</delegate> " +
            "Here's the command:\n```bash\nnpm test\n```\nWhen it's done, I'll tell you. Prices are < 5 dollars! **Done.**"
        let s = SpeechStream()
        var i = reply.startIndex
        while i < reply.endIndex {
            let j = reply.index(i, offsetBy: 3, limitedBy: reply.endIndex) ?? reply.endIndex
            s.feed(String(reply[i..<j])); i = j
        }
        s.finish()
        Speaker.shared.stop()
        for (n, line) in said.enumerated() { print("\(n + 1). \(line)") }
    }
}
