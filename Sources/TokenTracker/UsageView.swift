import SwiftUI
import AppKit

enum Theme {
    static let bg = Color(red: 0.07, green: 0.08, blue: 0.11)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.47, green: 0.47, blue: 0.95)
    static let text = Color.white.opacity(0.92)
    static let sub = Color.white.opacity(0.45)
    static let grid = Color.white.opacity(0.10)

    // Keyed on remaining %: plenty left = green, running low = yellow, nearly out = red.
    static func severity(remaining: Double) -> Color {
        if remaining <= 15 { return Color(red: 1.00, green: 0.42, blue: 0.42) }
        if remaining <= 40 { return Color(red: 0.95, green: 0.80, blue: 0.38) }
        return Color(red: 0.49, green: 0.91, blue: 0.53)
    }
}

struct PixelGlyphView: View {
    let glyph: PixelGlyph
    let color: Color
    let pixel: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<glyph.rows.count, id: \.self) { y in
                HStack(spacing: 0) {
                    ForEach(0..<glyph.rows[y].count, id: \.self) { x in
                        Rectangle()
                            .fill(glyph.rows[y][x] == 1 ? color : Color.clear)
                            .frame(width: pixel, height: pixel)
                    }
                }
            }
        }
    }
}

struct PixelBar: View {
    let remaining: Double
    let active: Bool
    private let segments = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle()
                    .fill(color(i))
                    .frame(width: 9, height: 12)
            }
        }
    }

    private func color(_ i: Int) -> Color {
        guard active else { return Theme.grid }
        var filled = Int((remaining / 100 * Double(segments)).rounded())
        if remaining > 0 { filled = max(filled, 1) }
        return i < filled ? Theme.severity(remaining: remaining) : Theme.grid
    }
}

struct BarRow: View {
    let label: String
    let window: WindowUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.sub)
                    .frame(width: 20, alignment: .leading)
                PixelBar(remaining: window?.remaining ?? 0, active: window != nil)
                Text(percentText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(window.map { Theme.severity(remaining: $0.remaining) } ?? Theme.sub)
                    .frame(width: 42, alignment: .trailing)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.sub)
                    .padding(.leading, 28)
            }
        }
    }

    private var percentText: String {
        window.map { "\(Int($0.remaining.rounded()))%" } ?? "--"
    }

    private var caption: String? {
        guard let window else { return nil }
        if let r = window.resetsAt { return Dates.resetLabel(r) }
        return window.percent == 0 ? "WINDOW RESET" : nil
    }
}

struct ServiceSection: View {
    let name: String
    let accent: Color
    let glyph: PixelGlyph
    let usage: ServiceUsage

    private func staleText(_ note: String) -> String {
        guard let asOf = usage.asOf else { return note }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(note) · AS OF \(f.string(from: asOf))".uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                PixelGlyphView(glyph: glyph, color: accent, pixel: 20 / CGFloat(glyph.rows.count))
                Text(name)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .kerning(2)
                    .foregroundColor(Theme.text)
                Spacer()
                if let plan = usage.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(accent)
                }
            }
            if let err = usage.error {
                Text(err)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.sub)
                    .padding(.leading, 2)
            } else {
                BarRow(label: "5H", window: usage.session)
                BarRow(label: "7D", window: usage.weekly)
                if let note = usage.staleNote {
                    Text(staleText(note))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.claude.opacity(0.8))
                        .padding(.leading, 2)
                }
            }
        }
    }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ServiceSection(name: "CLAUDE", accent: Theme.claude,
                           glyph: .claude, usage: store.claude)
            Rectangle().fill(Theme.grid).frame(height: 2)
            ServiceSection(name: "CODEX", accent: Theme.codex,
                           glyph: .codex, usage: store.codex)
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.bg)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(updatedText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.sub)
            Spacer()
            Button(action: { store.refreshAll(forceClaude: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.sub)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.sub)
            }
            .buttonStyle(.plain)
            .help("Quit Token Tracker")
        }
        .padding(.top, 2)
    }

    private var updatedText: String {
        guard let d = store.lastUpdated else { return "LOADING..." }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "% LEFT · UPDATED \(f.string(from: d))".uppercased()
    }
}
