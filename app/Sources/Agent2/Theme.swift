import SwiftUI

/// Squared-off developer-tool look: near-black surfaces, 1px rules, mono
/// uppercase labels, square controls. Agent2 green #548A47 is the one accent.
enum Theme {
    static let green = Color(hex: 0x548A47)
    static let greenBright = Color(hex: 0x7CBA6B)
    static let greenWash = Color(hex: 0x548A47).opacity(0.14)
    static let bg = Color(hex: 0x0B0B0B)
    static let panel = Color(hex: 0x111111)
    static let panelRaised = Color(hex: 0x171717)
    static let border = Color(hex: 0x242424)
    static let borderStrong = Color(hex: 0x333333)
    static let text = Color(hex: 0xEDEDED)
    static let muted = Color(hex: 0x8F8F8F)
    static let dim = Color(hex: 0x5C5C5C)
    static let amber = Color(hex: 0xE6C35C)
    static let red = Color(hex: 0xE5484D)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let radius: CGFloat = 2
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Square shape used everywhere instead of rounded rectangles and capsules.
struct Sq: Shape {
    func path(in rect: CGRect) -> Path { RoundedRectangle(cornerRadius: Theme.radius).path(in: rect) }
}

struct BirdMark: View {
    var size: CGFloat = 18
    var color: Color = Theme.greenBright
    var body: some View {
        Canvas { ctx, sz in
            let cell = min(sz.width / CGFloat(PixelBird.columns), sz.height / CGFloat(PixelBird.height))
            for (r, runs) in PixelBird.rows.enumerated() {
                for (a, b) in runs {
                    ctx.fill(Path(CGRect(x: CGFloat(a) * cell, y: CGFloat(r) * cell,
                                         width: CGFloat(b - a + 1) * cell, height: cell)), with: .color(color))
                }
            }
        }
        .frame(width: size * CGFloat(PixelBird.columns) / CGFloat(PixelBird.height), height: size)
    }
}

/// `// SECTION` style mono label.
struct MonoLabel: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(color)
    }
}

/// Small square status tag, e.g. `✓ LIVE`.
struct Tag: View {
    enum Tone { case ok, run, plain, warn }
    let text: String
    var tone: Tone = .plain
    var body: some View {
        let c: Color = switch tone {
        case .ok: Theme.greenBright
        case .run: Theme.amber
        case .warn: Theme.red
        case .plain: Theme.muted
        }
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tone == .plain ? Color.clear : c.opacity(0.10), in: Sq())
            .overlay(Sq().stroke(tone == .plain ? Theme.borderStrong : c.opacity(0.35), lineWidth: 1))
            .foregroundStyle(c)
            .fixedSize()
    }
}

/// Kept for older call sites: a tag in the green tone.
struct Pill: View {
    let text: String
    var color: Color = Theme.green
    var body: some View { Tag(text: text, tone: color == Theme.green ? .ok : .plain) }
}

/// White filled, mono uppercase, square.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(0.7)
            .textCase(.uppercase)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.8 : 1), in: Sq())
            .foregroundStyle(Theme.bg)
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Green filled variant for the one action that matters on a screen.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(0.7)
            .textCase(.uppercase)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Theme.green.opacity(configuration.isPressed ? 0.75 : 1), in: Sq())
            .foregroundStyle(.white)
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Outlined, mono uppercase, square.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.7)
            .textCase(.uppercase)
            .padding(.horizontal, 10).frame(height: 26)
            .background(configuration.isPressed ? Theme.panelRaised : Color.clear, in: Sq())
            .overlay(Sq().stroke(configuration.isPressed ? Theme.text : Theme.borderStrong))
            .foregroundStyle(Theme.text)
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Square checkbox instead of the rounded switch.
struct SquareToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    Rectangle().fill(configuration.isOn ? Theme.green : Color.clear)
                    Rectangle().stroke(configuration.isOn ? Theme.green : Theme.borderStrong, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                configuration.label.font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Square bordered text field.
struct SquareField: ViewModifier {
    var mono = true
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
            .padding(.horizontal, 9).frame(height: 28)
            .background(Theme.bg, in: Sq())
            .overlay(Sq().stroke(Theme.borderStrong))
    }
}
extension View {
    func squareField(mono: Bool = true) -> some View { modifier(SquareField(mono: mono)) }
}

/// A bordered block with an optional mono header bar, like a console panel.
struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    MonoLabel(text: title)
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.horizontal, 14).frame(height: 34)
                .background(Theme.panel)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.border))
    }
}

/// 1px horizontal rule.
struct Rule: View {
    var color: Color = Theme.border
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}
