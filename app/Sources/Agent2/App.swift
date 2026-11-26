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
        if let i = args.firstIndex(of: "--dmg-background"), i + 1 < args.count {
            do { try DMGBackground.write(to: URL(fileURLWithPath: args[i + 1])); print("Wrote DMG background to \(args[i + 1])") }
            catch { print("Failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { DevTools.snapshot(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--ask-voice"), i + 1 < args.count {
            MainActor.assumeIsolated { DevTools.ask(args[i + 1], spoken: true) }
            RunLoop.main.run()
        }
        if args.contains("--check-update") {
            MainActor.assumeIsolated { DevTools.checkUpdate() }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--update-from"), i + 2 < args.count {
            MainActor.assumeIsolated { DevTools.updateFrom(zip: args[i + 1], version: args[i + 2], relaunch: args.contains("--relaunch")) }
            RunLoop.main.run()
        }
        if args.contains("--stream-test") {
            MainActor.assumeIsolated { DevTools.streamTest() }
            exit(0)
        }
        if args.contains("--handsfree-test") {
            MainActor.assumeIsolated { DevTools.handsFreeTest() }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--talk"), i + 1 < args.count {
            MainActor.assumeIsolated { DevTools.talk(args[i + 1]) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
            MainActor.assumeIsolated { DevTools.say(args[i + 1]) }
            RunLoop.main.run()
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

/// Agent2 lives in the notch on MacBooks that have one, otherwise in the menu bar.
/// Holding ⌃⌥ is hands-free: no window opens, the notch (or menu bar icon) turns
/// into a green pill, and the answer is spoken back. A quick tap opens the chat.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var notchPanel: NotchPanel?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let hotkey = HotkeyMonitor()
    private let voice = VoiceInput()
    private let indicator = IndicatorModel.shared
    private var heldVoice = false
    private var placementInUse: Placement?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        AgentRegistry.shared.refresh()
        Task { await ComposioService.shared.refresh() }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ChatView(
            voice: voice,
            openSettings: { [weak self] in self?.openSettings(.source) },
            openHistory: { [weak self] in self?.openSettings(.history) },
            toggleMic: { [weak self] in self?.toggleMic() }))

        indicator.start(voice: voice)
        Kokoro.shared.loadIfInstalled()
        applyPlacement()
        // Keep the notch or menu bar pill in step with what Agent2 is doing.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIndicator() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placementInUse = nil; self?.applyPlacement() }
        }

        hotkey.onPress = { [weak self] in self?.hotkeyDown() }
        hotkey.onRelease = { [weak self] held in self?.hotkeyUp(held: held) }
        applyHotkeySetting()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotkeySetting(); self?.applyPlacement() }
        }

        Updater.shared.startAutomaticChecks()
        // Just updated? macOS ties Accessibility to the exact build, so the ⌃⌥
        // shortcut may need allowing again: take the person straight there.
        let d = UserDefaults.standard
        if let last = d.string(forKey: "lastRunVersion"), last != Updater.currentVersion,
           AppSettings.shared.hotkeyEnabled, !HotkeyMonitor.ensureAccessibility(prompt: false) {
            openSettings(.voice)
        }
        d.set(Updater.currentVersion, forKey: "lastRunVersion")

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

    // MARK: Notch or menu bar

    /// The placement that will actually be used on this Mac right now.
    private var effectivePlacement: Placement {
        switch AppSettings.shared.placement {
        case .menuBar: return .menuBar
        case .notch, .auto: return NotchGeometry.find() == nil ? .menuBar : .notch
        }
    }

    private func applyPlacement() {
        let want = effectivePlacement
        guard want != placementInUse else { return }
        placementInUse = want
        popover.performClose(nil)
        if want == .notch, let g = NotchGeometry.find() {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
            notchPanel?.orderOut(nil)
            let panel = NotchPanel(geometry: g, model: indicator,
                                   onClick: { [weak self] in self?.togglePopover() },
                                   onRightClick: { [weak self] in self?.showMenu() })
            panel.orderFrontRegardless()
            notchPanel = panel
        } else {
            notchPanel?.orderOut(nil)
            notchPanel = nil
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = PixelBird.menuBarImage(height: 17)
                item.button?.toolTip = "Agent2 — hold ⌃⌥ to talk"
                item.button?.target = self
                item.button?.action = #selector(statusItemClicked)
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                statusItem = item
            }
        }
    }

    private var lastPhase: IndicatorPhase = .idle
    private func refreshIndicator() {
        let phase = indicator.phase
        if let panel = notchPanel, phase != lastPhase { panel.show(phase, animated: true) }
        if let button = statusItem?.button, phase != .idle || lastPhase != .idle {
            button.image = MenuBarPill.image(for: indicator)
        }
        lastPhase = phase
    }

    /// The view the chat popover hangs from: the notch, or the menu bar icon.
    private var anchorView: NSView? { notchPanel?.clickView ?? statusItem?.button }

    // MARK: Chat popover and menu

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        togglePopover()
    }

    private func togglePopover() {
        if Speaker.shared.isSpeaking { Speaker.shared.stop(); return }   // a click hushes Agent2
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let anchor = anchorView else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Agent2", action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New conversation", action: #selector(menuNew), keyEquivalent: "n").target = self
        if Speaker.shared.isSpeaking {
            menu.addItem(withTitle: "Stop speaking", action: #selector(menuHush), keyEquivalent: "").target = self
        }
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
        if let r = Updater.shared.available {
            menu.addItem(withTitle: "Update to v\(r.version)…", action: #selector(menuUpdate), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Check for updates…", action: #selector(menuCheckUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Open history folder", action: #selector(menuHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let item = statusItem {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if let anchor = anchorView {
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.midX - 60, y: -4), in: anchor)
        }
    }

    @objc private func menuOpen() { showPopover() }
    @objc private func menuNew() { Orchestrator.shared.newConversation(); showPopover() }
    @objc private func menuHush() { Speaker.shared.stop() }
    @objc private func menuSettings() { openSettings(.source) }
    @objc private func menuUpdate() { openSettings(.about) }
    @objc private func menuCheckUpdates() {
        openSettings(.about)
        Task { await Updater.shared.check() }
    }
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

    // MARK: Voice (hands-free)

    private func hotkeyDown() {
        // Hands-free: a tap cuts Agent2 off if it's talking, otherwise starts or ends the conversation.
        if AppSettings.shared.listenMode == .handsFree {
            if Speaker.shared.isSpeaking { Speaker.shared.stop() } else { HandsFree.shared.toggle() }
            return
        }
        heldVoice = true
        Speaker.shared.stop()   // talking over Agent2 interrupts it, like a person
        Task {
            guard await voice.requestPermissions() else { showPopover(); return }
            // Only start once the keys have been held briefly, so a quick tap stays a tap.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard heldVoice else { return }
            NSSound(named: "Tink")?.play()
            voice.start()
        }
    }

    private func hotkeyUp(held: TimeInterval) {
        if AppSettings.shared.listenMode == .handsFree { return }
        heldVoice = false
        Task {
            if voice.isListening {
                let text = await voice.stop()
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    NSSound(named: "Pop")?.play()
                    Orchestrator.shared.send(text, spoken: true)
                }
            } else if held < 0.35 {
                togglePopover()
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
