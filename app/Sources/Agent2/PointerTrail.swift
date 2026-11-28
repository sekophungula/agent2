import AppKit
import ApplicationServices

/// Remembers where the pointer has been for the last minute (30 times a second),
/// so a spoken request can carry the gesture that went with it: circling a
/// button while asking "what does this do?", or resting on something.
@MainActor
final class PointerTrail {
    static let shared = PointerTrail()
    private var samples: [(p: CGPoint, t: CFTimeInterval)] = []
    private var markTime: CFTimeInterval = -1000
    private var timer: Timer?
    var replaying = false
    static let keep: CFTimeInterval = 60

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { PointerTrail.shared.sample() }
        }
    }

    /// Dev tools: pretend the pointer just moved along `path` while they talked.
    func replay(_ path: [CGPoint]) {
        let now = CACurrentMediaTime()
        markTime = now - 2
        samples = path.enumerated().map { ($1, now - 2 + Double($0) * 2 / Double(max(1, path.count))) }
    }

    /// The person started talking: the gesture starts here.
    func mark() { markTime = CACurrentMediaTime() }

    private func sample() {
        let now = CACurrentMediaTime()
        samples.append((NSEvent.mouseLocation, now))
        if let first = samples.first, now - first.t > Self.keep + 5 {
            samples.removeAll { now - $0.t > Self.keep }
        }
    }

    /// The pointer's path since they started talking (from a moment before), in
    /// global Cocoa points. A stationary pointer repeats, so how long it rested
    /// somewhere shows as how many points are there.
    func sinceMark() -> [CGPoint] {
        let now = CACurrentMediaTime()
        let from = now - markTime < Self.keep ? markTime - 0.5 : now - 3
        return samples.filter { $0.t >= from }.map(\.p) + (replaying ? [] : [NSEvent.mouseLocation])
    }

    /// What a path points at: the middle of it if they circled or scribbled over
    /// something, otherwise where the pointer spent the most time.
    static func focus(of path: [CGPoint]) -> CGPoint? {
        guard path.count >= 3 else { return path.last }
        let xs = path.map(\.x), ys = path.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let diagonal = hypot(box.width, box.height)
        if diagonal < 6 { return path.last }
        var length: CGFloat = 0
        for i in 1..<path.count { length += hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y) }
        // Going round something covers far more ground than the box it fits in.
        if length > 2.2 * diagonal, diagonal < 400 { return CGPoint(x: box.midX, y: box.midY) }
        // Otherwise: where it rested (the densest spot).
        let stride = max(1, path.count / 300)
        var best = path.last!, bestCount = 0
        for i in Swift.stride(from: 0, to: path.count, by: stride) {
            let c = path[i]
            let n = path.reduce(0) { $0 + (hypot($1.x - c.x, $1.y - c.y) < 20 ? 1 : 0) }
            if n > bestCount { bestCount = n; best = c }
        }
        return best
    }
}

/// Asks an app what control is at a spot, through the accessibility API (the
/// names VoiceOver reads): "button “Add files and more” in Claude". Far more
/// reliable than guessing from pixels, and it works in any app that labels its
/// controls. Needs Accessibility, which Agent2 already has for ⌃⌥.
@MainActor
enum AXDescriber {
    static func describe(atCocoa p: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let x = Float(p.x), y = Float(mainHeight - p.y)   // accessibility uses top-left screen points
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, x, y, &hit) == .success, var element = hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        // Electron and Chromium apps (Claude, Slack, VS Code…) only build their
        // accessibility tree once asked: ask, then look again.
        let app = AXUIElementCreateApplication(pid)
        if string(element, kAXRoleAttribute) == "AXGroup" || string(element, kAXRoleAttribute) == "AXWebArea" {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if AXUIElementCopyElementAtPosition(system, x, y, &hit) == .success, let again = hit { element = again }
        }
        // The hit is often an icon or label inside the control: climb to the control.
        var best = element
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let c = current else { break }
            let role = string(c, kAXRoleAttribute) ?? ""
            if Self.controlRoles.contains(role) { best = c; break }
            if label(c) != nil, best === element, label(element) == nil { best = c }
            current = parent(c)
        }
        var parts: [String] = []
        let roleName = string(best, kAXRoleDescriptionAttribute) ?? string(best, kAXRoleAttribute) ?? "element"
        parts.append(label(best).map { "\(roleName) \u{201C}\($0)\u{201D}" } ?? roleName)
        if let help = string(best, kAXHelpAttribute), !help.isEmpty, help != label(best) { parts.append("help: \u{201C}\(help)\u{201D}") }
        if let value = string(best, kAXValueAttribute), !value.isEmpty, value.count < 80, value != label(best) {
            parts.append("value: \u{201C}\(value)\u{201D}")
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { parts.append("in \(name)") }
        // Nothing but a bare group: not worth sending.
        if label(best) == nil, string(best, kAXHelpAttribute) == nil, !Self.controlRoles.contains(string(best, kAXRoleAttribute) ?? "") {
            return nil
        }
        return parts.joined(separator: ", ")
    }

    private static let controlRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXSlider", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXDisclosureTriangle", "AXComboBox",
        "AXSearchField", "AXSwitch", "AXToolbarButton", "AXDockItem", "AXIncrementor", "AXColorWell",
    ]

    private static func label(_ e: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(e, attr)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return String(s.prefix(80)) }
        }
        return nil
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func parent(_ e: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
