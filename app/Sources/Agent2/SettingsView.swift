import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case source = "Source", agents = "Agents", apps = "Apps (Composio)", history = "History", voice = "Voice & hotkey", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .source: return "point.3.connected.trianglepath.dotted"
        case .agents: return "square.stack.3d.up"
        case .apps: return "square.grid.2x2"
        case .history: return "doc.text"
        case .voice: return "mic"
        case .about: return "info.square"
        }
    }
    var blurb: String {
        switch self {
        case .source: return "The agent Agent2 thinks with. Only you change it."
        case .agents: return "Who the source may delegate to, and what they may do."
        case .apps: return "Link accounts once through Composio. Every agent can use them."
        case .history: return "Markdown files that belong to Agent2, not to any one agent."
        case .voice: return "Push-to-talk with ⌃ Control + ⌥ Option."
        case .about: return "The middleman for your AI agents."
        }
    }
}

struct SettingsView: View {
    @State var tab: SettingsTab
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel(text: "// Settings", color: Theme.greenBright)
                        Text(tab.rawValue).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                        Text(tab.blurb).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
                    Rule()
                    VStack(alignment: .leading, spacing: 16) {
                        switch tab {
                        case .source: SourceTab()
                        case .agents: AgentsTab()
                        case .apps: AppsTab()
                        case .history: HistoryTab()
                        case .voice: VoiceTab()
                        case .about: AboutTab()
                        }
                    }
                    .padding(28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BirdMark(size: 18)
                Text("Agent2").font(.system(size: 14, weight: .semibold)).tracking(-0.2)
                Spacer()
                Tag(text: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev")
            }
            .padding(.horizontal, 16).frame(height: 52)
            Rule()
            MonoLabel(text: "Configure").padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
            ForEach(SettingsTab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol).font(.system(size: 11)).frame(width: 16)
                        Text(t.rawValue.uppercased())
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced)).tracking(0.6)
                        Spacer()
                    }
                    .foregroundStyle(tab == t ? Theme.text : Theme.muted)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(tab == t ? Theme.panelRaised : .clear)
                    .overlay(alignment: .leading) { if tab == t { Rectangle().fill(Theme.green).frame(width: 2) } }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            Rule()
            HStack(spacing: 6) {
                Rectangle().fill(Theme.green).frame(width: 8, height: 8)
                Text("LOCAL · NO SERVERS").font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 16).frame(height: 36)
        }
        .frame(width: 200)
        .background(Theme.panel)
    }
}

/// A bordered list: one header bar, rows separated by 1px rules.
struct RuledList<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack { MonoLabel(text: title); Spacer(); if let trailing { MonoLabel(text: trailing) } }
                .padding(.horizontal, 14).frame(height: 34).background(Theme.panel)
            content
        }
        .overlay(Rectangle().stroke(Theme.border))
    }
}

