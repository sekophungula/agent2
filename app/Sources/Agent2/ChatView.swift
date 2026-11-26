import SwiftUI

/// The menu-bar popover.
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
            Rule()
            if let banner = updateBanner { banner; Rule() }
            sourceBar
            Rule()
            messages
            if voice.isListening || !orchestrator.status.isEmpty { Rule(); statusBar }
            Rule()
            composer
        }
        .frame(width: 440, height: 580)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            BirdMark(size: 18)
            Text("Agent2").font(.system(size: 14, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.text)
            Spacer()
            iconButton("plus", "New conversation") { orchestrator.newConversation() }
            iconButton("clock.arrow.circlepath", "History", action: openHistory)
            iconButton("gearshape", "Settings", action: openSettings)
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
        .background(Theme.panel)
    }

    /// A strip under the header while an update is available or installing.
    private var updateBanner: AnyView? {
        let text: String, button: AnyView?
        switch updater.state {
        case .available(let r):
            text = "v\(r.version) is available"
            button = AnyView(Button("Update") { Task { await updater.install(r) } }.buttonStyle(AccentButtonStyle()))
        case .downloading(let p):
            text = "Downloading update · \(Int(p * 100))%"; button = AnyView(ProgressView().controlSize(.small))
        case .installing:
            text = "Installing · Agent2 will reopen"; button = AnyView(ProgressView().controlSize(.small))
        default:
            return nil
        }
        return AnyView(
            HStack(spacing: 10) {
                Rectangle().fill(Theme.green).frame(width: 7, height: 7)
                Text(text).font(Theme.mono).foregroundStyle(Theme.text)
                Spacer()
                button
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(Theme.greenWash)
        )
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28)
                .overlay(Sq().stroke(Theme.border))
        }
        .buttonStyle(.plain).help(help)
    }

    /// `~/Agent2 / source: Claude Code   [✓ LIVE]` — the console breadcrumb.
    private var sourceBar: some View {
        HStack(spacing: 8) {
            Text("~/Agent2").foregroundStyle(Theme.muted)
            Text("/").foregroundStyle(Theme.dim)
            Menu {
                ForEach(registry.agents) { a in
                    Button { settings.sourceAgentID = a.id } label: {
                        Label(a.name, systemImage: a.id == settings.sourceAgentID ? "checkmark" : "circle")
                    }
                }
                Divider()
                Button("Agent settings…", action: openSettings)
            } label: {
                HStack(spacing: 4) {
                    Text("source:").foregroundStyle(Theme.muted)
                    Text(registry.source?.name ?? "none").foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .font(.system(size: 11, design: .monospaced))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The source agent is Agent2's brain. Only you change it.")
            Spacer()
            if orchestrator.isWorking { Tag(text: "Working", tone: .run) }
            else if registry.source != nil { Tag(text: "✓ Ready", tone: .ok) }
            else { Tag(text: "No source", tone: .warn) }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 14).frame(height: 34)
    }

    // MARK: messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if orchestrator.conversation.turns.isEmpty { emptyState }
                    ForEach(orchestrator.conversation.turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: orchestrator.conversation.turns.count) { _, _ in
                if let last = orchestrator.conversation.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel(text: "// Ready", color: Theme.greenBright)
            Text("What should your agents do?")
                .font(.system(size: 22, weight: .semibold)).tracking(-0.6).foregroundStyle(Theme.text)
                .padding(.top, 10)
            Text("Hold **⌃ Control + ⌥ Option** anywhere and talk, or type below. Agent2 routes the work to \(registry.source?.name ?? "your agent") and the other agents on this Mac.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(2)
                .padding(.top, 8)

            VStack(spacing: 0) {
                HStack { MonoLabel(text: "Try"); Spacer() }
                    .padding(.horizontal, 12).frame(height: 30).background(Theme.panel)
                ForEach(["Summarise my unread Gmail from today",
                         "Have Codex add tests while Claude reviews the README",
                         "What did we decide last week about the website?"], id: \.self) { s in
                    Rule()
                    Button { draft = s; focused = true } label: {
                        HStack(spacing: 10) {
                            Text("→").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.greenBright)
                            Text(s).font(.system(size: 12)).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .overlay(Rectangle().stroke(Theme.border))
            .padding(.top, 18)

            VStack(spacing: 0) {
                HStack { MonoLabel(text: "Agents on this Mac"); Spacer(); MonoLabel(text: "\(registry.agents.count)") }
                    .padding(.horizontal, 12).frame(height: 30).background(Theme.panel)
                ForEach(registry.agents.prefix(5)) { a in
                    Rule()
                    HStack {
                        Text(a.name).font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        Tag(text: a.id == settings.sourceAgentID ? "✓ Source" : a.kind == .cli ? "CLI" : a.kind == .api ? "API" : "Desktop",
                            tone: a.id == settings.sourceAgentID ? .ok : .plain)
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                }
            }
            .overlay(Rectangle().stroke(Theme.border))
            .padding(.top, 12)
        }
        .padding(.top, 10)
    }

    // MARK: status + composer

    private var statusBar: some View {
        HStack(spacing: 8) {
            if voice.isListening {
                Rectangle().fill(Theme.red).frame(width: 7, height: 7)
                    .opacity(0.5 + Double(voice.level) * 0.5)
                Text(voice.transcript.isEmpty ? "Listening… release ⌃⌥ to send" : voice.transcript)
                    .lineLimit(2)
            } else {
                ProgressView().controlSize(.mini)
                Text(orchestrator.status).lineLimit(1)
                Spacer()
                Button("Stop") { orchestrator.stop() }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .font(Theme.mono).foregroundStyle(Theme.muted)
        .padding(.horizontal, 14).frame(minHeight: 38)
        .background(Theme.panel)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(">").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.greenBright)
                TextField("Ask Agent2…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit(send)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(Theme.bg, in: Sq())
            .overlay(Sq().stroke(focused ? Theme.borderStrong : Theme.border))

            Button(action: toggleMic) {
                Image(systemName: voice.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(voice.isListening ? Theme.red : Theme.muted)
                    .frame(width: 34, height: 34)
                    .overlay(Sq().stroke(voice.isListening ? Theme.red : Theme.border))
            }.buttonStyle(.plain).help("Talk (or hold ⌃⌥)")

            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.white : Theme.panelRaised, in: Sq())
                    .foregroundStyle(canSend ? Theme.bg : Theme.dim)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(12)
        .background(Theme.panel)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !orchestrator.isWorking }

    private func send() {
        guard canSend else { return }
        orchestrator.send(draft)
        draft = ""
    }
}

struct TurnView: View {
    let turn: Turn
    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .leading, spacing: 6) {
                MonoLabel(text: "You")
                Text(turn.text)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.panel)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.borderStrong).frame(width: 2) }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { BirdMark(size: 10); MonoLabel(text: turn.agent, color: Theme.greenBright) }
                Text(markdown(turn.text))
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .activity:
            DisclosureGroup {
                Text(turn.text).font(Theme.mono).foregroundStyle(Theme.muted).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 8) {
                    Text("==>").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                    Text(turn.agent).font(Theme.mono).foregroundStyle(Theme.text)
                    Spacer()
                    Tag(text: turn.agent.contains("→") ? "Delegated" : "✓ Done", tone: turn.agent.contains("→") ? .plain : .ok)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.border))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
