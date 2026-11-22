import SwiftUI

/// Dark, crisp developer-tool look (in the spirit of Composio and Render),
/// with Agent2 green #548A47 as the one accent colour.
enum Theme {
    static let green = Color(red: 0x54 / 255, green: 0x8A / 255, blue: 0x47 / 255)
    static let greenBright = Color(red: 0x7B / 255, green: 0xC0 / 255, blue: 0x6A / 255)
    static let bg = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0A / 255)
    static let panel = Color(red: 0x12 / 255, green: 0x15 / 255, blue: 0x12 / 255)
    static let panelRaised = Color(red: 0x1A / 255, green: 0x1E / 255, blue: 0x1A / 255)
    static let border = Color.white.opacity(0.08)
    static let text = Color(red: 0xEC / 255, green: 0xEF / 255, blue: 0xEA / 255)
    static let muted = Color(red: 0x8C / 255, green: 0x94 / 255, blue: 0x8A / 255)
    static let mono = Font.system(.caption, design: .monospaced)
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

struct Pill: View {
    let text: String
    var color: Color = Theme.green
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(color == Theme.green ? Theme.greenBright : color)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.green.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.white)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panelRaised.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
            .foregroundStyle(Theme.text)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}
