import Foundation

/// The models each agent can run on, for the model menus in Settings.
///
/// An empty id means "the agent's own default" (whatever it's set to in its own
/// config, e.g. ~/.codex/config.toml). Agents whose model list is open-ended
/// (Cursor, OpenCode) take a typed model name instead.
enum ModelCatalog {
    struct Model: Hashable, Identifiable {
        let id: String
        let name: String
        var note: String = ""
    }

    static let agentDefault = Model(id: "", name: "Agent's default")

    private static let claude: [Model] = [
        .init(id: "claude-fable-5-2", name: "Fable 5.2", note: "Most capable"),
        .init(id: "claude-opus-5-5", name: "Opus 5.5", note: "Deep reasoning and coding"),
        .init(id: "claude-sonnet-5-5", name: "Sonnet 5.5", note: "Fast and capable"),
        .init(id: "claude-haiku-5-5", name: "Haiku 5.5", note: "Fastest"),
    ]

    private static let openAI: [Model] = [
        .init(id: "gpt-6.2-astra", name: "GPT-6.2 Astra", note: "Flagship"),
        .init(id: "gpt-6.2-sol", name: "GPT-6.2 Sol", note: "Everyday work"),
        .init(id: "gpt-6.1-terra", name: "GPT-6.1 Terra", note: "Fast"),
        .init(id: "gpt-6-luna", name: "GPT-6 Luna", note: "Fastest, cheapest"),
        .init(id: "gpt-6-astra", name: "GPT-6 Astra", note: "Previous flagship"),
        .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", note: "Previous"),
    ]

    private static let gemini: [Model] = [
        .init(id: "gemini-4-carbon", name: "Gemini 4 Carbon", note: "Strongest reasoning"),
        .init(id: "gemini-4-neon", name: "Gemini 4 Neon", note: "Frontier, fast"),
        .init(id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen", note: "Everyday coding and agents"),
        .init(id: "gemini-4-argon", name: "Gemini 4 Argon", note: "Efficient"),
        .init(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
        .init(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", note: "Fastest"),
    ]

    /// The menu for an agent, or nil when its models are typed in (or it has no choice).
    static func models(for agentID: String) -> [Model]? {
        switch agentID {
        case "claude-code": return [agentDefault] + claude
        case "anthropic-api": return claude
        case "codex": return [agentDefault] + openAI
        case "openai-api": return openAI
        case "gemini": return [agentDefault] + gemini
        default: return nil
        }
    }

    /// Agents that take a typed model name, with an example.
    static func typedExample(for agentID: String) -> String? {
        switch agentID {
        case "cursor-agent": return "e.g. sonnet-5.5"
        case "opencode": return "provider/model, e.g. anthropic/claude-sonnet-5-5"
        default: return nil
        }
    }

    /// `models` plus `current` when it isn't one of them (a model typed in before,
    /// or one newer than this list), so the menu always shows what's in use.
    static func menu(_ models: [Model], current: String) -> [Model] {
        models.contains { $0.id == current } ? models : models + [Model(id: current, name: current)]
    }
}
