import AppKit
import Foundation

/// What a single agent call needs.
struct RunContext: Sendable {
    let cwd: String
    let autonomy: Autonomy
    let cancel: CancelToken
    let progress: @Sendable (String) -> Void
    /// Tools Agent2 offers API-based agents (delegation, Composio, history search).
    let tools: ToolHost?
    /// The source agent's reply text as it's written, so Agent2 can start speaking early.
    var onText: (@Sendable (String) -> Void)? = nil
    /// Quick conversational turn: lighter thinking, and Claude Code skips the person's
    /// own hooks and plugins (they can add seconds before the first word).
    var fast = false
    /// Cua Driver binary to attach as an MCP server, for screen control (source agent only).
    var screenDriver: String? = nil
    /// Background bookkeeping (memory): don't save it as a Claude Code session.
    var background = false
    /// A screenshot (JPEG) to send with the prompt, for agents that take images.
    var image: URL? = nil
}

struct ToolSpec: @unchecked Sendable {
    let name: String
    let description: String
    let schema: [String: Any]
    init(_ name: String, _ description: String, _ schema: [String: Any]) {
        self.name = name; self.description = description; self.schema = schema
    }
}

protocol ToolHost: Sendable {
    var specs: [ToolSpec] { get }
    func call(_ name: String, _ args: [String: Any]) async -> String
}

enum RunnerError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
}

/// Sends one prompt to one agent and returns its final reply.
enum Runner {
    static func run(_ agent: AgentInfo, prompt: String, system: String, model: String?, ctx: RunContext) async throws -> String {
        try FileManager.default.createDirectory(atPath: ctx.cwd, withIntermediateDirectories: true)
        // No model asked for: the one the person picked in Settings, else the agent's own default.
        var chosen = model
        if chosen == nil { chosen = await MainActor.run { AppSettings.shared.model(for: agent.id) } }
        let m = { (flag: String) in chosen.map { [flag, $0] } ?? [] }
        switch agent.id {
        case "claude-code": return try await claudeCode(agent, prompt, system, ctx, model: chosen)
        case "codex": return try await codex(agent, prompt, system, ctx, model: chosen)
        case "gemini": return try await simpleCLI(agent, m("-m") + ["-p", combined(system, prompt)] + (ctx.autonomy == .full ? ["--yolo"] : []), ctx)
        case "cursor-agent": return try await simpleCLI(agent, m("--model") + ["-p", combined(system, prompt), "--output-format", "text"] + (ctx.autonomy == .full ? ["--force"] : []), ctx)
        case "opencode": return try await simpleCLI(agent, ["run"] + m("-m") + [combined(system, prompt)], ctx)
        case "anthropic-api": return try await AnthropicAPI.run(prompt: prompt, system: system, ctx: ctx)
        case "openai-api": return try await OpenAIAPI.run(prompt: prompt, system: system, ctx: ctx)
        default:
            if agent.kind == .desktop { return await handOff(agent, prompt) }
            throw RunnerError.failed("Agent2 doesn't know how to run \(agent.name).")
        }
    }

    private static func combined(_ system: String, _ prompt: String) -> String {
        "<instructions>\n\(system)\n</instructions>\n\n\(prompt)"
    }

