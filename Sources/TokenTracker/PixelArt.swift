import AppKit

struct PixelGlyph {
    let rows: [[Int]]

    // Claude: 8x8 sunburst
    static let claude = PixelGlyph(rows: [
        [0, 0, 0, 1, 1, 0, 0, 0],
        [0, 1, 0, 1, 1, 0, 1, 0],
        [0, 0, 1, 1, 1, 1, 0, 0],
        [1, 1, 1, 1, 1, 1, 1, 1],
        [1, 1, 1, 1, 1, 1, 1, 1],
        [0, 0, 1, 1, 1, 1, 0, 0],
        [0, 1, 0, 1, 1, 0, 1, 0],
        [0, 0, 0, 1, 1, 0, 0, 0],
    ])

    // Codex: 12x12 cloud with a ">_" prompt cut out
    static let codex = PixelGlyph(rows: [
        [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
        [0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0],
        [1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1],
        [1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1],
        [1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1],
        [1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1],
        [0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0],
    ])

    func draw(in rect: NSRect, color: NSColor) {
        let n = CGFloat(rows.count)
        let px = rect.width / n
        color.setFill()
        for (y, row) in rows.enumerated() {
            for (x, v) in row.enumerated() where v == 1 {
                let r = NSRect(x: rect.minX + CGFloat(x) * px,
                               y: rect.minY + rect.height - CGFloat(y + 1) * px,
                               width: px, height: px)
                NSBezierPath(rect: r).fill()
            }
        }
    }
}

enum StatusRenderer {
    static let claudeColor = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let codexColor = NSColor(calibratedRed: 0.31, green: 0.82, blue: 0.72, alpha: 1)

    static func image(claude: Double?, codex: Double?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)

        func label(_ p: Double?) -> NSAttributedString {
            let s = p.map { "\(Int($0.rounded()))%" } ?? "--"
            return NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
        }

        let cl = label(claude)
        let cx = label(codex)
        let glyph: CGFloat = 13
        let gapGlyphText: CGFloat = 4
        let gapGroups: CGFloat = 10
        let height: CGFloat = 17
        let width = glyph + gapGlyphText + ceil(cl.size().width)
            + gapGroups
            + glyph + gapGlyphText + ceil(cx.size().width) + 2

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            PixelGlyph.claude.draw(
                in: NSRect(x: x, y: (height - glyph) / 2, width: glyph, height: glyph),
                color: claudeColor)
            x += glyph + gapGlyphText
            cl.draw(at: NSPoint(x: x, y: (height - cl.size().height) / 2 + 0.5))
            x += ceil(cl.size().width) + gapGroups
            PixelGlyph.codex.draw(
                in: NSRect(x: x, y: (height - glyph) / 2, width: glyph, height: glyph),
                color: codexColor)
            x += glyph + gapGlyphText
            cx.draw(at: NSPoint(x: x, y: (height - cx.size().height) / 2 + 0.5))
            return true
        }
    }
}