private struct SourceTab: View {
    @ObservedObject var registry = AgentRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Text("The source reads your request, does what it can and hands the rest to other agents. Agent2 never switches it for you. Your history stays the same either way.")
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        RuledList(title: "Detected on this Mac", trailing: "\(registry.agents.count) found") {
            ForEach(registry.agents) { a in
                let on = settings.sourceAgentID == a.id
                Rule()
                Button { settings.sourceAgentID = a.id } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Rectangle().stroke(on ? Theme.green : Theme.borderStrong)
                            if on { Rectangle().fill(Theme.green).padding(3) }
                        }
                        .frame(width: 14, height: 14).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(a.name).font(.system(size: 13, weight: .medium))
                                Tag(text: a.kind == .cli ? "CLI" : a.kind == .api ? "API key" : "Desktop · hand-off")
                            }
                            Text(a.strengths).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(a.detail.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(Theme.mono).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        if on { Tag(text: "✓ Source", tone: .ok) }
                    }
                    .padding(14)
                    .background(on ? Theme.greenWash : .clear)
                    .overlay(alignment: .leading) { if on { Rectangle().fill(Theme.green).frame(width: 2) } }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if registry.agents.isEmpty {
                Rule()
                VStack(alignment: .leading, spacing: 6) {
                    Text("No agents found yet").font(.system(size: 13, weight: .medium))
                    Text("Install Claude Code (`npm i -g @anthropic-ai/claude-code`) or Codex (`npm i -g @openai/codex`) and sign in, or add an API key under Agents.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Button("Scan again") { registry.refresh() }.buttonStyle(SecondaryButtonStyle())
    }
}

private struct AgentsTab: View {
    @ObservedObject var registry = AgentRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Card(title: "Delegation") {
            Toggle("Let the source delegate to other agents", isOn: $settings.delegatesEnabled)
            Text("When on, the source can hand parts of a job to the agents below and they run in parallel.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            ForEach(registry.agents.filter { $0.canRunHeadless && $0.id != settings.sourceAgentID }) { a in
                Toggle(a.name, isOn: Binding(
                    get: { !settings.disabledDelegateIDs.contains(a.id) },
                    set: { on in if on { settings.disabledDelegateIDs.remove(a.id) } else { settings.disabledDelegateIDs.insert(a.id) } }))
                    .disabled(!settings.delegatesEnabled)
                    .padding(.leading, 24)
            }
        }
        .toggleStyle(SquareToggleStyle())

        RuledList(title: "What agents may do") {
            ForEach(Autonomy.allCases) { level in
                let on = settings.autonomy == level
                Rule()
                Button { settings.autonomy = level } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Rectangle().stroke(on ? Theme.green : Theme.borderStrong)
                            if on { Rectangle().fill(Theme.green).padding(3) }
                        }.frame(width: 14, height: 14)
                        Text(level.label).font(.system(size: 12.5))
                        Spacer()
                        if level == .full { Tag(text: "Careful", tone: .warn) }
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(on ? Theme.greenWash : .clear)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Rule()
            VStack(alignment: .leading, spacing: 8) {
                fieldRow("Workspace") { TextField("", text: $settings.workspaceFolder).squareField() }
                Text("Applies to Claude Code, Codex, Gemini and Cursor. They work inside this folder.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            .padding(14)
        }

        Card(title: "API keys · optional", trailing: AnyView(Tag(text: "Keychain"))) {
            Text("Use these if you'd rather pay per use than use a subscription CLI.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            fieldRow("Anthropic") { SecureField("sk-ant-…", text: $settings.anthropicKey).squareField() }
            fieldRow("Model") { TextField("", text: $settings.anthropicModel).squareField() }
            fieldRow("OpenAI") { SecureField("sk-…", text: $settings.openAIKey).squareField() }
            fieldRow("Model") { TextField("", text: $settings.openAIModel).squareField() }
            HStack { Spacer(); Button("Save and rescan") { registry.refresh() }.buttonStyle(PrimaryButtonStyle()) }
        }
    }

    private func fieldRow<F: View>(_ label: String, @ViewBuilder field: () -> F) -> some View {
        HStack(spacing: 12) {
            MonoLabel(text: label).frame(width: 84, alignment: .leading)
            field()
        }
    }
}

private struct AppsTab: View {
    @ObservedObject var composio = ComposioService.shared
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 0)]
    var body: some View {
        Card(title: "Composio account", trailing: AnyView(accountTag)) {
            if !composio.isInstalled {
                Text("The Composio CLI isn't installed. Install it once, then come back to sign in and link apps.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Button("Install Composio") { composio.openInstallPage() }.buttonStyle(PrimaryButtonStyle())
            } else if !composio.isSignedIn {
                Text("Sign in to link Gmail, Slack, GitHub, X, LinkedIn and hundreds more.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Button("Sign in with browser") { Task { await composio.signIn() } }.buttonStyle(PrimaryButtonStyle())
            } else {
                HStack {
                    Text(composio.account ?? "Signed in").font(.system(size: 12.5, design: .monospaced))
                    Spacer()
                    Button("Refresh") { Task { await composio.refresh() } }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if let busy = composio.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(busy).font(Theme.mono).foregroundStyle(Theme.muted) }
            }
            if let err = composio.lastError { Text(err).font(Theme.mono).foregroundStyle(Theme.red) }
        }

        RuledList(title: "Already linked to your agents?") {
            statusRow("Claude Code", composio.linkedInClaudeCode)
            statusRow("Codex", composio.linkedInCodex)
            if !(composio.linkedInClaudeCode && composio.linkedInCodex) {
                Rule()
                HStack {
                    Text("Add Composio to the agents that don't have it yet.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Add to my agents") { Task { await composio.connectAgents() } }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!composio.isSignedIn)
                }
                .padding(.horizontal, 14).frame(height: 44)
            }
        }

        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "Apps")
                Spacer()
                MonoLabel(text: "\(composio.connections.count) linked")
            }
            .padding(.horizontal, 14).frame(height: 34).background(Theme.panel)
            Rule()
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(ComposioService.popular) { tk in
                    let linked = composio.connections.contains { $0.toolkit.lowercased() == tk.id && $0.status != "failed" }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: tk.symbol).font(.system(size: 10))
                                .frame(width: 20, height: 20)
                                .background(Theme.panelRaised)
                                .overlay(Rectangle().stroke(Theme.borderStrong))
                                .foregroundStyle(Theme.muted)
                            Text(tk.name).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        if linked {
                            Text("✓ LINKED").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.6)
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(Theme.greenWash)
                                .overlay(Rectangle().stroke(Theme.greenBright.opacity(0.35)))
                                .foregroundStyle(Theme.greenBright)
                        } else {
                            Button { Task { await composio.link(tk.id) } } label: { Text("Link").frame(maxWidth: .infinity) }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(!composio.isSignedIn || composio.busy != nil)
                        }
                    }
                    .padding(12)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
        .overlay(Rectangle().stroke(Theme.border))