    // MARK: Claude Code (headless, stream-json)
    private static func claudeCode(_ a: AgentInfo, _ prompt: String, _ system: String, _ ctx: RunContext,
                                   model: String? = nil) async throws -> String {
        // With a screenshot, the prompt goes in on stdin as a message with an image.
        var stdin: String? = nil
        if let image = ctx.image, let data = try? Data(contentsOf: image) {
            let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]],
                ["type": "text", "text": prompt],
            ]]]
            stdin = (try? JSONSerialization.data(withJSONObject: msg)).map { String(decoding: $0, as: UTF8.self) + "\n" }
        }
        var args = (stdin == nil ? ["-p", prompt] : ["-p", "--input-format", "stream-json"])
            + ["--output-format", "stream-json", "--verbose", "--include-partial-messages", "--append-system-prompt", system]
        if let model { args += ["--model", model] }
        if ctx.background { args += ["--no-session-persistence"] }
        if ctx.fast { args += ["--setting-sources", "project,local", "--effort", "low"] }
        if let driver = ctx.screenDriver {
            args += ["--mcp-config", ScreenControl.claudeMCPConfig(driver), "--allowedTools", "mcp__cua-driver"]
        }
        switch ctx.autonomy {
        case .readOnly: break
        case .editFiles: args += ["--permission-mode", "acceptEdits"]
        case .full: args += ["--dangerously-skip-permissions"]
        }
        let finalBox = Box<String>()
        let res = try await Shell.run(a.detail, args, cwd: ctx.cwd, stdin: stdin, onLine: { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "stream_event":
                // Token-by-token text, so speech can start before the reply is finished.
                guard let ev = obj["event"] as? [String: Any] else { return }
                if ev["type"] as? String == "content_block_delta",
                   let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                    ctx.onText?(t)
                } else if ev["type"] as? String == "content_block_stop" {
                    ctx.onText?("\n")
                }
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    if block["type"] as? String == "tool_use" {
                        let name = block["name"] as? String ?? "tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let hint = (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["url"]) as? String ?? ""
                        ctx.progress("Claude Code → \(name) \(hint.prefix(80))")
                    } else if let t = block["text"] as? String, !t.isEmpty {
                        ctx.progress("Claude Code: \(t.prefix(120))")
                    }
                }
            case "result":
                if let r = obj["result"] as? String {
                    let isError = obj["is_error"] as? Bool ?? false
                    let lower = r.lowercased()
                    if isError && (lower.contains("authenticate") || lower.contains("login") || lower.contains("oauth")) {
                        finalBox.value = "⚠️ Claude Code isn't signed in: \(r)\n\nOpen Terminal, run `claude`, and sign in with your Claude account, then try again."
                    } else {
                        finalBox.value = r
                    }
                }
            default: break
            }
        }, cancel: ctx.cancel)
        if let v = finalBox.value { return v }
        throw RunnerError.failed("Claude Code exited (\(res.status)): \(res.stderr.suffix(400))")
    }

    // MARK: Codex CLI (exec mode)
    private static func codex(_ a: AgentInfo, _ prompt: String, _ system: String, _ ctx: RunContext,
                              model: String? = nil) async throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("agent2-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let sandbox = ["read-only", "workspace-write", "danger-full-access"][[Autonomy.readOnly, .editFiles, .full].firstIndex(of: ctx.autonomy)!]
        var args: [String] = ["exec", "--skip-git-repo-check", "--color", "never", "--json", "-s", sandbox]
        if let model { args += ["-m", model] }
        if let image = ctx.image { args += ["-i", image.path] }
        if ctx.fast { args += ["-c", "model_reasoning_effort=\"low\""] }
        if let driver = ctx.screenDriver { args += ScreenControl.codexOverrides(driver) }
        args += ["--output-last-message", out.path, combined(system, prompt)]
        let res = try await Shell.run(a.detail, args, cwd: ctx.cwd, onLine: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else {
                return ctx.progress("Codex: \(t.prefix(120))")
            }
            // `codex exec --json` events: each finished item, e.g. a message or a command.
            guard let item = obj["item"] as? [String: Any] else { return }
            let kind = item["type"] as? String ?? item["item_type"] as? String ?? ""
            if kind.contains("message"), obj["type"] as? String == "item.completed", let text = item["text"] as? String {
                ctx.onText?(text + "\n")
                ctx.progress("Codex: \(text.prefix(120))")
            } else if let cmd = item["command"] as? String {
                ctx.progress("Codex → \(cmd.prefix(100))")
            }
        }, cancel: ctx.cancel)
        if let text = try? String(contentsOf: out, encoding: .utf8), !text.isEmpty { return text }
        if res.status == 0 { return res.stdout }
        throw RunnerError.failed("Codex exited (\(res.status)): \(res.stderr.suffix(400))")
    }

    private static func simpleCLI(_ a: AgentInfo, _ args: [String], _ ctx: RunContext) async throws -> String {
        ctx.progress("\(a.name) is working…")
        let res = try await Shell.run(a.detail, args, cwd: ctx.cwd, onLine: { ctx.onText?($0 + "\n") }, cancel: ctx.cancel)
        if res.status == 0 { return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        throw RunnerError.failed("\(a.name) exited (\(res.status)): \(res.stderr.suffix(400))")
    }

    /// Desktop chat apps have no headless mode: copy the prompt and bring the app forward.
    @MainActor
    private static func handOff(_ a: AgentInfo, _ prompt: String) async -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.detail), configuration: .init(), completionHandler: nil)
        return "Opened \(a.name) and copied your message. Paste it there with ⌘V. (Desktop apps can't be run in the background; pick a command-line agent or API key as your source for full Agent2 features.)"
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

// MARK: - Anthropic Messages API (raw HTTP; Swift has no official SDK)

