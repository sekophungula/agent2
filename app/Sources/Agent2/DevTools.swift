import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Developer helpers: `Agent2 --snapshot <dir>` renders the UI to PNGs and
/// `Agent2 --ask "<message>"` runs one request through the orchestrator headlessly.
@MainActor
enum DevTools {
    /// `--parakeet-test <audio files…>`: downloads Parakeet if needed and prints
    /// what it hears in each file, with timings.
    /// `--point-test [question…]`: checks the screenshot ↔ screen maths on made-up
    /// display layouts, then asks Claude Code each question about the real screen
    /// and moves the cursor to its answer (saving a screenshot with the cursor in it).
    static func pointTest(_ questions: [String], out: URL) {
        // 1. Maths: every corner of every display survives the round trip.
        let layouts: [(String, CGRect)] = [
            ("Retina main 1440×900", CGRect(x: 0, y: 0, width: 1440, height: 900)),
            ("1x external 1920×1080, right and lower", CGRect(x: 1440, y: -180, width: 1920, height: 1080)),
            ("display to the left, above", CGRect(x: -1280, y: 100, width: 1280, height: 800)),
            ("portrait 1080×1920", CGRect(x: 3360, y: -500, width: 1080, height: 1920)),
        ]
        var worst = 0.0
        for (name, frame) in layouts {
            let scale = min(1, ScreenLook.maxSide / max(frame.width, frame.height))
            let size = CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            let expected = [CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
                            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY)]
            for (c, e) in zip(corners, expected) {
                let p = ScreenLook.cocoaPoint(fromImage: c, frame: frame, imageSize: size)
                let back = ScreenLook.imagePoint(fromCocoa: p, frame: frame, imageSize: size)
                worst = max(worst, hypot(p.x - e.x, p.y - e.y), hypot(back.x - c.x, back.y - c.y))
            }
            print("maths ok:", name, "image", Int(size.width), "×", Int(size.height))
        }
        print(String(format: "maths: worst corner error %.4f pt", worst))
        guard !questions.isEmpty else { exit(worst < 0.01 ? 0 : 1) }

