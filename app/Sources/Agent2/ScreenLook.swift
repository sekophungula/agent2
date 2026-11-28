import AppKit
import ScreenCaptureKit

/// What the person is looking at when they ask something: a screenshot of the
/// display under their pointer, where the pointer is in it, and the app in front.
/// It's sent to the agent with the request, so "what's this?" or "where do I
/// click?" can be answered, and the agent can point back with `[POINT:x,y:label]`.
struct ScreenShot: Sendable {
    let displayID: CGDirectDisplayID
    /// The display in global Cocoa points (origin bottom-left of the main display).
    let frame: CGRect
    /// Pixel size of the image the agent sees (scaled down from the display).
    let imageSize: CGSize
    let file: URL
    /// The person's pointer in image pixels (origin top-left).
    let pointer: CGPoint
    let frontPID: pid_t?
    /// Where they moved the pointer while asking, in image pixels (drawn on the image).
    var trail: [CGPoint] = []
    /// What they were pointing at: the middle of a circle they drew, else where the pointer rested.
    var focus: CGPoint
    /// The control at `focus`, as the app describes it to accessibility (name, role, help).
    var element: String?
}

@MainActor
enum ScreenLook {
    /// Longest side of the image sent to the agent: enough to read UI, small enough to be quick.
    static let maxSide: CGFloat = 1280

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording (shows its prompt once; afterwards it's a switch in System Settings).
    static func request() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Captures the display under the pointer, leaving out Agent2's own windows
    /// (its chat panel and cursor overlay). Nil without permission or on failure.
    static func capture(spoken: Bool = false) async -> ScreenShot? {
        guard allowed else {
            // Ask macOS once, the first time it's needed; after that it's in Settings.
            if !UserDefaults.standard.bool(forKey: "askedScreenRecording") {
                UserDefaults.standard.set(true, forKey: "askedScreenRecording")
                _ = CGRequestScreenCaptureAccess()
            }
            return nil
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let frame = screen.frame
        // Asked from Agent2's own panel: what's behind it is what matters, whichever app that is.
        let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let front = frontApp == ProcessInfo.processInfo.processIdentifier ? nil : frontApp
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let scale = min(1, maxSide / max(frame.width, frame.height) * 1)   // points → image pixels
            let size = CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let imageSize = CGSize(width: image.width, height: image.height)
            // Where they pointed while talking (on this display), and what that was.
            let path = (spoken ? PointerTrail.shared.sinceMark() : []).filter { NSMouseInRect($0, frame, false) }
            let focusCocoa = PointerTrail.focus(of: path) ?? mouse
            let toImage = { (p: CGPoint) in imagePoint(fromCocoa: p, frame: frame, imageSize: imageSize) }
            let trail = path.map(toImage)
            let annotated = trail.count > 2 ? draw(trail: trail, on: image) ?? image : image
            let rep = NSBitmapImageRep(cgImage: annotated)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent2-screen-\(UUID().uuidString).jpg")
            try jpeg.write(to: file)
            return ScreenShot(displayID: id, frame: frame, imageSize: imageSize, file: file,
                              pointer: toImage(mouse), frontPID: front, trail: trail, focus: toImage(focusCocoa),
                              element: AXDescriber.describe(atCocoa: focusCocoa))
        } catch {
            return nil
        }
    }

    /// The pointer's path drawn over the screenshot as a thin magenta line, so the
    /// agent sees a circle or a sweep the way the person made it.
    static func draw(trail: [CGPoint], on image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // image pixels, origin top-left
        let path = CGMutablePath()
        path.addLines(between: trail)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(5); ctx.addPath(path); ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.5); ctx.addPath(path); ctx.strokePath()
        return ctx.makeImage()
    }

    // MARK: Coordinates (the only place screenshot pixels and screen points meet)

    /// A global Cocoa point → pixels in an image of `frame`'s display (origin top-left).
    nonisolated static func imagePoint(fromCocoa p: CGPoint, frame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(x: (p.x - frame.minX) * imageSize.width / frame.width,
                y: (frame.maxY - p.y) * imageSize.height / frame.height)
    }

