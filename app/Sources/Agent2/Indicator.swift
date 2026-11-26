import AppKit
import SwiftUI

/// What Agent2 is doing right now, shown in the notch or the menu bar.
enum IndicatorPhase: Equatable {
    case idle, listening, thinking, speaking
    var label: String {
        switch self {
        case .idle: return ""
        case .listening: return "Listening"
        case .thinking: return "Working"
        case .speaking: return "Speaking"
        }
    }
}

/// Shared state for both indicators. Polled from the voice input, the orchestrator
/// and the speaker so it always reflects what's really happening.
@MainActor
final class IndicatorModel: ObservableObject {
    static let shared = IndicatorModel()
    @Published var phase: IndicatorPhase = .idle
    @Published var level: CGFloat = 0          // 0…1, drives the bars
    @Published var tick: Int = 0               // animation clock
    @Published var ready = true                // a source agent is available

    private var timer: Timer?
    weak var voice: VoiceInput?

    func start(voice: VoiceInput) {
        self.voice = voice
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        let conversation = HandsFree.shared
        let speaking = Speaker.shared.isSpeaking
        let working = Orchestrator.shared.isWorking
        // In a hands-free conversation the pill stays open: listening whenever Agent2 isn't busy.
        let listening = (voice?.isListening ?? false) || (conversation.isOn && !speaking && !working)
        let next: IndicatorPhase = (voice?.isListening ?? false) ? .listening
            : speaking ? .speaking : working ? .thinking : listening ? .listening : .idle
        if next != phase { phase = next }
        ready = AgentRegistry.shared.source != nil
        guard phase != .idle else { if level != 0 { level = 0 }; return }
        tick &+= 1
        switch phase {
        case .listening:
            let input = HandsFree.shared.isOn ? HandsFree.shared.level : (voice?.level ?? 0)
            level = level * 0.5 + CGFloat(input) * 0.5
        case .speaking: level = 0.35 + 0.45 * abs(sin(Double(tick) * 0.9)) * CGFloat.random(in: 0.6...1)
        default: level = 0
        }
    }

    /// Heights (0…1) for `count` waveform bars.
    func bars(_ count: Int) -> [CGFloat] {
        (0..<count).map { i in
            switch phase {
            case .listening, .speaking:
                let wobble = 0.55 + 0.45 * sin(Double(tick) * 0.7 + Double(i) * 1.3)
                return max(0.18, min(1, level * 1.6 * CGFloat(wobble) + 0.12))
            case .thinking:
                return (tick / 3) % count == i ? 1 : 0.3
            case .idle:
                return 0.2
            }
        }
    }
}

// MARK: - Menu bar pill

/// The menu bar icon: the bird when idle, a green pill with live bars while
/// Agent2 is listening, working or speaking.
@MainActor
enum MenuBarPill {
    static func image(for model: IndicatorModel) -> NSImage {
        if model.phase == .idle { return PixelBird.menuBarImage(height: 17) }
        let h: CGFloat = 22, w: CGFloat = 62
        let bars = model.bars(5)
        let fill = model.phase == .thinking ? NSColor(Theme.green).withAlphaComponent(0.85) : NSColor(Theme.green)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: (h - 3) / 2, yRadius: (h - 3) / 2)
            fill.setFill()
            pill.fill()
            NSGraphicsContext.current?.shouldAntialias = false
            PixelBird.draw(in: NSRect(x: 9, y: 4, width: 12, height: 14), color: PixelBird.ink)
            NSGraphicsContext.current?.shouldAntialias = true
            for (i, b) in bars.enumerated() {
                let bh = max(3, (h - 10) * b)
                let r = NSRect(x: 27 + CGFloat(i) * 5.5, y: (h - bh) / 2, width: 3, height: bh)
                PixelBird.ink.setFill()
                NSBezierPath(rect: r).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - Notch

/// Geometry of the camera housing on MacBooks that have one.
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat

    static func find() -> NotchGeometry? {
        for s in NSScreen.screens where s.safeAreaInsets.top > 0 {
            guard let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { continue }
            let w = s.frame.width - l.width - r.width
            if w > 40 { return NotchGeometry(screen: s, width: w, height: s.safeAreaInsets.top) }
        }
        return nil
    }
}

/// A borderless panel that sits on the notch. It looks like part of the notch
/// when idle (a bird on one side, a status square on the other) and grows into
/// a green pill while Agent2 listens, works or speaks.
@MainActor
final class NotchPanel: NSPanel {
    static let idleEar: CGFloat = 30
    static let activeEar: CGFloat = 104

    private let geometry: NotchGeometry
    let clickView: ClickView

    init(geometry: NotchGeometry, model: IndicatorModel, onClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
        self.geometry = geometry
        clickView = ClickView(frame: .zero)
        clickView.onClick = onClick
        clickView.onRightClick = onRightClick
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        let host = NSHostingView(rootView: NotchView(model: model, notchWidth: geometry.width, height: geometry.height))
        host.translatesAutoresizingMaskIntoConstraints = false
        clickView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: clickView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clickView.trailingAnchor),
            host.topAnchor.constraint(equalTo: clickView.topAnchor),
            host.bottomAnchor.constraint(equalTo: clickView.bottomAnchor),
        ])
        contentView = clickView
        setFrame(frame(for: .idle), display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allow the panel to sit in the menu bar area at the very top of the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func frame(for phase: IndicatorPhase) -> NSRect {
        let ear = phase == .idle ? Self.idleEar : Self.activeEar
        let w = geometry.width + ear * 2
        let f = geometry.screen.frame
        return NSRect(x: f.midX - w / 2, y: f.maxY - geometry.height, width: w, height: geometry.height)
    }

    func show(_ phase: IndicatorPhase, animated: Bool) {
        let target = frame(for: phase)
        guard target != frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }
}

/// Takes all clicks for the notch panel (the SwiftUI content is display-only).
final class ClickView: NSView {
    var onClick: () -> Void = {}
    var onRightClick: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onRightClick() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchView: View {
    @ObservedObject var model: IndicatorModel
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let ear = max(0, (geo.size.width - notchWidth) / 2)
            HStack(spacing: 0) {
                leftEar.frame(width: ear)
                Color.clear.frame(width: notchWidth)
                rightEar.frame(width: ear)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(NotchShape(radius: min(10, height * 0.3)).fill(Color.black))
        }
        .animation(.easeOut(duration: 0.18), value: model.phase)
    }

    @ViewBuilder private var leftEar: some View {
        if model.phase == .idle {
            BirdMark(size: 14, color: Theme.greenBright).frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 6) {
                BirdMark(size: 12, color: PixelBirdColor.ink)
                Text(model.phase.label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(PixelBirdColor.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 9)
            .frame(height: max(16, height - 12))
            .background(Capsule().fill(Theme.green))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var rightEar: some View {
        if model.phase == .idle {
            Rectangle().fill(model.ready ? Theme.green : Theme.dim)
                .frame(width: 6, height: 6)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(model.bars(model.phase == .thinking ? 3 : 7).enumerated()), id: \.offset) { _, b in
                    Rectangle()
                        .fill(Theme.greenBright)
                        .frame(width: model.phase == .thinking ? 5 : 3,
                               height: model.phase == .thinking ? 5 : max(3, (height - 14) * b))
                        .opacity(model.phase == .thinking ? Double(0.35 + 0.65 * b) : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .transition(.opacity)
        }
    }
}

enum PixelBirdColor {
    static let ink = Color(nsColor: PixelBird.ink)
}

/// The notch outline: square top edge, rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