        // 2. Live: capture, ask, point.
        CompanionCursor.shared.capturable = true
        CompanionCursor.shared.start()
        AgentRegistry.shared.refresh()
        guard let agent = AgentRegistry.shared.agents.first(where: { $0.id == "claude-code" }) else { print("no Claude Code"); exit(1) }
        Task {
            for (n, q) in questions.enumerated() {
                guard let shot = await ScreenLook.capture() else { print("capture failed (Screen Recording?)"); exit(1) }
                print("\n== \(q)\nscreen", shot.frame, "image", shot.imageSize, "pointer", shot.pointer)
                var ctx = RunContext(cwd: NSTemporaryDirectory(), autonomy: .readOnly, cancel: CancelToken(), progress: { _ in }, tools: nil)
                ctx.fast = true
                ctx.image = shot.file
                let t = Date()
                let reply = (try? await Runner.run(agent, prompt: ScreenLook.prompt(shot) + "\n\n" + q,
                                                   system: "Answer in one short sentence.", model: "sonnet", ctx: ctx)) ?? "(failed)"
                print(String(format: "%.1fs: ", Date().timeIntervalSince(t)) + reply.replacingOccurrences(of: "\n", with: " "))
                guard let mark = ScreenLook.mark(in: reply) else { print("no mark"); continue }
                let p = ScreenLook.cocoaPoint(fromImage: CGPoint(x: mark.x, y: mark.y), frame: shot.frame, imageSize: shot.imageSize)
                print("mark", mark.x, mark.y, "→ screen point", Int(p.x), Int(p.y), "shown:", ScreenLook.show(mark, from: shot))
                try? await Task.sleep(for: .seconds(1.6))
                let png = out.appendingPathComponent("point-\(n + 1).png").path
                let p2 = Process(); p2.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p2.arguments = ["-x", "-m", png]
                try? p2.run(); p2.waitUntilExit()
                print("saved", png)
                try? FileManager.default.removeItem(at: shot.file)
            }
            exit(0)
        }
    }

    /// `--gesture-test <x> <y> <out dir> "question"`: circles the spot (top-left
    /// screen points) as if the person had while asking, without moving the real
    /// pointer, then runs the whole request: screenshot with the drawn path,
    /// accessibility lookup, Claude Code, and the cursor pointing back.
    static func gestureTest(x: Double, y: Double, out: URL, question: String) {
        CompanionCursor.shared.capturable = true
        CompanionCursor.shared.start()
        AgentRegistry.shared.refresh()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let centre = CGPoint(x: x, y: mainHeight - y)
        let path = (0...60).map { i -> CGPoint in
            let a = Double(i) / 60 * 2.2 * .pi
            return CGPoint(x: centre.x + 26 * cos(a), y: centre.y + 20 * sin(a))
        }
        PointerTrail.shared.replaying = true
        PointerTrail.shared.replay(path)
        guard let agent = AgentRegistry.shared.agents.first(where: { $0.id == "claude-code" }) else { exit(1) }
        Task {
            guard let shot = await ScreenLook.capture(spoken: true) else { print("capture failed"); exit(1) }
            try? FileManager.default.copyItem(at: shot.file, to: out.appendingPathComponent("gesture-sent.jpg"))
            print("focus", shot.focus, "element:", shot.element ?? "(none)")
            var ctx = RunContext(cwd: NSTemporaryDirectory(), autonomy: .readOnly, cancel: CancelToken(), progress: { _ in }, tools: nil)
            ctx.fast = true
            ctx.image = shot.file
            let t = Date()
            let reply = (try? await Runner.run(agent, prompt: ScreenLook.prompt(shot) + "\n\n" + question,
                                               system: "Answer in two short sentences.", model: "sonnet", ctx: ctx)) ?? "(failed)"
            print(String(format: "%.1fs: ", Date().timeIntervalSince(t)) + reply)
            if let mark = ScreenLook.mark(in: reply) { print("points back:", ScreenLook.show(mark, from: shot)) }
            exit(0)
        }
    }

    static func parakeetTest(_ files: [String]) {
        AppSettings.shared.dictationEngine = .parakeet
        Parakeet.trace = { print($0) }
        let started = Date()
        Parakeet.shared.prepare()
        Task {
            while Parakeet.shared.state == .downloading { try? await Task.sleep(for: .milliseconds(200)) }
            print(String(format: "state: %@ after %.1fs", "\(Parakeet.shared.state)", Date().timeIntervalSince(started)))
            guard Parakeet.shared.isReady else { exit(1) }
            for _ in 0..<600 where !Parakeet.shared.boosting { try? await Task.sleep(for: .milliseconds(100)) }
            print("boosting:", Parakeet.shared.boosting, Parakeet.vocabulary())
            for f in files {
                let t = Date()
                let text = await Parakeet.shared.transcribe(file: URL(fileURLWithPath: f)) ?? "(nothing)"
                print(String(format: "\n== %@ (%.0f ms)\n%@", (f as NSString).lastPathComponent, Date().timeIntervalSince(t) * 1000, text))
            }
            exit(0)
        }
    }

    /// `--memory-test build` reads the history into memory with the source agent;
    /// `--memory-test "<question>" …` prints what each question would recall.
    static func memoryTest(_ args: [String]) {
        AgentRegistry.shared.refresh()
        let m = HistoryMemory.shared
        if args.first == "build" {
            let started = Date()
            print("reader:", HistoryMemory.reader().0?.name ?? HistoryMemory.reader().1 ?? "")
            m.update()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if case .updating(let i, let n) = m.state { print("reading \(i)/\(n)…"); return }
                    print("state:", m.state, "things:", m.nodes, "conversations:", m.conversations,
                          String(format: "%.0fs", Date().timeIntervalSince(started)))
                    exit(0)
                }
            }
            return
        }
        Task {
            for q in args {
                let t = Date()
                let r = await m.recall(q)
                print("Q: \(q)  [\(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) ms]")
                print(r ?? "(nothing related)", "\n")
            }
            exit(0)
        }
    }

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
        for step in 0..<5 { render(WelcomeView(step: step, done: {}), "welcome-\(step + 1)", dir) }
        for tab in [SettingsTab.source, .agents, .apps, .voice, .about] {
            render(SettingsView(tab: tab).frame(width: 820, height: tab == .voice || tab == .agents ? 1080 : 640), "settings-\(tab.id.split(separator: " ").first!.lowercased())", dir)
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

    /// `Agent2 --handsfree-test`: starts a hands-free conversation for 25 seconds and
    /// prints when speech starts and ends and what was heard (nothing is sent to an agent).
    static func handsFreeTest() {
        let t0 = Date()
        HandsFree.trace = { print(String(format: "%5.1fs  %@", Date().timeIntervalSince(t0), $0)) }
        Task { @MainActor in
            await HandsFree.shared.begin()
            print("listening: \(HandsFree.shared.isOn)  \(HandsFree.shared.problem ?? "")")
            try? await Task.sleep(for: .seconds(25))
            HandsFree.shared.end()
            exit(0)
        }
    }

    /// `Agent2 --dictation-test <audio file>`: plays a recording into speech recognition
    /// in real time, the way the microphone would, through the old single recognition
    /// task and through `RollingTranscriber`, and prints what each one heard.
    static func dictationTest(_ path: String) {
        Task { @MainActor in
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                  let recognizer = SFSpeechRecognizer() else { print("can't open \(path)"); exit(1) }
            _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            let legacy = SFSpeechAudioBufferRecognitionRequest()
            legacy.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { legacy.requiresOnDeviceRecognition = true }
            var legacyText = ""
            let legacyTask = recognizer.recognitionTask(with: legacy) { r, _ in
                if let t = r?.bestTranscription.formattedString { legacyText = t }
            }
            let rolling = RollingTranscriber(recognizer: recognizer)
            rolling.start()
            let format = file.processingFormat
            let chunk = AVAudioFrameCount(format.sampleRate / 10)
            let t0 = Date()
            while file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                try? file.read(into: buf, frameCount: chunk)
                if buf.frameLength == 0 { break }
                legacy.append(buf)
                rolling.append(buf)
                try? await Task.sleep(for: .milliseconds(100))
            }
            let secs = Date().timeIntervalSince(t0)
            legacy.endAudio()
            try? await Task.sleep(for: .milliseconds(450))   // what the old stop() waited
            let old = legacyText
            legacyTask.cancel()
            let new = await rolling.finish(timeout: min(6, 1.5 + secs * 0.03))
            print(String(format: "audio: %.0fs", secs))
            print("OLD (\(old.split(separator: " ").count) words): \(old)\n")
            print("NEW (\(new.split(separator: " ").count) words): \(new)")
            exit(0)
        }
    }

    /// `Agent2 --cursor-demo [seconds]`: shows the companion cursor on screen (also
    /// in screenshots) running a scripted tour of moves and clicks, then idles so
    /// CPU use can be checked, then quits. Prints a line at each step.
    static func cursorDemo() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let c = CompanionCursor.shared
        c.capturable = true
        CompanionCursor.trace = true
        c.start()
        let s = NSScreen.screens[0].frame
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: s.minX + s.width * fx, y: s.minY + s.height * fy) }
        let tour: [(Double, CGPoint, String)] = [
            (0.5, at(0.25, 0.70), "move"), (1.6, at(0.62, 0.55), "click"), (2.8, at(0.40, 0.30), "double"),
            (4.0, at(0.75, 0.25), "move"), (4.9, at(0.70, 0.72), "right"), (6.0, at(0.30, 0.45), "drag"),
        ]
        let t0 = Date()
        for (delay, p, kind) in tour {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                print(String(format: "%5.2fs  %@ → (%.0f, %.0f)", Date().timeIntervalSince(t0), kind, p.x, p.y))
                c.agentAction(at: p, kind: kind)
            }
        }
        let total = Double(CommandLine.arguments.last.flatMap(Double.init) ?? 16)
        // AGENT2_CURSOR_FRAMES=<dir>: save what the overlay shows at moments of the tour.
        if let dir = ProcessInfo.processInfo.environment["AGENT2_CURSOR_FRAMES"] {
            for t in [0.62, 0.75, 1.8, 1.95, 2.25, 2.6, 3.06, 3.2, 3.5, 5.75, 6.45, 6.75] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    guard let view = NSApp.windows.first?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "f-%.2f.png", t)))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { print("done"); exit(0) }
        app.run()
    }
}
