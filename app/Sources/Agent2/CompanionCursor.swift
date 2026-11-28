import AppKit
import QuartzCore
import SwiftUI

/// Agent2's companion cursor: a green pointer that shows where the agent is
/// working, next to (never instead of) the person's real pointer.
///
/// - Agent moves (`move_cursor`, clicks, drags from Cua Driver, reported by
///   `CuaProxy`) glide along a gentle curve with ease-in-out and a small
///   overshoot, then settle. Clicks leave a soft green ripple.
/// - Otherwise it stays next to the person's pointer the whole time Agent2 runs
///   (like a companion), so it's always clear where they're pointing: that spot
///   is sent to the agent with the screenshot.
/// - When the agent answers with a place on screen (`point(at:label:)`) it flies
///   there, rings the spot and shows a label, then comes back.
/// - It leaves a comet-style trail that tapers and fades over `companionTrail` seconds.
///
/// Drawing: one transparent, click-through panel per display, above normal
/// windows and on every Space. Frames come from a display link (up to 120 Hz)
/// that is paused whenever nothing is moving, so it costs nothing when idle.
@MainActor
final class CompanionCursor: NSObject {
    static let shared = CompanionCursor()

    /// Dev tools: let screenshots include the overlay (normally it's left out of
    /// screen captures so the agent's own screenshots don't show it).
    var capturable = false

    // MARK: State (global Cocoa coordinates: origin bottom-left of the main display)

    private(set) var position = CGPoint(x: -100, y: -100)
    private var alpha: CGFloat = 0
    private var trail: [(p: CGPoint, t: CFTimeInterval)] = []
    private var ripples: [(p: CGPoint, t: CFTimeInterval)] = []
    private var glide: Glide?
    private var lastActivity: CFTimeInterval = 0
    private var agentHoldUntil: CFTimeInterval = 0
    private var lastAgentEvent: CFTimeInterval = -100
    private var lastFrame: CFTimeInterval = 0
    private var lastMouseMove: CFTimeInterval = -100
    /// What the agent is pointing out, while it's held there.
    private var pointLabel: String?
    private var pointSpot: CGPoint?

    private struct Glide {
        var from, control, to: CGPoint
        var start, duration: CFTimeInterval
        var kind: String
        var lastU: Double = 0
    }

    private var panels: [NSPanel] = []
    private var views: [OverlayView] = []
    private var link: CADisplayLink?
    private var mouseMonitors: [Any] = []
    private var started = false

    static let maxOpacity: CGFloat = 0.92
    static let holdAfterAgent: CFTimeInterval = 3.5
    static let holdAfterPoint: CFTimeInterval = 7
    static let fadeAfterIdle: CFTimeInterval = 3
    static let shadowOffset = CGVector(dx: 16, dy: -20)