        let others = composio.connections.filter { c in !ComposioService.popular.contains { $0.id == c.toolkit.lowercased() } }
        if !others.isEmpty {
            Text("Also linked: " + others.map(\.toolkit).joined(separator: ", ")).font(Theme.mono).foregroundStyle(Theme.muted)
        }
    }

    private var accountTag: some View {
        Group {
            if composio.isSignedIn { Tag(text: "✓ Signed in", tone: .ok) }
            else if composio.isInstalled { Tag(text: "Signed out") }
            else { Tag(text: "Not installed", tone: .warn) }
        }
    }

    private func statusRow(_ name: String, _ ok: Bool) -> some View {
        VStack(spacing: 0) {
            Rule()
            HStack {
                Text(name).font(.system(size: 12.5))
                Spacer()
                Tag(text: ok ? "✓ Composio linked" : "Not linked", tone: ok ? .ok : .plain)
            }
            .padding(.horizontal, 14).frame(height: 40)
        }
    }
}

private struct HistoryTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var items: [(title: String, date: Date, url: URL)] = []
    var body: some View {
        Card(title: "Storage") {
            HStack(spacing: 8) {
                TextField("", text: $settings.historyFolder).squareField()
                Button("Reveal") { NSWorkspace.shared.open(HistoryStore.folder) }.buttonStyle(SecondaryButtonStyle())
            }
            HStack {
                Text("Recent turns sent to agents as context").font(.system(size: 12.5))
                Spacer()
                Stepper(value: $settings.contextTurns, in: 2...40) {
                    Text("\(settings.contextTurns)").font(.system(size: 12, design: .monospaced))
                        .frame(width: 34, height: 24).overlay(Rectangle().stroke(Theme.borderStrong))
                }
            }
        }
        RuledList(title: "Conversations", trailing: "\(items.count) files") {
            ForEach(items, id: \.url) { item in
                Rule()
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(item.url.lastPathComponent).font(Theme.mono).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer()
                    Button("Continue") { Orchestrator.shared.open(item.url); AppDelegate.shared?.showPopover() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Open") { NSWorkspace.shared.open(item.url) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 14).frame(height: 52)
            }
            if items.isEmpty {
                Rule()
                Text("No conversations yet.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { items = HistoryStore.list() }
    }
}

private struct VoiceTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var kokoro = Kokoro.shared
    @State private var trusted = HotkeyMonitor.ensureAccessibility(prompt: false)
    var body: some View {
        Card(title: "Push-to-talk") {
            HStack(spacing: 6) {
                key("⌃"); Text("+").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim); key("⌥")
                Text("Hold anywhere, speak, let go to send").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.leading, 8)
            }
            Toggle("Enable the ⌃ Control + ⌥ Option shortcut", isOn: $settings.hotkeyEnabled)
            Text("A quick tap opens Agent2 for typing instead.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
        .toggleStyle(SquareToggleStyle())

        RuledList(title: "Permissions") {
            Rule()
            HStack {
                Text("Accessibility").font(.system(size: 12.5))
                Text("to see the shortcut in other apps").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                Spacer()
                if trusted { Tag(text: "✓ Granted", tone: .ok) }
                else {
                    Tag(text: "Needed", tone: .run)
                    Button("Grant") { trusted = HotkeyMonitor.ensureAccessibility(prompt: true) }.buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
        }

        Card(title: "Talking back") {
            Toggle("Answer voice requests out loud", isOn: $settings.speakVoiceReplies)
            Text("Hold ⌃⌥ and talk: no window opens, and Agent2 tells you what it did. Click the notch or the menu bar icon to stop it speaking.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("Also read replies to typed messages aloud", isOn: $settings.speakReplies)
            Text("Your words are transcribed on this Mac, and the Kokoro voice runs on it too.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(SquareToggleStyle())

        RuledList(title: "Voice", trailing: "What Agent2 sounds like") {
            engineRow(.kokoro, "Kokoro", "Natural voice that runs on this Mac. One-time 180 MB download.") { kokoroStatus }
            engineRow(.system, "macOS voice", "Built in. Uses the best voice installed in System Settings.") { EmptyView() }
            if settings.voiceEngine == .kokoro {
                Rule()
                HStack(spacing: 10) {
                    Text("Speaker").font(.system(size: 12.5))
                    Picker("", selection: $settings.kokoroVoice) {
                        ForEach(Kokoro.voices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 210)
                    Spacer()
                    Button("Preview") {
                        Speaker.shared.speak("Hi, I'm Agent2. When you ask me for something, this is how I'll tell you what I did.")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!kokoro.isReady)
                }
                .padding(.horizontal, 14).frame(height: 46)
            }
        }

        RuledList(title: "Where Agent2 lives", trailing: NotchGeometry.find() == nil ? "No notch on this Mac" : "This Mac has a notch") {
            ForEach(Placement.allCases) { place in
                let on = settings.placement == place
                Rule()
                Button { settings.placement = place } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Rectangle().stroke(on ? Theme.green : Theme.borderStrong)
                            if on { Rectangle().fill(Theme.green).padding(3) }
                        }.frame(width: 14, height: 14)
                        Text(place.label).font(.system(size: 12.5))
                        Spacer()
                        if place == .auto { Tag(text: "Default") }
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(on ? Theme.greenWash : .clear)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var kokoroStatus: some View {
        switch kokoro.state {
        case .ready:
            HStack(spacing: 8) {
                Tag(text: "✓ Ready", tone: .ok)
                Button("Remove") { kokoro.remove() }.buttonStyle(SecondaryButtonStyle())
            }
        case .downloading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Tag(text: "Downloading", tone: .run) }
        case .notInstalled:
            Button("Download") { kokoro.prepare() }.buttonStyle(PrimaryButtonStyle())
        case .failed(let why):
            HStack(spacing: 8) {
                Tag(text: "Failed", tone: .warn).help(why)
                Button("Retry") { kokoro.prepare() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func engineRow<T: View>(_ engine: VoiceEngine, _ title: String, _ detail: String,
                                    @ViewBuilder trailing: () -> T) -> some View {
        let on = settings.voiceEngine == engine
        return VStack(spacing: 0) {
            Rule()
            HStack(spacing: 12) {
                Button { settings.voiceEngine = engine } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Rectangle().stroke(on ? Theme.green : Theme.borderStrong)
                            if on { Rectangle().fill(Theme.green).padding(3) }
                        }.frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 12.5, weight: .medium))
                            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                trailing()
            }
            .padding(.horizontal, 14).frame(height: 54)
            .background(on ? Theme.greenWash : .clear)
        }
    }

    private func key(_ s: String) -> some View {
        Text(s).font(.system(size: 13, design: .monospaced))
            .frame(width: 30, height: 26)
            .background(Theme.panelRaised)
            .overlay(Rectangle().stroke(Theme.borderStrong))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 2) }
    }
}

private struct AboutTab: View {
    var body: some View {
        Card(title: "Agent2") {
            HStack(spacing: 16) {
                BirdMark(size: 48)
                    .padding(10)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(Theme.border))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent2").font(.system(size: 20, weight: .semibold)).tracking(-0.5)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · MIT licensed")
                        .font(Theme.mono).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                Button("Website") { NSWorkspace.shared.open(URL(string: "https://agent2.shakatec.co.za")!) }.buttonStyle(SecondaryButtonStyle())
                Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/sekophungula/agent2")!) }.buttonStyle(SecondaryButtonStyle())
            }
        }

        UpdatesCard()

        RuledList(title: "If macOS blocks Agent2", trailing: "Not notarised yet") {
            Rule()
            Text("Agent2 isn't notarised by Apple yet, so macOS may say “Agent2” Not Opened the first time, or after you install a new version. Allow it once:")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                Rule()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.green)
                        .frame(width: 20, height: 20)
                        .overlay(Rectangle().stroke(Theme.green.opacity(0.6)))
                    Text(.init(step)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Rule()
            HStack(spacing: 8) {
                Button("Open Privacy & Security") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
                }.buttonStyle(AccentButtonStyle())
                Button(copied ? "Copied" : "Copy Terminal fix") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("xattr -dr com.apple.quarantine /Applications/Agent2.app", forType: .string)
                    copied = true
                }.buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(14)
        }
    }

    @State private var copied = false
    static let steps = [
        "Click **Done** in the warning. Don't click Move to Bin.",
        "Open **System Settings → Privacy & Security**.",
        "Scroll down to **Security**, where it says “Agent2 was blocked to protect your Mac”.",
        "Click **Open Anyway**, confirm with your password or Touch ID, then click **Open Anyway** again.",
    ]
}

/// Settings → About → Updates.
private struct UpdatesCard: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Card(title: "Updates", trailing: AnyView(statusTag)) {
            HStack(spacing: 8) {
                Text(headline).font(.system(size: 12.5, weight: .medium))
                Spacer()
                action
            }
            if case .downloading(let p) = updater.state {
                ProgressView(value: p).tint(Theme.green)
            }
            if let r = updater.available, !r.notes.isEmpty {
                Text(Self.summary(r.notes))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Full release notes") { NSWorkspace.shared.open(r.page) }.buttonStyle(.link).font(.system(size: 11.5))
            }
            Toggle("Check for updates automatically", isOn: $settings.autoUpdateCheck)
            Text(footnote).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(SquareToggleStyle())
    }

    private var headline: String {
        switch updater.state {
        case .idle: return "You have v\(Updater.currentVersion)"
        case .checking: return "Checking GitHub for a newer version…"
        case .upToDate: return "Agent2 v\(Updater.currentVersion) is the latest version"
        case .available(let r): return "Agent2 v\(r.version) is available (you have v\(Updater.currentVersion))"
        case .downloading(let p): return "Downloading v\(updater.available?.version ?? "")… \(Int(p * 100))%"
        case .installing: return "Installing. Agent2 will quit and reopen."
        case .failed(let why): return why
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.state {
        case .available(let r):
            Button("Update now") { Task { await updater.install(r) } }.buttonStyle(AccentButtonStyle())
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check now") { Task { await updater.check() } }.buttonStyle(SecondaryButtonStyle())
                .disabled(Updater.currentVersion == "dev")
        }
    }

    @ViewBuilder private var statusTag: some View {
        switch updater.state {
        case .available: Tag(text: "Update", tone: .run)
        case .upToDate: Tag(text: "✓ Latest", tone: .ok)
        case .failed: Tag(text: "Error", tone: .warn)
        default: Tag(text: "v\(Updater.currentVersion)")
        }
    }

    private var footnote: String {
        var s = "Updates come from Agent2's GitHub releases. Your settings, history and voice stay as they are."
        if !Updater.canReplaceInPlace { s += " Move Agent2 to Applications to install updates from here." }
        if let d = updater.lastChecked { s += " Last checked \(d.formatted(date: .omitted, time: .shortened))." }
        return s
    }

    /// The release notes as plain text, first few lines only.
    static func summary(_ notes: String) -> String {
        let lines = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("**install") }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression) }
        return lines.prefix(4).joined(separator: "\n")
    }
}
