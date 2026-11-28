import Foundation

/// `Agent2 --cua-proxy <cua-driver> [args…]`: what Claude Code and Codex launch as
/// the cua-driver MCP server when screen control is on.
///
/// It starts the real `cua-driver mcp` and passes every message both ways
/// unchanged, with two additions so Agent2 can draw its companion cursor:
/// - Cursor tools that take a `session` and weren't given one get `"agent2"`,
///   so all of the agent's actions share one cursor Agent2 can ask about.
/// - After each cursor action it asks Cua where that cursor is now (screen points,
///   origin top-left; Cua has already turned window pixels and element tokens into
///   a point) and tells the Agent2 app with a distributed notification. When the
///   companion cursor is on it also hides Cua's own cursor for that session.
/// The real pointer is never moved by any of this.
enum CuaProxy {
    static let notification = Notification.Name("za.co.shakatec.agent2.agentCursor")
    static let defaultSession = "agent2"

    /// Tools that move or use the agent cursor, and the kind of feedback each gets.
    static let cursorTools: [String: String] = [
        "move_cursor": "move", "click": "click", "double_click": "double", "right_click": "right",
        "drag": "drag", "run_steps": "steps", "scroll": "move",
    ]

    static func run(driver: String, extraArgs: [String]) -> Never {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: driver)
        child.arguments = ["mcp"] + extraArgs
        let toChild = Pipe(), fromChild = Pipe()
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.standardError
        do { try child.run() } catch {
            FileHandle.standardError.write(Data("agent2 cua proxy: couldn't start \(driver): \(error)\n".utf8))
            exit(1)
        }
        let state = State(toChild: toChild.fileHandleForWriting)
        child.terminationHandler = { p in exit(p.terminationStatus) }

        // Agent → Cua.
        Thread.detachNewThread {
            readLines(FileHandle.standardInput) { line in state.fromAgent(line) }
            try? toChild.fileHandleForWriting.close()
        }
        // Cua → agent.
        readLines(fromChild.fileHandleForReading) { line in state.fromDriver(line) }
        child.waitUntilExit()
        exit(child.terminationStatus)
    }

    /// Calls `body` with each newline-terminated line (without the newline) until EOF.
    private static func readLines(_ h: FileHandle, _ body: (Data) -> Void) {
        var buffer = Data()
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { if !buffer.isEmpty { body(buffer) }; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                body(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let toChild: FileHandle
        private let stdout = FileHandle.standardOutput
        /// Request id (as JSON text) → (tool, session) for cursor actions in flight.
        private var pending: [String: (kind: String, session: String)] = [:]
        private var toolsListID: String?
        private var takesSession: Set<String> = []
        private var hiddenSessions: Set<String> = []
        private var injectedKinds: [String: String] = [:]   // our request id → kind of action it follows
        private var nextID = 0

        init(toChild: FileHandle) { self.toChild = toChild }

        func fromAgent(_ line: Data) {
            guard var msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let method = msg["method"] as? String, let id = msg["id"] else { return send(line) }
            let idKey = Self.key(id)
            if method == "tools/list" { lock.withLock { toolsListID = idKey }; return send(line) }
            guard method == "tools/call", var params = msg["params"] as? [String: Any],
                  let name = params["name"] as? String, var kind = CuaProxy.cursorTools[name] else { return send(line) }
            var args = params["arguments"] as? [String: Any] ?? [:]
            if name == "run_steps" { kind = Self.lastStepKind(args) }
            var session = args["session"] as? String
            let accepts = lock.withLock { takesSession.contains(name) }
            var out = line
            if session == nil, accepts {
                session = CuaProxy.defaultSession
                args["session"] = session
                params["arguments"] = args
                msg["params"] = params
                if let d = try? JSONSerialization.data(withJSONObject: msg) { out = d }
            }
            if let session {
                lock.withLock { pending[idKey] = (kind, session) }
                // Only one cursor on screen: hide Cua's while Agent2 draws its own.
                if Self.companionOn, lock.withLock({ hiddenSessions.insert(session).inserted }) {
                    inject("set_agent_cursor_enabled", ["session": session, "enabled": false], kind: nil)
                }
            }
            send(out)
        }

        func fromDriver(_ line: Data) {
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = msg["id"] else {
                return reply(line)
            }
            let idKey = Self.key(id)
            // Answers to our own requests never reach the agent.
            if idKey.hasPrefix("\"agent2-") {
                let kind = lock.withLock { injectedKinds.removeValue(forKey: idKey) }
                if let kind, let point = Self.position(msg) { Self.post(point, kind: kind) }
                return
            }
            reply(line)
            if idKey == lock.withLock({ toolsListID }) {
                let tools = ((msg["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
                let names = tools.compactMap { t -> String? in
                    let props = (t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
                    return props?["session"] != nil ? t["name"] as? String : nil
                }
                lock.withLock { takesSession = Set(names) }
            }
            if let action = lock.withLock({ pending.removeValue(forKey: idKey) }) {
                let failed = (msg["result"] as? [String: Any])?["isError"] as? Bool ?? (msg["error"] != nil)
                inject("get_agent_cursor_state", ["session": action.session], kind: failed ? "move" : action.kind)
            }
        }

        private func inject(_ tool: String, _ args: [String: Any], kind: String?) {
            let id: String = lock.withLock { nextID += 1; return "agent2-\(nextID)" }
            lock.withLock { injectedKinds["\"\(id)\""] = kind }
            let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                      "params": ["name": tool, "arguments": args]]
            if let d = try? JSONSerialization.data(withJSONObject: msg) { send(d) }
        }

        private func send(_ line: Data) { lock.withLock { toChild.write(line + Data([0x0A])) } }
        private func reply(_ line: Data) { stdout.write(line + Data([0x0A])) }

        /// The feedback for a run_steps batch: its last cursor step's (a click ripples).
        static func lastStepKind(_ args: [String: Any]) -> String {
            let steps = args["steps"] as? [[String: Any]] ?? []
            for step in steps.reversed() {
                let tool = step["tool"] as? String ?? step.keys.first { CuaProxy.cursorTools[$0] != nil }
                if let tool, tool != "run_steps", let kind = CuaProxy.cursorTools[tool] { return kind }
            }
            return "move"
        }

        static func key(_ id: Any) -> String {
            if let s = id as? String { return "\"\(s)\"" }
            return "\(id)"
        }

        static var companionOn: Bool {
            UserDefaults.standard.object(forKey: "companionCursor") as? Bool ?? true
        }

        /// The cursor position from a get_agent_cursor_state reply.
        static func position(_ msg: [String: Any]) -> CGPoint? {
            guard let result = msg["result"] as? [String: Any] else { return nil }
            var state = result["structuredContent"] as? [String: Any]
            if state == nil, let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String,
               let d = text.data(using: .utf8) {
                state = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            guard let pos = state?["position"] as? [String: Any],
                  let x = (pos["x"] as? NSNumber)?.doubleValue, let y = (pos["y"] as? NSNumber)?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }

        static func post(_ p: CGPoint, kind: String) {
            DistributedNotificationCenter.default().postNotificationName(
                CuaProxy.notification, object: nil,
                userInfo: ["x": p.x, "y": p.y, "kind": kind], deliverImmediately: true)
        }
    }
}