    private var settings: AppSettings { .shared }
    private var trailDuration: CFTimeInterval { max(0.15, min(1.2, settings.companionTrail)) }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(agentCursorMoved(_:)), name: CuaProxy.notification, object: nil,
            suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Switched to another app: what was pointed out may not be there any more.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        refresh()
    }

    /// Builds or tears down the overlay to match the setting.
    func refresh() {
        guard started else { return }
        if settings.companionCursor {
            if panels.isEmpty { buildPanels() }
            if mouseMonitors.isEmpty {
                let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
                if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) { mouseMonitors.append(g) }
                if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) { mouseMonitors.append(l) }
            }
        } else {
            for m in mouseMonitors { NSEvent.removeMonitor(m) }
            mouseMonitors = []
            link?.invalidate(); link = nil
            for p in panels { p.orderOut(nil) }
            panels = []; views = []
            trail = []; ripples = []; glide = nil; alpha = 0
        }
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { clearPoint() }
    }

    @objc private func screensChanged() {
        guard settings.companionCursor else { return }
        link?.invalidate(); link = nil
        for p in panels { p.orderOut(nil) }
        panels = []; views = []
        buildPanels()
    }

    private func buildPanels() {
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.sharingType = capturable ? .readOnly : .none
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.owner = self
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
    }

    // MARK: - Input

    @objc private func agentCursorMoved(_ note: Notification) {
        guard let info = note.userInfo, let x = info["x"] as? Double, let y = info["y"] as? Double else { return }
        if Self.trace { print("agent cursor event:", info["kind"] ?? "?", x, y) }
        agentAction(at: Self.cocoaPoint(fromTopLeft: CGPoint(x: x, y: y)), kind: info["kind"] as? String ?? "move")
    }

    /// The agent's cursor goes to `p` (global Cocoa coordinates) and does `kind`
    /// there: move, click, double, right, drag or steps.
    func agentAction(at p: CGPoint, kind: String) {
        guard settings.companionCursor, !panels.isEmpty else { return }
        let now = CACurrentMediaTime()
        lastAgentEvent = now
        lastActivity = now
        agentHoldUntil = now + Self.holdAfterAgent
        if alpha < 0.05, glide == nil {
            // Not on screen yet: set off from the person's pointer, like a companion would.
            position = Self.offset(NSEvent.mouseLocation)
            trail = []
        }
        let distance = hypot(p.x - position.x, p.y - position.y)
        if distance < 2 {
            glide = nil
            position = p
            landed(kind: kind, at: now)
        } else {
            // A gentle arc: the control point sits off to one side of the straight line.
            let mid = CGPoint(x: (position.x + p.x) / 2, y: (position.y + p.y) / 2)
            var normal = CGVector(dx: -(p.y - position.y) / distance, dy: (p.x - position.x) / distance)
            if normal.dy < 0 { normal = CGVector(dx: -normal.dx, dy: -normal.dy) }   // bow upward
            let bow = min(140, distance * 0.2)
            let control = CGPoint(x: mid.x + normal.dx * bow, y: mid.y + normal.dy * bow)
            let duration = min(0.9, max(0.38, 0.3 + Double(distance) / 2400))
            glide = Glide(from: position, control: control, to: p, start: now, duration: duration, kind: kind)
        }
        wake()
    }

    private func mouseMoved() {
        lastMouseMove = CACurrentMediaTime()
        if settings.companionFollows { wake() }
    }

    /// Settings → Preview: a short tour from the pointer, with a click and a double click.
    func preview() {
        let m = NSEvent.mouseLocation
        let steps: [(CGVector, String, Double)] = [
            (CGVector(dx: 220, dy: 90), "move", 0), (CGVector(dx: 380, dy: -120), "click", 1.1),
            (CGVector(dx: 120, dy: -220), "double", 2.2), (CGVector(dx: 30, dy: -40), "move", 3.3),
        ]
        for (d, kind, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.agentAction(at: CGPoint(x: m.x + d.dx, y: m.y + d.dy), kind: kind)
            }
        }
    }

    /// The agent points something out: fly there, ring it and show `label`, then
    /// go back to the person's pointer after a few seconds (or `clearPoint()`).
    func point(at p: CGPoint, label: String?) {
        guard settings.companionCursor, !panels.isEmpty else { return }
        let old = pointBounds()
        pointLabel = label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String($0.prefix(48)) }
        pointSpot = nil
        invalidate(old)
        agentAction(at: p, kind: "point")
    }

    /// Back to the person's pointer now (they switched app, cancelled, asked again).
    func clearPoint() {
        guard pointSpot != nil || glide?.kind == "point" else { return }
        let old = pointBounds()
        pointSpot = nil; pointLabel = nil
        if glide?.kind == "point" { glide = nil }
        agentHoldUntil = 0
        invalidate(old)
        wake()
    }

    /// Dev tools: print each agent cursor event.
    static var trace = false

    // MARK: - Frames

    private func wake() {
        if link == nil, let v = views.first {
            let l = v.displayLink(target: self, selector: #selector(frame(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
            lastFrame = CACurrentMediaTime()
        }
        link?.isPaused = false
    }

    @objc private func frame(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, now - lastFrame))
        lastFrame = now
        let before = dirtyBounds()

        if var g = glide {
            let u = min(1, (now - g.start) / g.duration)
            // Fill the trail from the curve itself (every few points), so a late
            // frame never shows up as a straight piece or a corner.
            let prev = Self.bezier(g.from, g.control, g.to, Self.glideEase(g.lastU))
            let next = Self.bezier(g.from, g.control, g.to, Self.glideEase(u))
            let steps = min(40, Int(hypot(next.x - prev.x, next.y - prev.y) / 5))
            if steps > 1 {
                for k in 1..<steps {
                    let f = Double(k) / Double(steps)
                    let uk = g.lastU + (u - g.lastU) * f
                    trail.append((Self.bezier(g.from, g.control, g.to, Self.glideEase(uk)), g.start + uk * g.duration))
                }
            }
            g.lastU = u
            glide = g
            position = next
            lastActivity = now
            if u >= 1 {
                position = g.to
                glide = nil
                landed(kind: g.kind, at: now)
            }
        } else if settings.companionFollows, now > agentHoldUntil {
            // Shadow the real pointer: a small offset and a lazy lag.
            let target = Self.offset(NSEvent.mouseLocation)
            if alpha < 0.05 { position = target; trail = [] }
            let k = 1 - exp(-dt * 7)
            position.x += (target.x - position.x) * k
            position.y += (target.y - position.y) * k
            if hypot(target.x - position.x, target.y - position.y) > 0.3 { lastActivity = now }
        }

        // Trail: record the tip, forget what's older than the fade time.
        if let last = trail.last?.p, hypot(last.x - position.x, last.y - position.y) < 0.4 {} else { trail.append((position, now)) }
        trail.removeAll { now - $0.t > trailDuration }
        ripples.removeAll { now - $0.t > Self.rippleDuration }

        // The point-out is over: back to the person's pointer.
        if pointSpot != nil, now > agentHoldUntil {
            invalidate(pointBounds())
            pointSpot = nil; pointLabel = nil
        }

        // Always shown next to the person's pointer when following; otherwise fade
        // in while active and out a few seconds after everything goes still.
        let visible = settings.companionFollows || glide != nil || now - lastActivity < Self.fadeAfterIdle || now < agentHoldUntil
        let goal: CGFloat = visible ? Self.maxOpacity : 0
        let rate: CGFloat = visible ? 9 : 2.2
        alpha += (goal - alpha) * (1 - exp(-CGFloat(dt) * rate))
        if abs(goal - alpha) < 0.004 { alpha = goal }

        invalidate(before.union(dirtyBounds()))

        let following = settings.companionFollows && now > agentHoldUntil
        let settled = !following || hypot(Self.offset(NSEvent.mouseLocation).x - position.x,
                                          Self.offset(NSEvent.mouseLocation).y - position.y) < 0.3
        let still = glide == nil && ripples.isEmpty && (trail.count <= 1) && alpha == goal && settled
            && pointSpot == nil && !(following && now - lastMouseMove < 0.5)
        if still {
            if alpha == 0 { trail = [] }
            l.isPaused = true
        }
    }

    private func landed(kind: String, at now: CFTimeInterval) {
        switch kind {
        case "click", "right", "steps": ripples.append((position, now))
        case "double": ripples.append((position, now)); ripples.append((position, now + 0.13))
        case "drag": ripples.append((position, now))
        case "point": ripples.append((position, now)); pointSpot = position
        default: break
        }
        agentHoldUntil = now + (kind == "point" ? Self.holdAfterPoint : Self.holdAfterAgent)
        lastActivity = now
    }

    private func invalidate(_ rect: CGRect) {
        guard !rect.isNull else { return }
        for (panel, view) in zip(panels, views) where panel.frame.intersects(rect) {
            let local = rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY).integral
            view.setNeedsDisplay(local)
        }
    }

    /// Everything currently drawn, in global coordinates (with room for shadow and width).
    private func dirtyBounds() -> CGRect {
        var r = CGRect.null
        if alpha > 0 { r = r.union(Self.pointerBox.offsetBy(dx: position.x, dy: position.y).insetBy(dx: -2, dy: -2)) }
        for pt in trail { r = r.union(CGRect(x: pt.p.x - 10, y: pt.p.y - 10, width: 20, height: 20)) }
        for rp in ripples { r = r.union(CGRect(x: rp.p.x - 36, y: rp.p.y - 36, width: 72, height: 72)) }
        return r.union(pointBounds())
    }

    /// The ring and label around a pointed-out spot.
    private func pointBounds() -> CGRect {
        guard let s = pointSpot else { return .null }
        return CGRect(x: s.x - 340, y: s.y - 60, width: 680, height: 120)
    }

    // MARK: - Drawing

    static let rippleDuration: CFTimeInterval = 0.6
    static let green = NSColor(Theme.green)

    fileprivate func draw(in ctx: CGContext, viewOrigin: CGPoint, dirty: CGRect) {
        let now = CACurrentMediaTime()
        ctx.saveGState()
        ctx.translateBy(x: -viewOrigin.x, y: -viewOrigin.y)
        drawTrail(ctx, now: now)
        drawRipples(ctx, now: now)
        drawPointOut(ctx, now: now)
        if alpha > 0.01 { drawPointer(ctx, at: position, alpha: alpha) }
        ctx.restoreGState()
    }

    /// A comet tail: round strokes from the oldest point to the newest, each a bit
    /// wider and stronger, drawn with `.copy` inside a transparency layer so the
    /// overlaps don't build up into visible segments.
    private func drawTrail(_ ctx: CGContext, now: CFTimeInterval) {
        guard trail.count > 1, alpha > 0.01 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha / Self.maxOpacity)
        ctx.beginTransparencyLayer(in: trailBounds(), auxiliaryInfo: nil)
        ctx.setBlendMode(.copy)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Smooth the sampled points into a curve (Catmull-Rom), so fast moves
        // don't show as straight pieces with corners.
        let raw = trail.map { ($0.p, now - $0.t) } + [(position, 0.0)]
        var pts: [(p: CGPoint, age: Double)] = []
        for i in 0..<(raw.count - 1) {
            let p0 = raw[max(0, i - 1)].0, p1 = raw[i].0, p2 = raw[i + 1].0, p3 = raw[min(raw.count - 1, i + 2)].0
            let steps = max(1, min(12, Int(hypot(p2.x - p1.x, p2.y - p1.y) / 4)))
            for k in 0..<steps {
                let t = CGFloat(k) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                pts.append((CGPoint(x: cr(p0.x, p1.x, p2.x, p3.x), y: cr(p0.y, p1.y, p2.y, p3.y)),
                            raw[i].1 + (raw[i + 1].1 - raw[i].1) * Double(t)))
            }
        }
        pts.append(raw[raw.count - 1])
        // Stroke in bands (consecutive pieces of about the same strength as one path):
        // ~20 strokes a frame instead of hundreds. Each band overlaps the previous
        // by one point and `.copy` keeps the joins seamless.
        let bands = 20
        func level(_ age: Double) -> Int {
            let life = 1 - min(1, age / trailDuration)               // 1 at the head, 0 at the tail
            return Int((life * Double(bands)).rounded(.up))
        }
        var i = 1
        while i < pts.count {
            let band = level(pts[i].age)
            let path = CGMutablePath()
            path.move(to: pts[i - 1].p)
            while i < pts.count, level(pts[i].age) == band { path.addLine(to: pts[i].p); i += 1 }
            guard band > 0 else { continue }
            let life = Double(band) / Double(bands)
            let e = life * life * (3 - 2 * life)                     // smoothstep
            ctx.setLineWidth(0.6 + 7.4 * pow(e, 1.4))
            ctx.setStrokeColor(Self.green.withAlphaComponent(0.55 * pow(e, 1.3)).cgColor)
            ctx.addPath(path); ctx.strokePath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func trailBounds() -> CGRect {
        var r = CGRect(x: position.x - 6, y: position.y - 6, width: 12, height: 12)
        for pt in trail { r = r.union(CGRect(x: pt.p.x - 6, y: pt.p.y - 6, width: 12, height: 12)) }
        return r
    }

    /// A soft ring that breathes around the spot, and the label beside the pointer.
    private func drawPointOut(_ ctx: CGContext, now: CFTimeInterval) {
        guard let s = pointSpot else { return }
        let fade = CGFloat(min(1, max(0, (agentHoldUntil - now) / 0.4)))
        let breathe = CGFloat(0.5 + 0.5 * sin(now * 4))
        let radius = 17 + 3 * breathe
        ctx.setStrokeColor(Self.green.withAlphaComponent(0.85 * fade).cgColor)
        ctx.setFillColor(Self.green.withAlphaComponent(0.10 * fade).cgColor)
        ctx.setLineWidth(2.5)
        let rect = CGRect(x: s.x - radius, y: s.y - radius, width: radius * 2, height: radius * 2)
        ctx.fillEllipse(in: rect)
        ctx.strokeEllipse(in: rect)
        guard let label = pointLabel else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(fade),
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        // Beside the spot, below and to the right, flipped to whichever side keeps it on screen.
        let w = min(300, size.width + 20), h = size.height + 10
        let bounds = NSScreen.screens.first(where: { NSMouseInRect(s, $0.frame, false) })?.frame ?? .infinite
        var pill = CGRect(x: s.x + 22, y: s.y - 44, width: w, height: h)
        if pill.maxX > bounds.maxX - 6 { pill.origin.x = s.x - 22 - w }
        if pill.minY < bounds.minY + 6 { pill.origin.y = s.y + 24 }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.3 * fade).cgColor)
        ctx.setFillColor(Self.green.withAlphaComponent(0.95 * fade).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(with: CGRect(x: pill.minX + 10, y: pill.minY + 5, width: pill.width - 20, height: size.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawRipples(_ ctx: CGContext, now: CFTimeInterval) {
        for r in ripples where now >= r.t {
            let u = min(1, (now - r.t) / Self.rippleDuration)
            let grow = 1 - pow(1 - u, 3)                             // ease-out
            let radius = 5 + 24 * grow
            ctx.setStrokeColor(Self.green.withAlphaComponent(0.6 * pow(1 - u, 1.5)).cgColor)
            ctx.setFillColor(Self.green.withAlphaComponent(0.12 * (1 - u)).cgColor)
            ctx.setLineWidth(2.2 * (1 - u) + 0.6)
            let rect = CGRect(x: r.p.x - radius, y: r.p.y - radius, width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
        }
    }

    /// The pointer, drawn once per display scale and reused every frame.
    private var pointerImages: [CGFloat: CGImage] = [:]
    static let pointerBox = CGRect(x: -6, y: -27, width: 32, height: 33)   // around the tip, y-up

    private func drawPointer(_ ctx: CGContext, at p: CGPoint, alpha: CGFloat) {
        let scale = max(1, ctx.userSpaceToDeviceSpaceTransform.a)
        if pointerImages[scale] == nil { pointerImages[scale] = Self.renderPointer(scale: scale) }
        guard let image = pointerImages[scale] else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: Self.pointerBox.offsetBy(dx: p.x, dy: p.y))
        ctx.restoreGState()
    }

    /// A classic arrow pointer in Agent2 green with a white edge and a soft shadow.
    static func renderPointer(scale: CGFloat) -> CGImage? {
        let box = pointerBox
        guard let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)   // tip at (0, 0)
        ctx.scaleBy(x: 1, y: -1)                     // the shape below is drawn y-down
        // A rounded arrowhead: tip at the top-left, a long wing to the right, a
        // notch, and a shorter stem down.
        let tip = CGPoint(x: 0, y: 0), wing = CGPoint(x: 19.5, y: 7.6)
        let notch = CGPoint(x: 10.4, y: 10.9), stem = CGPoint(x: 7.5, y: 19.5)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: (tip.x + wing.x) / 2, y: (tip.y + wing.y) / 2))
        path.addArc(tangent1End: wing, tangent2End: notch, radius: 2.2)
        path.addArc(tangent1End: notch, tangent2End: stem, radius: 1.6)
        path.addArc(tangent1End: stem, tangent2End: tip, radius: 2.2)
        path.addArc(tangent1End: tip, tangent2End: wing, radius: 2.0)
        path.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 4 * scale,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(green.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(1.3)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.strokePath()
        return ctx.makeImage()
    }

    // MARK: - Maths

    static func offset(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + shadowOffset.dx, y: p.y + shadowOffset.dy) }

    /// Cua reports points with the origin at the top-left of the main display.
    static func cocoaPoint(fromTopLeft p: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let t = CGFloat(t), m = 1 - t
        return CGPoint(x: m * m * a.x + 2 * m * t * c.x + t * t * b.x,
                       y: m * m * a.y + 2 * m * t * c.y + t * t * b.y)
    }

    /// Ease in, ease out with a small overshoot that settles (about 4% past the target).
    static func glideEase(_ u: Double) -> Double {
        let x = 1 - cos(u * .pi / 2)                         // ease in (sine)
        let c1 = 0.9, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)  // ease-out back
    }
}

/// One display's overlay. Draws only what changed (the dirty rect).
private final class OverlayView: NSView {
    weak var owner: CompanionCursor?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let window else { return }
        ctx.clear(dirtyRect)
        MainActor.assumeIsolated {
            owner?.draw(in: ctx, viewOrigin: window.frame.origin, dirty: dirtyRect)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
