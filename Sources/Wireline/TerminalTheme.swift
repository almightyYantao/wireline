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

    fileprivate static func make(_ name: String, bg: UInt32, fg: UInt32, cur: UInt32,
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

// MARK: - macOS Native

extension TerminalTheme {
    /// Apple's system palette (window background, label color, NSColor.system*)
    /// for one appearance. `accent` is the user's system accent color; nil falls
    /// back to system blue.
    static func macOSNative(dark: Bool, accent: [Double]?) -> TerminalTheme {
        if dark {
            return TerminalTheme(name: "macOS Native (Dark)", ansi: [
                0x3a3a3c, 0xff453a, 0x32d74b, 0xffd60a, 0x0a84ff, 0xbf5af2, 0x64d2ff, 0xd1d1d6,
                0x636366, 0xff6961, 0x5de072, 0xffe04d, 0x409cff, 0xda8fff, 0x8fe0ff, 0xf2f2f7,
            ].map(hex), background: hex(0x1e1e1e), foreground: hex(0xdfdfdf),
                cursor: accent ?? hex(0x0a84ff))
        }
        return TerminalTheme(name: "macOS Native (Light)", ansi: [
            0x1d1d1f, 0xd70015, 0x248a3d, 0xa05a00, 0x0040dd, 0x8944ab, 0x0071a4, 0xaeaeb2,
            0x636366, 0xff3b30, 0x28cd41, 0xc93400, 0x007aff, 0xaf52de, 0x0095cc, 0xe5e5ea,
        ].map(hex), background: hex(0xffffff), foreground: hex(0x1d1d1f),
            cursor: accent ?? hex(0x007aff))
    }
}

// MARK: - Design-style skins

extension TerminalTheme {
    /// A design style's colors plus the shape / type it implies (see
    /// `AppTheme.styled`). The cursor is the UI accent.
    struct Styled {
        let colors: TerminalTheme
        var radius = 1.0
        var border = 1.0
        var density: AppTheme.Shape.Density = .normal
        var design: AppTheme.Typography.Design = .monospaced
        var chrome = 1.0
    }

    static let styled: [Styled] = [
        // Black outlines, square corners, loud accent (#ff006e) on white.
        Styled(colors: make("新野兽派 / Neo-Brutalist", bg: 0xffffff, fg: 0x000000, cur: 0xff006e, [
            0x000000, 0xd6004f, 0x3f8a00, 0xb36200, 0x0068b3, 0xff006e, 0x00869e, 0xd1d5db,
            0x374151, 0xff2d55, 0x5c9900, 0xff9500, 0x0091d9, 0xe0007a, 0x00a8c7, 0xf3f4f6]),
               radius: 0, border: 2.5, design: .monospaced),
        // Print magazine: warm paper, ink black, editorial red, serif type.
        Styled(colors: make("编辑杂志 / Editorial", bg: 0xfaf7f0, fg: 0x1c1b19, cur: 0xb3261e, [
            0x1c1b19, 0xb3261e, 0x3d6b35, 0x9a6a12, 0x2b4f81, 0x7d3c6b, 0x2f6f73, 0xc9c2b4,
            0x5c574d, 0xd23a2f, 0x548a4a, 0xbf8a2a, 0x3f6aa8, 0x9e5389, 0x3f8f94, 0xefe9dd]),
               radius: 0.4, density: .relaxed, design: .serif),
        // Soft extruded surfaces on one cool grey; no hard borders.
        Styled(colors: make("新拟物 / Neumorphism", bg: 0xe6e9ef, fg: 0x3d4451, cur: 0x5b7cfa, [
            0x3d4451, 0xd9534f, 0x3e9b6b, 0xb07d1a, 0x4f6fe0, 0x9b5fcf, 0x2f8f9d, 0xc3c8d2,
            0x6b7385, 0xe86f6b, 0x55b585, 0xcc9733, 0x6d8af0, 0xb27ce0, 0x48a8b5, 0xf2f4f8]),
               radius: 1.6, border: 0, density: .relaxed, design: .rounded),
        // Trustworthy and plain: white, slate text, corporate blue.
        Styled(colors: make("企业简洁 / Corporate Clean", bg: 0xffffff, fg: 0x1f2937, cur: 0x2563eb, [
            0x1f2937, 0xdc2626, 0x15803d, 0xb45309, 0x2563eb, 0x7c3aed, 0x0e7490, 0xd1d5db,
            0x4b5563, 0xef4444, 0x16a34a, 0xd97706, 0x3b82f6, 0x8b5cf6, 0x0891b2, 0xf3f4f6]),
               radius: 0.8, design: .standard),
        // No shadows, no borders: colour and space only.
        Styled(colors: make("极简扁平 / Minimalist Flat", bg: 0xf5f5f5, fg: 0x222222, cur: 0x2d9cdb, [
            0x222222, 0xe74c3c, 0x27ae60, 0xd68910, 0x2d9cdb, 0x8e44ad, 0x16a085, 0xcccccc,
            0x666666, 0xff6b5b, 0x2ecc71, 0xf39c12, 0x56b4e9, 0xa569bd, 0x1abc9c, 0xeeeeee]),
               radius: 0.5, border: 0, design: .standard),
        // Friendly lavender-grey, low saturation, rounded everything.
        Styled(colors: make("柔和界面 / Soft UI", bg: 0xf7f5fb, fg: 0x4a4458, cur: 0x8b7cf6, [
            0x4a4458, 0xe06c88, 0x4fa88a, 0xc4913a, 0x6f8fe8, 0x8b7cf6, 0x4aa3b5, 0xd6d1e0,
            0x7a7389, 0xef8aa2, 0x6cc2a3, 0xdcae5c, 0x8eaaf2, 0xa89bfa, 0x6bbccc, 0xf1eef7]),
               radius: 1.6, border: 0.5, density: .relaxed, design: .rounded),
        // Earth tones: linen, bark, moss.
        Styled(colors: make("自然有机 / Natural Organic", bg: 0xf3ede2, fg: 0x3e3a2f, cur: 0x6b8e4e, [
            0x3e3a2f, 0xb5523b, 0x6b8e4e, 0xa77b2c, 0x4f7385, 0x8c5e7a, 0x4e8a7b, 0xcfc5b3,
            0x6e6655, 0xcc6a50, 0x84a865, 0xc29545, 0x6a8f9f, 0xa67894, 0x67a494, 0xebe4d6]),
               radius: 1.4, density: .relaxed, design: .rounded),
        // Deep indigo night lit by violet / pink / cyan, slightly glassy.
        Styled(colors: make("现代渐变 / Modern Gradient", bg: 0x14112b, fg: 0xe8e6ff, cur: 0xc084fc, [
            0x221d45, 0xff5c93, 0x4ade80, 0xfbbf24, 0x60a5fa, 0xc084fc, 0x22d3ee, 0xd8d4f5,
            0x4b4578, 0xff85ad, 0x86efac, 0xfcd34d, 0x93c5fd, 0xd8b4fe, 0x67e8f9, 0xffffff]),
               radius: 1.4, design: .rounded, chrome: 0.88),
        // Sepia print shop: brown ink, mustard, serif.
        Styled(colors: make("复古怀旧 / Retro Vintage", bg: 0x2b2118, fg: 0xf0dfc0, cur: 0xe0a040, [
            0x3b2e22, 0xd0603e, 0x9aa55a, 0xe0a040, 0x6f93a6, 0xb5768a, 0x7fa89a, 0xe0cfae,
            0x6b5a45, 0xe57b57, 0xb5bf75, 0xf0bd5f, 0x8eadbf, 0xcc90a3, 0x9cc2b4, 0xfaefd8]),
               radius: 0.6, border: 1.5, design: .serif),
        // Neutral dark layers, soft blue highlight.
        Styled(colors: make("暗黑模式 / Dark Mode", bg: 0x121212, fg: 0xe4e4e7, cur: 0x8ab4f8, [
            0x27272a, 0xf28b82, 0x81c995, 0xfdd663, 0x8ab4f8, 0xc58af9, 0x78d9ec, 0xd4d4d8,
            0x52525b, 0xf6aea9, 0xa8dab5, 0xfde293, 0xaecbfa, 0xd7aefb, 0xa1e4f2, 0xfafafa]),
               design: .standard),
        // Stacked dark-grey panels over the desktop, system blue.
        Styled(colors: make("macOS 毛玻璃 / macOS Vibrancy", bg: 0x1e1e20, fg: 0xdcdcdc, cur: 0x0a84ff, [
            0x2c2c2e, 0xff453a, 0x32d74b, 0xffd60a, 0x0a84ff, 0xbf5af2, 0x64d2ff, 0xd1d1d6,
            0x636366, 0xff6961, 0x5de072, 0xffe04d, 0x409cff, 0xda8fff, 0x8fe0ff, 0xf2f2f7]),
               radius: 1.1, border: 0.5, design: .standard, chrome: 0.8),
        // Solid blocks, hard contrast, electric yellow on near-black.
        Styled(colors: make("几何大胆 / Geometric Bold", bg: 0x101820, fg: 0xfefefe, cur: 0xfee715, [
            0x1d2a36, 0xff3b3b, 0x00e08a, 0xfee715, 0x2f7dff, 0xff2e93, 0x00d5e0, 0xdadfe5,
            0x4a5866, 0xff6b6b, 0x4dffb2, 0xfff15c, 0x6aa3ff, 0xff6ab4, 0x4deaf2, 0xffffff]),
               radius: 0, border: 2, design: .standard),
        // Puffy clay: pastel lilac, very round, rounded type.
        Styled(colors: make("粘土拟态 / Claymorphism", bg: 0xf2ecff, fg: 0x3b2f5c, cur: 0xff7aa8, [
            0x3b2f5c, 0xe5527a, 0x3fa77a, 0xc98a1e, 0x5b7cf0, 0xa35ee8, 0x2c9fb0, 0xd9cff0,
            0x6e6390, 0xff7aa8, 0x5cc495, 0xe8a83d, 0x7d9af5, 0xbc85f0, 0x4dbccc, 0xfaf7ff]),
               radius: 2, border: 0, density: .relaxed, design: .rounded),
        // Document tool: off-black on white, quiet borders, link blue.
        Styled(colors: make("Notion 风格 / Notion", bg: 0xffffff, fg: 0x37352f, cur: 0x2383e2, [
            0x37352f, 0xe03e3e, 0x0f7b6c, 0xd9730d, 0x0b6e99, 0x6940a5, 0x0f7b8a, 0xd3d1cb,
            0x787774, 0xeb5757, 0x2a9d8f, 0xf2994a, 0x2383e2, 0x9065b0, 0x2ab0c0, 0xf1f1ef]),
               radius: 0.6, design: .standard),
        // Fintech polish: navy text, Stripe purple (#635bff), cyan accent.
        Styled(colors: make("Stripe 风格 / Stripe", bg: 0xf6f9fc, fg: 0x0a2540, cur: 0x635bff, [
            0x0a2540, 0xdf1b41, 0x0e8a4f, 0xb76e00, 0x635bff, 0x9f3ad6, 0x0a8fb3, 0xcbd5e1,
            0x425466, 0xff5a5f, 0x1fb57a, 0xe69a1a, 0x7a73ff, 0xb86ee6, 0x00b3e6, 0xeef2f7]),
               radius: 1.2, design: .standard),
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
