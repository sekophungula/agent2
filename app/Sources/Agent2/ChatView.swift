import SwiftUI

/// The chat panel under the notch or menu bar bird: a quiet, rounded card with
/// the conversation, a big hold-to-talk button and a follow-up field.
struct ChatView: View {
    @ObservedObject var orchestrator = Orchestrator.shared
    @ObservedObject var registry = AgentRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updater = Updater.shared
    @ObservedObject var voice: VoiceInput
    var openSettings: () -> Void
    var openHistory: () -> Void
    var toggleMic: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = updateBanner { banner.padding(.horizontal, 14).padding(.bottom, 8) }
            messages
            composer
        }
        .frame(width: 420, height: 560)
        .background(Chat.bg)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BirdMark(size: 16)
            sourceMenu
            Spacer()
            iconButton("square.and.pencil", "New conversation") { orchestrator.newConversation() }
            iconButton("clock", "History", action: openHistory)
            iconButton("gearshape", "Settings", action: openSettings)
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 50)
    }

    /// Which agent does the work, as a small pill with a status dot.
    private var sourceMenu: some View {
        Menu {
            ForEach(registry.agents.filter(\.canRunHeadless)) { a in
                Button { settings.sourceAgentID = a.id } label: {
                    if a.id == settings.sourceAgentID { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                }
            }
            Divider()
            Button("Agent settings…", action: openSettings)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(registry.source?.name ?? "No agent").font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Chat.faint)
            }
            .foregroundStyle(Chat.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Chat.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("The agent that does the work. Only you change it.")
    }

    private var statusColor: Color {
        if registry.source == nil { return Theme.amber }
        return orchestrator.isWorking ? Theme.amber : Theme.greenBright
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(Chat.faint)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle()).help(help)
    }

    /// While an update is available or installing.
    private var updateBanner: AnyView? {
        let text: String, button: AnyView?
        switch updater.state {
        case .available(let r):
            text = "Agent2 \(r.version) is ready"
            button = AnyView(Button("Update") { Task { await updater.install(r) } }.buttonStyle(PillButtonStyle(filled: true)))
        case .downloading(let p):
            text = "Downloading update · \(Int(p * 100))%"; button = AnyView(ProgressView().controlSize(.small))
        case .installing:
            text = "Installing · Agent2 will reopen"; button = AnyView(ProgressView().controlSize(.small))
        default:
            return nil
        }
        return AnyView(
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.greenBright)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Chat.text)
                Spacer()
                button
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
            .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
    }

    // MARK: Conversation

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if orchestrator.conversation.turns.isEmpty, !voice.isListening { emptyState }
                    ForEach(orchestrator.conversation.turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                    if voice.isListening { listeningBubble.id("live") }
                    else if orchestrator.isWorking { workingRow.id("live") }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: orchestrator.conversation.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: orchestrator.isWorking) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: voice.isListening) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about anything on your screen.")
                .font(.system(size: 21, weight: .semibold)).foregroundStyle(Chat.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hold ⌃ Control + ⌥ Option and talk. Point at what you mean while you ask, and Agent2 will see it.")
                .font(.system(size: 13.5)).foregroundStyle(Chat.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["What does this button do?", "Summarise this page for me", "Open Safari"], id: \.self) { s in
                    Button { draft = s; focused = true } label: {
                        Text(s).font(.system(size: 13)).foregroundStyle(Chat.text)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(Chat.raised, in: Capsule())
                    }.buttonStyle(HoverButtonStyle(shape: AnyShape(Capsule())))
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 26)
    }

    /// What you're saying, live, as a faint bubble of your own.
    private var listeningBubble: some View {
        HStack {
            Spacer(minLength: 50)
            HStack(spacing: 8) {
                Circle().fill(Theme.red).frame(width: 7, height: 7).opacity(0.45 + Double(voice.level) * 0.55)
                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                    .font(.system(size: 14)).foregroundStyle(Chat.text.opacity(0.75))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Chat.bubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var workingRow: some View {
        HStack(spacing: 10) {
            ThinkingDots()
            Text(orchestrator.status.isEmpty ? "Thinking…" : orchestrator.status)
                .font(.system(size: 13)).foregroundStyle(Chat.muted).lineLimit(1)
            Spacer()
            Button("Stop") { orchestrator.stop() }.buttonStyle(PillButtonStyle(filled: false))
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            Button(action: toggleMic) {
                HStack(spacing: 7) {
                    Image(systemName: voice.isListening ? "waveform" : "mic.fill").font(.system(size: 12, weight: .semibold))
                    Text(voice.isListening ? "Listening… tap to send" : "Hold ⌃⌥ to talk")
                        .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(voice.isListening ? Color.white : Chat.bg)
                .padding(.horizontal, 14).frame(height: 38)
                .background(voice.isListening ? Theme.red : Theme.greenBright, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Click to talk, click again to send. Or hold ⌃ Control + ⌥ Option anywhere.")

            HStack(spacing: 6) {
                TextField(orchestrator.conversation.turns.isEmpty ? "Ask anything…" : "Follow up…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Chat.text)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(canSend ? Chat.bg : Chat.faint)
                        .frame(width: 26, height: 26)
                        .background(canSend ? Chat.text : Chat.bubble, in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Chat.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Chat.stroke : .clear, lineWidth: 1))
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !orchestrator.isWorking }

    private func send() {
        guard canSend else { return }
        orchestrator.send(draft)
        draft = ""
    }
}

/// The chat panel's own palette: a little lifted from Theme's near-black, so
/// the card reads as soft rather than a terminal.
enum Chat {
    static let bg = Color(hex: 0x161616)
    static let raised = Color(hex: 0x232323)
    static let bubble = Color(hex: 0x2E2E2E)
    static let stroke = Color(hex: 0x3A3A3A)
    static let text = Color(hex: 0xF2F2F2)
    static let muted = Color(hex: 0xA3A3A3)
    static let faint = Color(hex: 0x7A7A7A)
}

struct TurnView: View {
    let turn: Turn
    @State private var open = false

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(turn.text)
                    .textSelection(.enabled)
                    .font(.system(size: 14))
                    .foregroundStyle(Chat.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Chat.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(markdown(turn.text))
                    .textSelection(.enabled)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundStyle(Chat.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    BirdMark(size: 9, color: Chat.faint)
                    Text(turn.agent).font(.system(size: 11)).foregroundStyle(Chat.faint)
                }
            }
        case .activity:
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: turn.agent.contains("→") ? "arrow.turn.down.right" : "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(turn.agent.contains("→") ? Chat.faint : Theme.greenBright)
                        Text(turn.agent).font(.system(size: 12)).foregroundStyle(Chat.muted)
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Chat.faint)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if open {
                    Text(turn.text).font(.system(size: 12)).foregroundStyle(Chat.muted).textSelection(.enabled)
                        .lineSpacing(2)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Chat.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Three dots that breathe while the agent works.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.greenBright)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * (0.5 + 0.5 * sin(s * 5 - Double(i) * 0.9)))
                }
            }
        }
    }
}

/// A rounded button: green filled, or a quiet outline.
struct PillButtonStyle: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? Chat.bg : Chat.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(filled ? Theme.greenBright : Chat.raised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A plain button that lightens on hover.
struct HoverButtonStyle: ButtonStyle {
    var shape = AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    func makeBody(configuration: Configuration) -> some View { Hovering(configuration: configuration, shape: shape) }

    private struct Hovering: View {
        let configuration: ButtonStyleConfiguration
        let shape: AnyShape
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(shape.fill(Color.white.opacity(hover ? 0.07 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hover = $0 }
        }
    }
}
