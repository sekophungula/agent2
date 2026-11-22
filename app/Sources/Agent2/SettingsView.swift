import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case source = "Source", agents = "Agents", apps = "Apps (Composio)", history = "History", voice = "Voice & hotkey", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .source: return "brain"
        case .agents: return "person.3"
        case .apps: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .voice: return "mic"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State var tab: SettingsTab
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { BirdMark(size: 22); Text("Agent2").font(.system(size: 15, weight: .bold)) }
                    .padding(.bottom, 16).padding(.leading, 6)
                ForEach(SettingsTab.allCases) { t in
                    Button { tab = t } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t.symbol).frame(width: 18)
                            Text(t.rawValue)
                        }
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(tab == t ? Theme.green.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(tab == t ? Theme.greenBright : Theme.text)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 190)
            .background(Theme.panel)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tab.rawValue).font(.system(size: 22, weight: .bold))
                    switch tab {
                    case .source: SourceTab()
                    case .agents: AgentsTab()
                    case .apps: AppsTab()
                    case .history: HistoryTab()
                    case .voice: VoiceTab()
                    case .about: AboutTab()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 540)
    }
}

private struct SourceTab: View {
    @ObservedObject var registry = AgentRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Text("The source is the agent Agent2 thinks with. It reads your request, does what it can and hands the rest to other agents. Agent2 never switches it for you: change it here whenever you like. Your history stays the same either way.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        ForEach(registry.agents) { a in
            Button { settings.sourceAgentID = a.id } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: settings.sourceAgentID == a.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(settings.sourceAgentID == a.id ? Theme.greenBright : Theme.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(a.name).font(.system(size: 13, weight: .semibold))
                            Pill(text: a.kind == .cli ? "CLI" : a.kind == .api ? "API KEY" : "DESKTOP · HAND-OFF",
                                 color: a.kind == .desktop ? Theme.muted : Theme.green)
                        }
                        Text(a.strengths).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Text(a.detail.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Theme.mono).foregroundStyle(Theme.muted.opacity(0.7))
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.sourceAgentID == a.id ? Theme.green : Theme.border))
            }.buttonStyle(.plain)
        }
        if registry.agents.isEmpty {
            Card {
                Text("No agents found yet").font(.headline)
                Text("Install Claude Code (`npm i -g @anthropic-ai/claude-code`) or Codex (`npm i -g @openai/codex`) and sign in with your subscription, or add an API key under Agents.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        Button("Scan again") { registry.refresh() }.buttonStyle(SecondaryButtonStyle())
    }
}

private struct AgentsTab: View {
    @ObservedObject var registry = AgentRegistry.shared
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Card {
            Toggle("Let the source delegate to other agents", isOn: $settings.delegatesEnabled)
            Text("When on, the source can hand parts of a job to the agents below and they run in parallel.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            ForEach(registry.agents.filter { $0.canRunHeadless && $0.id != settings.sourceAgentID }) { a in
                Toggle(a.name, isOn: Binding(
                    get: { !settings.disabledDelegateIDs.contains(a.id) },
                    set: { on in if on { settings.disabledDelegateIDs.remove(a.id) } else { settings.disabledDelegateIDs.insert(a.id) } }))
                    .disabled(!settings.delegatesEnabled)
            }
        }
        Card {
            Text("What agents may do").font(.headline)
            Picker("", selection: $settings.autonomy) {
                ForEach(Autonomy.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.radioGroup).labelsHidden()
            Text("Applies to Claude Code, Codex, Gemini and Cursor. They work inside your workspace folder.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack {
                Text("Workspace").frame(width: 90, alignment: .leading)
                TextField("", text: $settings.workspaceFolder).textFieldStyle(.roundedBorder)
            }
        }
        Card {
            Text("API keys (optional)").font(.headline)
            Text("Use these if you'd rather pay per use than use a subscription CLI. Keys are stored in your macOS Keychain.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack { Text("Anthropic").frame(width: 90, alignment: .leading); SecureField("sk-ant-…", text: $settings.anthropicKey).textFieldStyle(.roundedBorder) }
            HStack { Text("Model").frame(width: 90, alignment: .leading); TextField("", text: $settings.anthropicModel).textFieldStyle(.roundedBorder) }
            HStack { Text("OpenAI").frame(width: 90, alignment: .leading); SecureField("sk-…", text: $settings.openAIKey).textFieldStyle(.roundedBorder) }
            HStack { Text("Model").frame(width: 90, alignment: .leading); TextField("", text: $settings.openAIModel).textFieldStyle(.roundedBorder) }
            Button("Save and rescan") { registry.refresh() }.buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct AppsTab: View {
    @ObservedObject var composio = ComposioService.shared
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    var body: some View {
        Text("Link your socials, tools and accounts once with Composio, and every agent Agent2 uses can work in them.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)

        Card {
            HStack {
                Text("Already linked to your agents?").font(.headline)
                Spacer()
            }
            statusRow("Claude Code", composio.linkedInClaudeCode)
            statusRow("Codex", composio.linkedInCodex)
            if !(composio.linkedInClaudeCode && composio.linkedInCodex) {
                Button("Add Composio to my agents") { Task { await composio.connectAgents() } }
                    .buttonStyle(SecondaryButtonStyle()).disabled(!composio.isSignedIn)
            }
        }

        Card {
            if !composio.isInstalled {
                Text("Composio CLI isn't installed").font(.headline)
                Text("Install it once, then come back here to sign in and link apps.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("Install Composio") { composio.openInstallPage() }.buttonStyle(PrimaryButtonStyle())
            } else if !composio.isSignedIn {
                Text("Sign in to Composio").font(.headline)
                Button("Sign in with browser") { Task { await composio.signIn() } }.buttonStyle(PrimaryButtonStyle())
            } else {
                HStack {
                    Text("Signed in").font(.headline)
                    Pill(text: composio.account ?? "")
                    Spacer()
                    Button("Refresh") { Task { await composio.refresh() } }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if let busy = composio.busy {
                HStack { ProgressView().controlSize(.small); Text(busy).font(Theme.mono).foregroundStyle(Theme.muted) }
            }
            if let err = composio.lastError { Text(err).font(Theme.mono).foregroundStyle(.orange) }
        }

        Text("Apps").font(.headline)
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ComposioService.popular) { tk in
                let linked = composio.connections.contains { $0.toolkit.lowercased() == tk.id && $0.status != "failed" }
                Button { if !linked { Task { await composio.link(tk.id) } } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tk.symbol).frame(width: 18).foregroundStyle(Theme.greenBright)
                        Text(tk.name).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer()
                        if linked { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.greenBright) }
                        else { Text("Link").font(Theme.mono).foregroundStyle(Theme.muted) }
                    }
                    .padding(10)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(linked ? Theme.green : Theme.border))
                }
                .buttonStyle(.plain)
                .disabled(!composio.isSignedIn || composio.busy != nil)
            }
        }
        let others = composio.connections.filter { c in !ComposioService.popular.contains { $0.id == c.toolkit.lowercased() } }
        if !others.isEmpty {
            Text("Also connected: " + others.map(\.toolkit).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func statusRow(_ name: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.greenBright : Theme.muted)
            Text(name)
            Spacer()
            Text(ok ? "Composio connected" : "not connected").font(Theme.mono).foregroundStyle(Theme.muted)
        }.font(.system(size: 12))
    }
}

private struct HistoryTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var items: [(title: String, date: Date, url: URL)] = []
    var body: some View {
        Text("Every conversation is saved as a Markdown file that belongs to Agent2, not to any one agent, so switching between Claude Code, Codex, an API key or another session never loses it.")
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        HStack {
            TextField("", text: $settings.historyFolder).textFieldStyle(.roundedBorder)
            Button("Reveal") { NSWorkspace.shared.open(HistoryStore.folder) }.buttonStyle(SecondaryButtonStyle())
        }
        Stepper("Recent turns sent to agents as context: \(settings.contextTurns)", value: $settings.contextTurns, in: 2...40)
            .font(.system(size: 12))
        ForEach(items, id: \.url) { item in
            HStack {
                VStack(alignment: .leading) {
                    Text(item.title).font(.system(size: 12, weight: .medium))
                    Text(item.url.lastPathComponent).font(Theme.mono).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Continue") { Orchestrator.shared.open(item.url); AppDelegate.shared?.showPopover() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Open") { NSWorkspace.shared.open(item.url) }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        }
        .onAppear { items = HistoryStore.list() }
        if items.isEmpty { Text("No conversations yet.").foregroundStyle(Theme.muted) }
    }
}

private struct VoiceTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var trusted = HotkeyMonitor.ensureAccessibility(prompt: false)
    var body: some View {
        Card {
            Toggle("Hold ⌃ Control + ⌥ Option to talk", isOn: $settings.hotkeyEnabled)
            Text("Hold both keys anywhere on your Mac, speak, and let go to send. A quick tap opens Agent2 for typing.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? Theme.greenBright : .orange)
                Text(trusted ? "Accessibility access granted" : "Agent2 needs Accessibility access to hear the shortcut in other apps.")
                    .font(.system(size: 12))
                Spacer()
                if !trusted {
                    Button("Grant…") { trusted = HotkeyMonitor.ensureAccessibility(prompt: true) }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        Card {
            Toggle("Read replies aloud", isOn: $settings.speakReplies)
            Text("Speech is transcribed on this Mac with Apple's speech recognition.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        Card {
            HStack(spacing: 14) {
                BirdMark(size: 54)
                VStack(alignment: .leading) {
                    Text("Agent2").font(.system(size: 20, weight: .bold))
                    Text("The middleman for your AI agents. Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            HStack {
                Link("agent2.shakatec.co.za", destination: URL(string: "https://agent2.shakatec.co.za")!)
                Text("·").foregroundStyle(Theme.muted)
                Link("GitHub", destination: URL(string: "https://github.com/sekophungula/agent2")!)
            }.font(.system(size: 12))
        }
    }
}