enum AnthropicAPI {
    static func run(prompt: String, system: String, ctx: RunContext) async throws -> String {
        let (key, model) = await MainActor.run { (AppSettings.shared.anthropicKey, AppSettings.shared.anthropicModel) }
        var messages: [[String: Any]] = [["role": "user", "content": prompt]]
        let tools: [[String: Any]] = (ctx.tools?.specs ?? []).map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.schema]
        }
        for _ in 0..<12 {
            if ctx.cancel.isCancelled { throw CancellationError() }
            var body: [String: Any] = [
                "model": model, "max_tokens": 16000, "system": system, "messages": messages,
                "output_config": ["effort": "medium"],
            ]
            if !tools.isEmpty { body["tools"] = tools }
            var headers = ["x-api-key": key, "anthropic-version": "2026-10-21", "content-type": "application/json"]
            // Server-side refusal fallback for the current Claude models.
            if ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5"].contains(model) {
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
                body["fallbacks"] = "default"
            }
            ctx.progress("Claude API is thinking…")
            let resp = try await HTTP.postJSON("https://api.anthropic.com/v1/messages", headers: headers, body: body)
            if let err = resp["error"] as? [String: Any] { throw RunnerError.failed("Anthropic: \(err["message"] ?? err)") }
            let content = resp["content"] as? [[String: Any]] ?? []
            let stop = resp["stop_reason"] as? String
            if stop == "refusal" { return "Claude declined this request." }
            let toolUses = content.filter { $0["type"] as? String == "tool_use" }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard stop == "tool_use", !toolUses.isEmpty, let host = ctx.tools else { return text }
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            await withTaskGroup(of: (Int, String).self) { group in
                for (i, tu) in toolUses.enumerated() {
                    let name = tu["name"] as? String ?? ""
                    let input = tu["input"] as? [String: Any] ?? [:]
                    nonisolated(unsafe) let safeInput = input
                    group.addTask { (i, await host.call(name, safeInput)) }
                }
                var outs = Array(repeating: "", count: toolUses.count)
                for await (i, out) in group { outs[i] = out }
                for (i, tu) in toolUses.enumerated() {
                    results.append(["type": "tool_result", "tool_use_id": tu["id"] as? String ?? "", "content": outs[i]])
                }
            }
            messages.append(["role": "user", "content": results])
        }
        throw RunnerError.failed("Claude API used too many tool rounds.")
    }
}

// MARK: - OpenAI Responses API

enum OpenAIAPI {
    static func run(prompt: String, system: String, ctx: RunContext) async throws -> String {
        let (key, model) = await MainActor.run { (AppSettings.shared.openAIKey, AppSettings.shared.openAIModel) }
        let tools: [[String: Any]] = (ctx.tools?.specs ?? []).map {
            ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema]
        }
        var input: [[String: Any]] = [["role": "user", "content": prompt]]
        var previous: String?
        for _ in 0..<12 {
            if ctx.cancel.isCancelled { throw CancellationError() }
            var body: [String: Any] = ["model": model, "instructions": system, "input": input]
            if !tools.isEmpty { body["tools"] = tools }
            if let previous { body["previous_response_id"] = previous }
            ctx.progress("OpenAI is thinking…")
            let resp = try await HTTP.postJSON("https://api.openai.com/v1/responses",
                                               headers: ["authorization": "Bearer \(key)", "content-type": "application/json"],
                                               body: body)
            if let err = resp["error"] as? [String: Any] { throw RunnerError.failed("OpenAI: \(err["message"] ?? err)") }
            previous = resp["id"] as? String
            let output = resp["output"] as? [[String: Any]] ?? []
            let calls = output.filter { $0["type"] as? String == "function_call" }
            let text = output.filter { $0["type"] as? String == "message" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["text"] as? String }.joined()
            guard !calls.isEmpty, let host = ctx.tools else { return text }
            input = []
            for c in calls {
                let args = (try? JSONSerialization.jsonObject(with: Data((c["arguments"] as? String ?? "{}").utf8))) as? [String: Any] ?? [:]
                let out = await host.call(c["name"] as? String ?? "", args)
                input.append(["type": "function_call_output", "call_id": c["call_id"] as? String ?? "", "output": out])
            }
        }
        throw RunnerError.failed("OpenAI used too many tool rounds.")
    }
}

enum HTTP {
    static func postJSON(_ url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, http.statusCode >= 400, obj?["error"] == nil {
            throw RunnerError.failed("HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        return obj ?? [:]
    }
}
