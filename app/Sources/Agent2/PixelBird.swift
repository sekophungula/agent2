import AppKit

/// The Agent2 mark: a pixel-art bird drawn from a grid, so the menu bar icon,
/// the app icon and the website logo all come from one source.
enum PixelBird {
    /// Each row lists inclusive [start, end] column runs of filled pixels.
    /// The bird faces left; the white wing line is the gap between runs.
    static let rows: [[(Int, Int)]] = [
        [(3, 7)],
        [(2, 8)],
        [(1, 3), (5, 9)],               // eye at column 4
        [(0, 9)],
        [(0, 0), (3, 10)],              // open beak
        [(4, 10)],
        [(4, 8)],
        [(3, 7), (9, 13)],
        [(3, 6), (8, 14)],
        [(3, 5), (7, 15)],
        [(3, 5), (7, 15)],
        [(3, 5), (7, 16)],
        [(3, 5), (7, 16)],
        [(4, 6), (8, 17)],
        [(4, 7), (9, 17)],
        [(5, 8), (10, 17)],
        [(5, 9), (12, 18)],
        [(6, 11), (13, 18)],
        [(7, 12), (16, 19)],
        [(8, 15), (18, 20)],
        [(9, 12), (14, 18), (20, 20)],
        [(9, 11), (14, 19), (21, 22)],
        [(9, 10), (15, 20), (22, 22)],
        [(7, 11), (16, 21)],
        [(6, 7), (11, 11), (17, 22)],
        [(5, 6), (18, 22)],
        [(19, 21)],
    ]
    static let columns = 23
    static var height: Int { rows.count }

    static let brandGreen = NSColor(srgbRed: 0x54 / 255, green: 0x8A / 255, blue: 0x47 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x0C / 255, green: 0x14 / 255, blue: 0x0A / 255, alpha: 1)

    static func draw(in rect: NSRect, color: NSColor) {
        let cell = min(rect.width / CGFloat(columns), rect.height / CGFloat(height))
        let w = cell * CGFloat(columns), h = cell * CGFloat(height)
        let ox = rect.minX + (rect.width - w) / 2
        let oy = rect.minY + (rect.height - h) / 2
        color.setFill()
        for (r, runs) in rows.enumerated() {
            let y = oy + h - CGFloat(r + 1) * cell
            for (a, b) in runs {
                NSRect(x: ox + CGFloat(a) * cell, y: y, width: CGFloat(b - a + 1) * cell, height: cell)
                    .integral.fill()
            }
        }
    }

    /// Template image for the menu bar (macOS tints it for light/dark).
    static func menuBarImage(height: CGFloat = 18) -> NSImage {
        let size = NSSize(width: height * CGFloat(columns) / CGFloat(self.height), height: height)
        let img = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.shouldAntialias = false
            draw(in: rect, color: .black)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// App icon: dark bird on a brand-green rounded square.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels)
        let inset = s * 0.1
        let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSGradient(starting: NSColor(srgbRed: 0x6A / 255, green: 0xA8 / 255, blue: 0x5B / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0x3F / 255, green: 0x6E / 255, blue: 0x35 / 255, alpha: 1))!
            .draw(in: path, angle: -90)
        NSGraphicsContext.current?.shouldAntialias = false
        draw(in: body.insetBy(dx: body.width * 0.17, dy: body.height * 0.15), color: ink)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// SVG for the website (one rect per run).
    static func svg(fill: String = "#0C140A") -> String {
        var rects = ""
        for (r, runs) in rows.enumerated() {
            for (a, b) in runs { rects += "<rect x=\"\(a)\" y=\"\(r)\" width=\"\(b - a + 1)\" height=\"1\"/>" }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(columns) \(height)\" shape-rendering=\"crispEdges\" fill=\"\(fill)\">\(rects)</svg>\n"
    }

    /// `Agent2 --export-assets <dir>` writes the iconset PNGs and logo SVG used by the build script and website.
    static func exportAssets(to dir: URL) throws {
        let fm = FileManager.default
        let iconset = dir.appendingPathComponent("Agent2.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let data = appIcon(pixels: base * scale).representation(using: .png, properties: [:])!
                try data.write(to: iconset.appendingPathComponent(name))
            }
        }
        try svg().write(to: dir.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
        try svg(fill: "#548A47").write(to: dir.appendingPathComponent("logo-green.svg"), atomically: true, encoding: .utf8)
        try appIcon(pixels: 512).representation(using: .png, properties: [:])!
            .write(to: dir.appendingPathComponent("icon-512.png"))
    }
}
