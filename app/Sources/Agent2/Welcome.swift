import AppKit
import AVFoundation
import Speech
import SwiftUI

/// The first-run tutorial: what Agent2 is, picking the agent that does the work,
/// the three permissions, a first try of ⌃⌥, and what else it can do. Shown once
/// after install, and again from the menu ("Show tutorial") or Settings → About.
@MainActor
enum Welcome {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Welcome to Agent2"
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(Theme.bg)
            w.center()
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: WelcomeView(done: { close() }))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct WelcomeView: View {
    let done: () -> Void

    init(step: Int = 0, done: @escaping () -> Void) {
        self.done = done
        _step = State(initialValue: step)
    }

    @ObservedObject private var registry = AgentRegistry.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var parakeet = Parakeet.shared
    @ObservedObject private var kokoro = Kokoro.shared
    @State private var step = 0
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var accessibility = HotkeyMonitor.ensureAccessibility(prompt: false)
    @State private var screen = ScreenLook.allowed
    @State private var heard = false
    private let poll = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private let titles = ["Welcome", "Your agent", "Permissions", "Try it", "You're set"]

    var body: some View {
        VStack(spacing: 0) {
            // Progress: one segment per step.
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Rectangle().fill(i <= step ? Theme.green : Theme.borderStrong).frame(height: 2)
                }
            }
            .padding(.horizontal, 28).padding(.top, 40)
            HStack {
                MonoLabel(text: "Step \(step + 1) of \(titles.count) · \(titles[step])")
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) { page }
                    .padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rule()
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(SecondaryButtonStyle()) }
                Spacer()
                if step < titles.count - 1 {
                    if step > 0 { Button("Skip") { step += 1 }.buttonStyle(SecondaryButtonStyle()) }
                    Button(step == 0 ? "Get started" : "Continue") { step += 1 }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start using Agent2") { done() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 620, height: 560)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onReceive(poll) { _ in refresh() }
        .onAppear {
            registry.refresh()
            // Get the on-device voice models downloading while they read.
            parakeet.prepareIfChosen()
            if settings.voiceEngine == .kokoro { kokoro.prepare() }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: agent
        case 2: permissions
        case 3: tryIt
        default: finish
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            BirdMark(size: 44)
            heading("Meet Agent2, help you can talk to.")
            para("Ask for something out loud, like you would a capable assistant. Agent2 hands it to the AI agent on your Mac (Claude Code, Codex, Gemini…), which does the work, and Agent2 tells you what was done.")
            para(NotchGeometry.find() == nil
                 ? "It lives in your menu bar as a small bird. Click it any time to type or see what's happening."
                 : "It lives in your Mac's notch. Click the notch any time to type or see what's happening.")
            bullet("Speak", "Hold Control + Option, talk, let go.")
            bullet("Type", "Tap Control + Option, or click the bird.")
            bullet("Private", "Your voice is turned into text on this Mac. Nothing is recorded or uploaded by Agent2.")
        }
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Pick the agent that does the work.")
            para("This is your source agent. It uses your own subscription or API key, and you can change it any time in Settings.")
            if registry.agents.filter(\.canRunHeadless).isEmpty {
                Card {
                    Text("No agents found yet").font(.system(size: 13, weight: .medium))
                    Text("Install one, sign in to it once in Terminal, then come back and press Scan again:")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    code("npm i -g @anthropic-ai/claude-code")
                    code("npm i -g @openai/codex")
                    Text("Or add an Anthropic or OpenAI API key in Settings → Agents.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            } else {
                RuledList(title: "Found on this Mac", trailing: "\(registry.agents.filter(\.canRunHeadless).count)") {
                    ForEach(registry.agents.filter(\.canRunHeadless)) { a in
                        let on = settings.sourceAgentID == a.id
                        Rule()
                        Button { settings.sourceAgentID = a.id } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Rectangle().stroke(on ? Theme.green : Theme.borderStrong)
                                    if on { Rectangle().fill(Theme.green).padding(3) }
                                }.frame(width: 14, height: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).font(.system(size: 13, weight: .medium))
                                    Text(a.strengths).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if on { Tag(text: "✓ Source", tone: .ok) }
                            }
                            .padding(12)
                            .background(on ? Theme.greenWash : .clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button("Scan again") { registry.refresh() }.buttonStyle(SecondaryButtonStyle())
        }
        .onAppear {
            // Nothing chosen yet: start with the first agent found.
            if settings.sourceAgentID.isEmpty, let first = registry.agents.first(where: \.canRunHeadless) {
                settings.sourceAgentID = first.id
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Let Agent2 hear you.")
            para("macOS asks you about each of these once.")
            RuledList(title: "Permissions") {
                Rule()
                permissionRow("Microphone", "to hear what you say", granted: mic == .authorized,
                              denied: mic == .denied || mic == .restricted, settingsPane: "Privacy_Microphone") {
                    Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refresh() }
                }
                Rule()
                permissionRow("Speech recognition", "to show your words live while you talk", granted: speech == .authorized,
                              denied: speech == .denied || speech == .restricted, settingsPane: "Privacy_SpeechRecognition") {
                    SFSpeechRecognizer.requestAuthorization { _ in Task { @MainActor in refresh() } }
                }
                Rule()
                permissionRow("Accessibility", "so Control + Option works in every app", granted: accessibility,
                              denied: false, settingsPane: "Privacy_Accessibility") {
                    accessibility = HotkeyMonitor.ensureAccessibility(prompt: true)
                }
                Rule()
                permissionRow("Screen Recording", "so your agent can see what you're pointing at", granted: screen,
                              denied: false, settingsPane: "Privacy_ScreenCapture") {
                    ScreenLook.request()
                }
            }
            if !accessibility || !screen {
                para("For Accessibility and Screen Recording, macOS opens System Settings: switch Agent2 on in the list, then come back here.")
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Try it now.")
            HStack(spacing: 6) {
                key("⌃ control"); Text("+").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.dim); key("⌥ option")
            }
            para("Hold both keys, say \u{201C}Open Calculator\u{201D}, then let go.")
            HStack(spacing: 10) {
                if heard {
                    Tag(text: "✓ Heard you", tone: .ok)
                    Text("That's all there is to it.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                } else {
                    Tag(text: "Waiting for ⌃⌥", tone: .run)
                    Text(accessibility ? "Hold the keys while you speak." : "Grant Accessibility on the previous step first.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
            }
            Card(title: "Good first things to say") {
                example("Open Safari", "apps open instantly")
                example("Turn the volume down", "")
                example("What's on my calendar tomorrow?", "needs your calendar connected under Apps")
                example("Make a short packing list for a weekend trip", "your agent writes it and saves it")
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("You're set.")
            para("A few things worth knowing:")
            bullet("Hands-free", "Prefer a conversation? Settings → Voice & hotkey → Hands-free. Tap ⌃⌥ once and talk back and forth.")
            bullet("Interrupt", "Click the bird or tap ⌃⌥ to stop Agent2 talking.")
            bullet("Memory", "Agent2 remembers past conversations, so you can say \u{201C}like last time\u{201D}.")
            bullet("Models", "Choose which model each agent uses in Settings → Agents.")
            bullet("Apps", "Connect Gmail, Slack, GitHub and more in Settings → Apps.")
            Card(title: "Getting voice ready on this Mac") {
                voiceRow("Speech recognition (Parakeet)", parakeetStatus)
                voiceRow("Voice (Kokoro)", kokoroStatus)
                Text("Agent2 works while these download; it uses Apple's built-in voice until they're ready.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text("You can see this tutorial again from the bird's right-click menu.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: Pieces

    private func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        speech = SFSpeechRecognizer.authorizationStatus()
        accessibility = HotkeyMonitor.ensureAccessibility(prompt: false)
        screen = ScreenLook.allowed
        if step == 3, IndicatorModel.shared.phase != .idle { heard = true }
    }

    private var parakeetStatus: (String, Tag.Tone) {
        if settings.dictationEngine == .apple { return ("Using Apple's", .plain) }
        switch parakeet.state {
        case .ready: return ("✓ Ready", .ok)
        case .downloading: return ("Downloading \(Parakeet.downloadSize)…", .run)
        case .failed: return ("Will retry", .warn)
        case .notInstalled: return ("Waiting", .plain)
        }
    }

    private var kokoroStatus: (String, Tag.Tone) {
        if settings.voiceEngine == .system { return ("Using macOS voice", .plain) }
        switch kokoro.state {
        case .ready: return ("✓ Ready", .ok)
        case .downloading: return ("Downloading…", .run)
        case .failed: return ("Will retry", .warn)
        case .notInstalled: return ("Waiting", .plain)
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }

    private func para(_ s: String) -> some View {
        Text(s).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).frame(width: 84, alignment: .leading)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func example(_ said: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{201C}\(said)\u{201D}").font(.system(size: 12.5))
            if !note.isEmpty { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.dim) }
        }
    }

    private func code(_ s: String) -> some View {
        Text(s).font(Theme.mono).textSelection(.enabled)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.panelRaised).overlay(Rectangle().stroke(Theme.border))
    }

    private func key(_ s: String) -> some View {
        Text(s).font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panelRaised).overlay(Rectangle().stroke(Theme.borderStrong))
    }

    private func voiceRow(_ name: String, _ status: (String, Tag.Tone)) -> some View {
        HStack { Text(name).font(.system(size: 12.5)); Spacer(); Tag(text: status.0, tone: status.1) }
    }

    private func permissionRow(_ name: String, _ why: String, granted: Bool, denied: Bool, settingsPane: String,
                               grant: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12.5, weight: .medium))
                Text(why).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if granted {
                Tag(text: "✓ Granted", tone: .ok)
            } else if denied {
                // macOS won't ask twice: send them to the right page of System Settings.
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)")!)
                }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Allow", action: grant).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 14).frame(height: 52)
    }
}