    /// Pixels in the image (origin top-left) → a global Cocoa point. Each axis is
    /// scaled on its own and the display's origin is added, so it holds for any
    /// scale factor and for displays that don't start at (0, 0).
    nonisolated static func cocoaPoint(fromImage p: CGPoint, frame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(x: frame.minX + p.x * frame.width / imageSize.width,
                y: frame.maxY - p.y * frame.height / imageSize.height)
    }

    // MARK: The agent pointing back

    struct Mark: Equatable { let x: Double; let y: Double; let label: String }

    nonisolated static let markPattern = #"\[POINT:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?::\s*([^\]\n]*))?\]"#

    /// The first `[POINT:x,y:label]` in `text`.
    nonisolated static func mark(in text: String) -> Mark? {
        guard let r = text.range(of: markPattern, options: .regularExpression) else { return nil }
        let inner = text[r].dropFirst("[POINT:".count).dropLast()
        let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let xy = parts[0].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard xy.count == 2, let x = xy[0], let y = xy[1] else { return nil }
        let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return Mark(x: x, y: y, label: label)
    }

    /// `text` without any `[POINT:…]` marks.
    nonisolated static func withoutMarks(_ text: String) -> String {
        text.replacingOccurrences(of: markPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows `mark` if it still makes sense: inside the screenshot, on a display
    /// that's still there in the same place, with the same app in front. Otherwise
    /// it's dropped rather than pointing at the wrong thing.
    @discardableResult
    static func show(_ mark: Mark, from shot: ScreenShot) -> Bool {
        guard mark.x >= 0, mark.y >= 0, mark.x <= shot.imageSize.width, mark.y <= shot.imageSize.height,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == shot.displayID
              }), screen.frame == shot.frame,
              shot.frontPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == shot.frontPID
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        else { return false }
        let p = cocoaPoint(fromImage: CGPoint(x: mark.x, y: mark.y), frame: shot.frame, imageSize: shot.imageSize)
        CompanionCursor.shared.point(at: p, label: mark.label)
        return true
    }

    private static func focusLine(_ shot: ScreenShot) -> String {
        var line: String
        if shot.trail.count > 2 {
            line = "While asking, they moved their pointer along the pink line drawn on the screenshot (Agent2 drew it; it isn't part of the app). It centres on (\(Int(shot.focus.x)), \(Int(shot.focus.y))): that's what they were pointing at or circling."
        } else {
            line = "Their pointer is at (\(Int(shot.focus.x)), \(Int(shot.focus.y)))."
        }
        if let el = shot.element {
            line += "\nThe app describes the control there as: \(el). Trust this name over guessing from the picture."
        }
        return line
    }

    /// Agents Agent2 can hand a screenshot to.
    static let imageAgents: Set<String> = ["claude-code", "codex"]

    /// Instructions sent with the screenshot.
    static func prompt(_ shot: ScreenShot) -> String {
        """
        <screen>
        A screenshot of the display the person is looking at is attached (\(Int(shot.imageSize.width))×\(Int(shot.imageSize.height)) pixels). \(focusLine(shot))
        When they say "this", "here" or "that", they mean what they pointed at: describe that thing, what it's for and how to use it, as a guide to the app would.
        To show them something on screen, put [POINT:x,y:short label] on its own line at the end of your reply, using the screenshot's pixel coordinates (origin top-left, the centre of the thing). Agent2 moves a cursor there. Point at most once, and only when it helps (they asked where something is or what to click); otherwise leave it out. Don't mention the screenshot or the coordinates.
        </screen>
        """
    }
}

/// Watches a reply as it streams in and moves the cursor the moment a complete
/// `[POINT:…]` mark has arrived (or, failing that, when the reply is done).
@MainActor
final class PointWatcher {
    var shot: ScreenShot?
    private var text = ""
    private var done = false

    func feed(_ piece: String) {
        guard shot != nil, !done else { return }
        text += piece
        check(text)
    }

    func finish(_ reply: String) { if !done { check(reply) } }

    private func check(_ s: String) {
        guard let shot, let mark = ScreenLook.mark(in: s) else { return }
        done = true
        ScreenLook.show(mark, from: shot)
    }
}
