import Foundation
import Security
import SwiftUI

/// How much an agent may do on its own when Agent2 hands it work.
enum Autonomy: String, CaseIterable, Identifiable, Codable {
    case readOnly, editFiles, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .readOnly: return "Ask first (read-only)"
        case .editFiles: return "Edit files in workspace"
        case .full: return "Full access (no prompts)"
        }
    }
}

/// Where Agent2 shows itself.
/// How you talk to Agent2.
enum ListenMode: String, CaseIterable, Identifiable {
    case hold, handsFree
    var id: String { rawValue }
    var label: String { self == .hold ? "Hold ⌃⌥ while you talk" : "Hands-free conversation" }
    var detail: String {
        self == .hold
            ? "Hold Control+Option, speak, let go. Nothing listens until you press."
            : "Tap ⌃⌥ to start talking back and forth; Agent2 hears when you pause. Tap again, say \u{201C}goodbye\u{201D} or stay quiet for a minute to end."
    }
}

/// What turns speech into text.
enum DictationEngine: String, CaseIterable, Identifiable {
    case parakeet, apple
    var id: String { rawValue }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case kokoro, system
    var id: String { rawValue }
}

enum Placement: String, CaseIterable, Identifiable {
    case auto, notch, menuBar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Notch if this Mac has one, otherwise the menu bar"
        case .notch: return "Notch"
        case .menuBar: return "Menu bar"
        }
    }
}

