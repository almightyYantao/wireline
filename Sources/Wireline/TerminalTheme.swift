import Foundation
import AppKit
import SwiftTerm

/// A terminal color scheme: 16 ANSI colors + background / foreground / cursor.
/// Compatible with iTerm2 `.itermcolors` files.
struct TerminalTheme: Codable, Sendable, Equatable {
    var name: String
    /// 16 ANSI colors, each [r, g, b] in 0...1.
    var ansi: [[Double]]
    var background: [Double]
    var foreground: [Double]
    var cursor: [Double]

    static func nsColor(_ c: [Double]) -> NSColor {
        let r = c.count > 0 ? c[0] : 0
        let g = c.count > 1 ? c[1] : 0
        let b = c.count > 2 ? c[2] : 0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func termColor(_ c: [Double]) -> SwiftTerm.Color {
        func u16(_ v: Double) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        return SwiftTerm.Color(red: u16(c[0]), green: u16(c[1]), blue: u16(c[2]))
    }

    var ansiTermColors: [SwiftTerm.Color] { ansi.map { Self.termColor($0) } }
    var backgroundNS: NSColor { Self.nsColor(background) }
    var foregroundNS: NSColor { Self.nsColor(foreground) }
    var cursorNS: NSColor { Self.nsColor(cursor) }

    /// Wireline's built-in green-on-black default.
    static let wireline = TerminalTheme(
        name: "Wireline",
        ansi: [
            [0.15, 0.16, 0.15], [0.97, 0.32, 0.32], [0.21, 0.82, 0.50], [0.89, 0.70, 0.25],
            [0.25, 0.51, 0.94], [0.69, 0.52, 0.94], [0.21, 0.82, 0.75], [0.78, 0.83, 0.78],
            [0.39, 0.45, 0.39], [0.98, 0.45, 0.45], [0.36, 0.90, 0.63], [0.95, 0.80, 0.40],
            [0.40, 0.62, 0.98], [0.79, 0.65, 0.98], [0.36, 0.90, 0.82], [0.92, 0.95, 0.92]
        ],
        background: [0.039, 0.055, 0.039],
        foreground: [0.78, 0.83, 0.78],
        cursor: [0.20, 0.82, 0.50]
    )

    // MARK: - Built-in presets

    private static func hex(_ v: UInt32) -> [Double] {
        [Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255]
    }

    private static func make(_ name: String, bg: UInt32, fg: UInt32, cur: UInt32,
                             _ a: [UInt32]) -> TerminalTheme {
        TerminalTheme(name: name, ansi: a.map(hex), background: hex(bg), foreground: hex(fg), cursor: hex(cur))
    }

    /// A handful of well-loved schemes, available without importing a file.
    static let presets: [TerminalTheme] = [
        // 猛男粉 — an unapologetically hot-pink scheme. Because the app derives its
        // whole chrome from the active terminal theme, selecting this turns the
        // entire UI pink (accent = the hot-pink cursor).
        make("猛男粉 / Hot Pink", bg: 0x1a0a12, fg: 0xffcce4, cur: 0xff2d95, [
            0x3a2030, 0xff4d6d, 0x5fe3a0, 0xffd166, 0x8ab6ff, 0xff5cc8, 0x64e0d6, 0xffd9ec,
            0x6b4658, 0xff7d9c, 0x86f0bf, 0xffe08a, 0xa9caff, 0xff8fda, 0x93f0e8, 0xfff0f8]),
        make("Dracula", bg: 0x282a36, fg: 0xf8f8f2, cur: 0xf8f8f0, [
            0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
            0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]),
        make("Nord", bg: 0x2e3440, fg: 0xd8dee9, cur: 0xd8dee9, [
            0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
            0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]),
        make("Solarized Dark", bg: 0x002b36, fg: 0x839496, cur: 0x93a1a1, [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]),
        make("Gruvbox Dark", bg: 0x282828, fg: 0xebdbb2, cur: 0xebdbb2, [
            0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
            0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2]),
        make("Tokyo Night", bg: 0x1a1b26, fg: 0xc0caf5, cur: 0xc0caf5, [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5]),
        make("One Dark", bg: 0x282c34, fg: 0xabb2bf, cur: 0x528bff, [
            0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
            0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff]),

        // Light schemes. The cursor doubles as the UI accent, so each uses a
        // saturated, dark-enough cursor to stay legible on a light background.
        make("Wireline Light", bg: 0xf6f7f3, fg: 0x24302a, cur: 0x15904f, [
            0x24302a, 0xd0353b, 0x15904f, 0xa86a00, 0x2f6fd6, 0x8a4fd0, 0x0f8a83, 0xb8c0b8,
            0x5b6a5f, 0xe5484d, 0x1fa860, 0xc58a14, 0x4a86e8, 0xa06ae0, 0x1aa39b, 0xeef0ea]),
        make("GitHub Light", bg: 0xffffff, fg: 0x1f2328, cur: 0x0969da, [
            0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
            0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f]),
        make("Solarized Light", bg: 0xfdf6e3, fg: 0x586e75, cur: 0x268bd2, [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]),
        make("One Light", bg: 0xfafafa, fg: 0x383a42, cur: 0x526fff, [
            0x383a42, 0xe45649, 0x50a14f, 0xc18401, 0x4078f2, 0xa626a4, 0x0184bc, 0xa0a1a7,
            0x4f525e, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff]),
        make("Catppuccin Latte", bg: 0xeff1f5, fg: 0x4c4f69, cur: 0x8839ef, [
            0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
            0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc]),
        make("Gruvbox Light", bg: 0xfbf1c7, fg: 0x3c3836, cur: 0x076678, [
            0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
            0x928374, 0x9d0006, 0x79740e, 0xb57614, 0x076678, 0x8f3f71, 0x427b58, 0x3c3836]),
    ]
}

/// Parses an iTerm2 `.itermcolors` plist into a `TerminalTheme`.
enum ITermColorParser {
    static func parse(url: URL) -> TerminalTheme? {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }

        func comps(_ key: String) -> [Double]? {
            guard let d = dict[key] as? [String: Any] else { return nil }
            let r = (d["Red Component"] as? NSNumber)?.doubleValue
            let g = (d["Green Component"] as? NSNumber)?.doubleValue
            let b = (d["Blue Component"] as? NSNumber)?.doubleValue
            guard let r, let g, let b else { return nil }
            return [r, g, b]
        }

        var ansi: [[Double]] = []
        for i in 0..<16 {
            guard let c = comps("Ansi \(i) Color") else { return nil }
            ansi.append(c)
        }
        let bg = comps("Background Color") ?? [0, 0, 0]
        let fg = comps("Foreground Color") ?? [1, 1, 1]
        let cursor = comps("Cursor Color") ?? fg

        let name = url.deletingPathExtension().lastPathComponent
        return TerminalTheme(name: name, ansi: ansi, background: bg, foreground: fg, cursor: cursor)
    }
}
