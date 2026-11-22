import SwiftUI

/// The menu-bar popover.
struct ChatView: View {
    @ObservedObject var orchestrator = Orchestrator.shared
    @ObservedObject var registry = AgentRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var voice: VoiceInput
    var openSettings: () -> Void
    var openHistory: () -> Void
    var toggleMic: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            messages
            if voice.isListening || !orchestrator.status.isEmpty { statusBar }
            Divider().overlay(Theme.border)
            composer
        }
        .frame(width: 440, height: 580)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BirdMark(size: 20)
            Text("Agent2").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            Menu {
                ForEach(registry.agents) { a in
                    Button { settings.sourceAgentID = a.id } label: {
                        Label(a.name, systemImage: a.id == settings.sourceAgentID ? "checkmark" : "circle")
                    }
                }
                Divider()
                Button("Agent settings…", action: openSettings)
            } label: {
                Pill(text: registry.source?.name ?? "No source")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The source agent is Agent2's brain. Only you change it.")
            Spacer()
            iconButton("plus.bubble", "New conversation") { orchestrator.newConversation() }
            iconButton("clock.arrow.circlepath", "History", action: openHistory)
            iconButton("gearshape", "Settings", action: openSettings)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain).help(help)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 14) {
            Text("What should your agents do?")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            Text("Hold **⌃ Control + ⌥ Option** anywhere and talk, or type below. Agent2 routes the work to \(registry.source?.name ?? "your agent") and the other agents it found on this Mac.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Summarise my unread Gmail from today",
                         "Have Codex add tests to my project while Claude reviews the README",
                         "What did we decide last week about the website?"], id: \.self) { s in
                    Button { draft = s; focused = true } label: {
                        HStack {
                            Image(systemName: "arrow.turn.down.right").foregroundStyle(Theme.green)
                            Text(s).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .padding(9)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(registry.agents.filter(\.canRunHeadless).prefix(4)) { Pill(text: $0.name, color: Theme.muted) }
            }
        }
        .padding(.top, 24)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if voice.isListening {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .scaleEffect(1 + CGFloat(voice.level) * 0.8)
                Text(voice.transcript.isEmpty ? "Listening… release ⌃⌥ to send" : voice.transcript)
                    .lineLimit(2)
            } else {
                ProgressView().controlSize(.small)
                Text(orchestrator.status).lineLimit(1)
                Spacer()
                Button("Stop") { orchestrator.stop() }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .font(Theme.mono).foregroundStyle(Theme.muted)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask Agent2…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit(send)
            Button(action: toggleMic) {
                Image(systemName: voice.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(voice.isListening ? Color.red : Theme.muted)
            }.buttonStyle(.plain).help("Talk (or hold ⌃⌥)")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(draft.isEmpty ? Theme.panelRaised : Theme.green, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || orchestrator.isWorking)
        }
        .padding(12)
        .background(Theme.panel)
    }

    private func send() {
        orchestrator.send(draft)
        draft = ""
    }
}

struct TurnView: View {
    let turn: Turn
    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(Theme.green.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.green.opacity(0.5)))
                    .foregroundStyle(Theme.text)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) { BirdMark(size: 11); Text(turn.agent).font(Theme.mono).foregroundStyle(Theme.muted) }
                Text(markdown(turn.text))
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            }
        case .activity:
            DisclosureGroup {
                Text(turn.text).font(Theme.mono).foregroundStyle(Theme.muted).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: turn.agent.contains("→") ? "arrow.triangle.branch" : "terminal")
                        .foregroundStyle(Theme.green)
                    Text(turn.agent).font(Theme.mono).foregroundStyle(Theme.muted)
                }
            }
            .padding(8)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
