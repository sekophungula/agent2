import AppKit
import SwiftUI

@main
struct Agent2Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-assets"), i + 1 < args.count {
            do { try PixelBird.exportAssets(to: URL(fileURLWithPath: args[i + 1])); print("Exported assets to \(args[i + 1])") }
            catch { print("Export failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { DevTools.snapshot(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
            MainActor.assumeIsolated { DevTools.ask(args[i + 1]) }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon
        app.run()
    }
}

/// Agent2 lives in the menu bar: one status item, one popover, one settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let hotkey = HotkeyMonitor()
    private let voice = VoiceInput()
    private var heldVoice = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        AgentRegistry.shared.refresh()
        Task { await ComposioService.shared.refresh() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = PixelBird.menuBarImage(height: 17)
            button.toolTip = "Agent2 — hold ⌃⌥ to talk"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ChatView(
            voice: voice,
            openSettings: { [weak self] in self?.openSettings(.source) },
            openHistory: { [weak self] in self?.openSettings(.history) },
            toggleMic: { [weak self] in self?.toggleMic() }))

        hotkey.onPress = { [weak self] in self?.hotkeyDown() }
        hotkey.onRelease = { [weak self] held in self?.hotkeyUp(held: held) }
        applyHotkeySetting()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotkeySetting() }
        }

        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            _ = HotkeyMonitor.ensureAccessibility(prompt: true)
            openSettings(.source)
        }
    }

    private var hotkeyActive = false
    private func applyHotkeySetting() {
        let want = AppSettings.shared.hotkeyEnabled
        guard want != hotkeyActive else { return }
        hotkeyActive = want
        want ? hotkey.start() : hotkey.stop()
    }

    // MARK: Menu bar

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Agent2", action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New conversation", action: #selector(menuNew), keyEquivalent: "n").target = self
        menu.addItem(.separator())
        let sourceItem = NSMenuItem(title: "Source: \(AgentRegistry.shared.source?.name ?? "none")", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for a in AgentRegistry.shared.agents {
            let item = NSMenuItem(title: a.name, action: #selector(menuPickSource(_:)), keyEquivalent: "")
            item.representedObject = a.id
            item.target = self
            item.state = a.id == AppSettings.shared.sourceAgentID ? .on : .off
            sub.addItem(item)
        }
        sourceItem.submenu = sub
        menu.addItem(sourceItem)
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open history folder", action: #selector(menuHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpen() { showPopover() }
    @objc private func menuNew() { Orchestrator.shared.newConversation(); showPopover() }
    @objc private func menuSettings() { openSettings(.source) }
    @objc private func menuHistory() {
        try? FileManager.default.createDirectory(at: HistoryStore.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(HistoryStore.folder)
    }
    @objc private func menuPickSource(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { AppSettings.shared.sourceAgentID = id }
    }

    func openSettings(_ tab: SettingsTab) {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Agent2"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView(tab: tab))
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Voice

    private func hotkeyDown() {
        heldVoice = true
        Task {
            guard await voice.requestPermissions() else { showPopover(); return }
            // Only start once the keys have been held briefly, so a quick tap stays a tap.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard heldVoice else { return }
            if !popover.isShown { showPopover() }
            voice.start()
        }
    }

    private func hotkeyUp(held: TimeInterval) {
        heldVoice = false
        Task {
            if voice.isListening {
                let text = await voice.stop()
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { Orchestrator.shared.send(text) }
            } else if held < 0.35 {
                popover.isShown ? popover.performClose(nil) : showPopover()
            }
        }
    }

    private func toggleMic() {
        Task {
            if voice.isListening {
                let text = await voice.stop()
                if !text.isEmpty { Orchestrator.shared.send(text) }
            } else if await voice.requestPermissions() {
                voice.start()
            }
        }
    }
}