/// User settings. The *source* agent is only ever changed here, by the user:
/// Agent2 never switches it on its own.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var sourceAgentID: String { didSet { d.set(sourceAgentID, forKey: "sourceAgentID") } }
    @Published var delegatesEnabled: Bool { didSet { d.set(delegatesEnabled, forKey: "delegatesEnabled") } }
    @Published var disabledDelegateIDs: Set<String> { didSet { d.set(Array(disabledDelegateIDs), forKey: "disabledDelegateIDs") } }
    @Published var autonomy: Autonomy { didSet { d.set(autonomy.rawValue, forKey: "autonomy") } }
    @Published var historyFolder: String { didSet { d.set(historyFolder, forKey: "historyFolder") } }
    @Published var workspaceFolder: String { didSet { d.set(workspaceFolder, forKey: "workspaceFolder") } }
    @Published var anthropicModel: String { didSet { d.set(anthropicModel, forKey: "anthropicModel") } }
    @Published var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    /// The model chosen for each command-line agent (agent id → model id). Missing
    /// or empty: the agent's own default.
    @Published var agentModels: [String: String] { didSet { d.set(agentModels, forKey: "agentModels") } }

    /// The model the person picked for `agentID`, or nil for the agent's own default.
    func model(for agentID: String) -> String? {
        let m: String
        switch agentID {
        case "anthropic-api": m = anthropicModel
        case "openai-api": m = openAIModel
        default: m = agentModels[agentID] ?? ""
        }
        let t = m.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    func setModel(_ model: String, for agentID: String) {
        switch agentID {
        case "anthropic-api": anthropicModel = model
        case "openai-api": openAIModel = model
        default: agentModels[agentID] = model.isEmpty ? nil : model
        }
    }
    /// Read replies to *typed* messages aloud too (voice requests are always answered out loud).
    @Published var speakReplies: Bool { didSet { d.set(speakReplies, forKey: "speakReplies") } }
    @Published var speakVoiceReplies: Bool { didSet { d.set(speakVoiceReplies, forKey: "speakVoiceReplies") } }
    @Published var voiceEngine: VoiceEngine {
        didSet {
            d.set(voiceEngine.rawValue, forKey: "voiceEngine")
            if voiceEngine == .kokoro { Task { @MainActor in Kokoro.shared.prepare() } }
        }
    }
    @Published var kokoroVoice: String { didSet { d.set(kokoroVoice, forKey: "kokoroVoice") } }
    @Published var autoUpdateCheck: Bool { didSet { d.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    @Published var fastReplies: Bool { didSet { d.set(fastReplies, forKey: "fastReplies") } }
    @Published var dictationEngine: DictationEngine {
        didSet {
            d.set(dictationEngine.rawValue, forKey: "dictationEngine")
            if dictationEngine == .parakeet { Task { @MainActor in Parakeet.shared.prepare() } }
        }
    }
    /// Agent2 does simple things (open an app, mute) itself, instantly.
    @Published var instantCommands: Bool { didSet { d.set(instantCommands, forKey: "instantCommands") } }
    @Published var screenControl: Bool { didSet { d.set(screenControl, forKey: "screenControl") } }
    /// Send a screenshot of the display you're on (and where your pointer is) with each request.
    @Published var shareScreen: Bool { didSet { d.set(shareScreen, forKey: "shareScreen") } }
    /// Agent2's own green agent cursor (with a fading trail) instead of Cua's.
    @Published var companionCursor: Bool {
        didSet { d.set(companionCursor, forKey: "companionCursor"); Task { @MainActor in CompanionCursor.shared.refresh() } }
    }
    /// How long the companion cursor's trail takes to fade, in seconds.
    @Published var companionTrail: Double { didSet { d.set(companionTrail, forKey: "companionTrail") } }
    /// Between agent moves, the companion cursor shadows the person's pointer.
    @Published var companionFollows: Bool { didSet { d.set(companionFollows, forKey: "companionFollows") } }
    @Published var listenMode: ListenMode {
        didSet {
            d.set(listenMode.rawValue, forKey: "listenMode")
            if listenMode == .hold { Task { @MainActor in HandsFree.shared.end() } }
        }
    }
    @Published var placement: Placement { didSet { d.set(placement.rawValue, forKey: "placement") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var contextTurns: Int { didSet { d.set(contextTurns, forKey: "contextTurns") } }
    /// Remember across conversations with a graphify knowledge graph of the history.
    @Published var historyMemory: Bool {
        didSet { d.set(historyMemory, forKey: "historyMemory"); if historyMemory { Task { @MainActor in HistoryMemory.shared.start() } } }
    }

    @Published var anthropicKey: String { didSet { Keychain.set(anthropicKey, for: "anthropic") } }
    @Published var openAIKey: String { didSet { Keychain.set(openAIKey, for: "openai") } }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        sourceAgentID = d.string(forKey: "sourceAgentID") ?? ""
        delegatesEnabled = d.object(forKey: "delegatesEnabled") as? Bool ?? true
        disabledDelegateIDs = Set(d.stringArray(forKey: "disabledDelegateIDs") ?? [])
        autonomy = Autonomy(rawValue: d.string(forKey: "autonomy") ?? "") ?? .readOnly
        historyFolder = d.string(forKey: "historyFolder") ?? "\(home)/Agent2/History"
        workspaceFolder = d.string(forKey: "workspaceFolder") ?? "\(home)/Agent2/Workspace"
        anthropicModel = d.string(forKey: "anthropicModel") ?? "claude-opus-5-5"
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-6.2-sol"
        agentModels = d.dictionary(forKey: "agentModels") as? [String: String] ?? [:]
        // Agent2 is voice-first: typed messages are answered out loud too. Turned on
        // once for everyone in 0.1.6; people can still switch it off.
        if !d.bool(forKey: "speakRepliesOn016") {
            d.set(true, forKey: "speakRepliesOn016")
            d.set(true, forKey: "speakReplies")
        }
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? true
        speakVoiceReplies = d.object(forKey: "speakVoiceReplies") as? Bool ?? true
        voiceEngine = VoiceEngine(rawValue: d.string(forKey: "voiceEngine") ?? "") ?? .kokoro
        kokoroVoice = d.string(forKey: "kokoroVoice") ?? Kokoro.voices[0].id
        autoUpdateCheck = d.object(forKey: "autoUpdateCheck") as? Bool ?? true
        fastReplies = d.object(forKey: "fastReplies") as? Bool ?? true
        instantCommands = d.object(forKey: "instantCommands") as? Bool ?? true
        dictationEngine = DictationEngine(rawValue: d.string(forKey: "dictationEngine") ?? "") ?? .parakeet
        // On by default once Cua Driver is installed: installing it is the opt-in.
        screenControl = d.object(forKey: "screenControl") as? Bool ?? true
        companionCursor = d.object(forKey: "companionCursor") as? Bool ?? true
        shareScreen = d.object(forKey: "shareScreen") as? Bool ?? true
        companionTrail = d.object(forKey: "companionTrail") as? Double ?? 0.45
        companionFollows = d.object(forKey: "companionFollows") as? Bool ?? true
        listenMode = ListenMode(rawValue: d.string(forKey: "listenMode") ?? "") ?? .hold
        placement = Placement(rawValue: d.string(forKey: "placement") ?? "") ?? .auto
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        contextTurns = d.object(forKey: "contextTurns") as? Int ?? 12
        historyMemory = d.object(forKey: "historyMemory") as? Bool ?? true
        anthropicKey = Keychain.get("anthropic") ?? ""
        openAIKey = Keychain.get("openai") ?? ""
    }
}

/// API keys live in the login keychain, never in UserDefaults or history files.
enum Keychain {
    private static let service = "za.co.shakatec.agent2"

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
