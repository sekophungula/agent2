import Foundation

/// Lets the source agent see and use this Mac's apps through Cua Driver
/// (github.com/trycua/cua, MIT), an MCP server that clicks, types, scrolls and
/// opens apps on the real desktop and shows its own cursor while it works.
/// Agent2 attaches it to the source agent only for its own runs; the person's
/// Claude Code and Codex settings are left alone.
enum ScreenControl {
    static let installCommand = #"/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)" -- --no-connect"#
    static let docs = URL(string: "https://cua.ai/docs/cua-driver")!

    /// Path to the `cua-driver` binary, if Cua Driver is installed.
    static var driverPath: String? {
        if let p = Shell.which("cua-driver") { return p }
        let app = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
        return FileManager.default.isExecutableFile(atPath: app) ? app : nil
    }

    /// The driver to attach to this run, or nil when screen control is off or not installed.
    @MainActor static var activeDriver: String? {
        AppSettings.shared.screenControl ? driverPath : nil
    }

    /// How the agent launches Cua Driver: through Agent2's proxy (`CuaProxy`), which
    /// passes everything through and tells Agent2 where the agent's cursor goes.
    static func launch(_ driver: String) -> (command: String, args: [String]) {
        guard let me = Bundle.main.executablePath else { return (driver, ["mcp"]) }
        return (me, ["--cua-proxy", driver])
    }

    /// MCP server config for Claude Code's --mcp-config.
    static func claudeMCPConfig(_ driver: String) -> String {
        let l = launch(driver)
        let obj: [String: Any] = ["mcpServers": ["cua-driver": ["command": l.command, "args": l.args]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Extra Codex `-c` overrides that add the MCP server for this run.
    static func codexOverrides(_ driver: String) -> [String] {
        let l = launch(driver)
        let args = l.args.map { "\"\($0)\"" }.joined(separator: ",")
        return ["-c", "mcp_servers.cua.command=\"\(l.command)\"", "-c", "mcp_servers.cua.args=[\(args)]"]
    }

    static let prompt = """
    Screen control: you can see and use the apps on this Mac through the cua-driver tools. Use them when the person asks you to do something in an app on their screen, or to show them where something is.
    - Look first: list_apps or list_windows, then get_window_state (a window's accessibility tree plus a screenshot) or get_desktop_state (the whole display).
    - Act with run_steps, which runs several clicks, typing and key presses in one call and can report what changed. Call get_guide once if you're unsure how a tool works.
    - The person sees your cursor move. For "show me" or "where is" questions, move the cursor to the thing (move_cursor) and say what it is, instead of clicking.
    - Say briefly what you're about to do before a longer sequence, so the person knows what's happening on their screen.
    - Never type passwords, payment details or one-time codes, and ask before sending, buying, posting or deleting anything.
    """

    struct Status: Equatable {
        var accessibility: Bool?
        var screenRecording: Bool?
        var summary: String
    }

    /// Reads `cua-driver permissions status` (read-only, no prompts).
    static func status() async -> Status {
        guard let driver = driverPath else { return Status(summary: "Not installed") }
        guard let res = try? await Shell.run(driver, ["permissions", "status"]) else {
            return Status(summary: "Couldn't run Cua Driver")
        }
        let text = (res.stdout + "\n" + res.stderr).lowercased()
        func granted(_ key: String) -> Bool? {
            guard let line = text.split(separator: "\n").first(where: { $0.contains(key) }) else { return nil }
            // e.g. "Screen Recording (see your screen):  ❌ off"
            let value = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if line.contains("❌") || value.hasSuffix("off") || value.contains("not granted") { return false }
            if line.contains("✅") || value.hasSuffix("on") || value.contains("granted") { return true }
            return nil
        }
        let ax = granted("accessibility"), sr = granted("screen recording")
        let summary = ax == true && sr == true ? "Ready" : "Needs permissions"
        return Status(accessibility: ax, screenRecording: sr, summary: summary)
    }

    /// Opens Cua's own walkthrough, which takes the person to each switch in System Settings.
    static func grantPermissions() {
        guard let driver = driverPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: driver)
        p.arguments = ["permissions", "grant"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
