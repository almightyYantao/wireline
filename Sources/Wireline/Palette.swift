import SwiftUI
import Observation

/// The app-wide color palette. Defaults to Wireline's green-on-black, but when a
/// terminal color scheme is active it derives the whole chrome (background,
/// accent, text) from that scheme so the UI stays coordinated with the terminal.
@Observable
final class Palette: @unchecked Sendable {
    static let shared = Palette()

    /// Bumped whenever colors change, so the UI can force a full refresh.
    private(set) var version = 0

    var bg = Color(hex: 0x0A0E0A)
    var surface = Color(hex: 0x0F150F)
    var border = Color(hex: 0x1B241B)
    var accent = Color(hex: 0x35D07F)
    var accentBright = Color(hex: 0x5CF0A2)
    var textPrimary = Color(hex: 0xC8D3C8)
    var textDim = Color(hex: 0x63755F)
    var amber = Color(hex: 0xE3B341)
    var red = Color(hex: 0xF85149)
    var purple = Color(hex: 0xB084F0)
    var teal = Color(hex: 0x35D0C0)

    /// Recompute from a terminal theme (nil resets to the Wireline default).
    func update(from theme: TerminalTheme?) {
        guard let t = theme else {
            resetDefaults()
            version += 1
            return
        }
        let bgc = t.background, fg = t.foreground
        bg = rgb(bgc)
        textPrimary = rgb(fg)
        accent = rgb(t.cursor)
        accentBright = rgb(lighten(t.cursor, 0.25))
        surface = rgb(mix(bgc, fg, 0.10))
        border = rgb(mix(bgc, fg, 0.22))
        textDim = rgb(mix(fg, bgc, 0.45))
        amber = rgb(t.ansi[3])       // yellow
        red = rgb(t.ansi[1])         // red
        purple = rgb(t.ansi[5])      // magenta
        teal = rgb(t.ansi[6])        // cyan
        version += 1
    }

    private func resetDefaults() {
        bg = Color(hex: 0x0A0E0A); surface = Color(hex: 0x0F150F); border = Color(hex: 0x1B241B)
        accent = Color(hex: 0x35D07F); accentBright = Color(hex: 0x5CF0A2)
        textPrimary = Color(hex: 0xC8D3C8); textDim = Color(hex: 0x63755F)
        amber = Color(hex: 0xE3B341); red = Color(hex: 0xF85149)
        purple = Color(hex: 0xB084F0); teal = Color(hex: 0x35D0C0)
    }

    // MARK: helpers (rgb components are 0...1)
    private func rgb(_ c: [Double]) -> Color {
        Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
    }
    private func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
        [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
    }
    private func lighten(_ c: [Double], _ t: Double) -> [Double] {
        [min(1, c[0] + t), min(1, c[1] + t), min(1, c[2] + t)]
    }
}
