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
    @Published var speakReplies: Bool { didSet { d.set(speakReplies, forKey: "speakReplies") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var contextTurns: Int { didSet { d.set(contextTurns, forKey: "contextTurns") } }

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
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-6.1-sol"
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? false
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        contextTurns = d.object(forKey: "contextTurns") as? Int ?? 12
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
