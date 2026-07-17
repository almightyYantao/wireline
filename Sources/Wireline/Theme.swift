import SwiftUI
import WirelineCore

/// The terminal / "hacker console" visual language: monospace everywhere,
/// green-on-black, bracketed status tags.
enum WL {
    // Palette — derived from the active terminal theme (see `Palette`).
    static var bg: Color          { Palette.shared.bg }
    static var surface: Color     { Palette.shared.surface }
    static var border: Color      { Palette.shared.border }
    static var green: Color       { Palette.shared.accent }
    static var greenBright: Color { Palette.shared.accentBright }
    static var textPrimary: Color { Palette.shared.textPrimary }
    static var textDim: Color     { Palette.shared.textDim }
    static var amber: Color       { Palette.shared.amber }
    static var red: Color         { Palette.shared.red }
    static var purple: Color      { Palette.shared.purple }
    static var teal: Color        { Palette.shared.teal }

    // Shape / density — driven by the active theme (see `Palette`).
    /// A corner radius scaled by the theme (base defaults to the stock 6pt).
    static func radius(_ base: CGFloat = 6) -> CGFloat {
        max(0, base * Palette.shared.radiusScale)
    }
    /// Border thickness for the current theme.
    static var borderWidth: CGFloat { Palette.shared.borderWidth }
    /// A padding scaled by the theme's density.
    static func pad(_ base: CGFloat) -> CGFloat { base * Palette.shared.densityPad }
    /// Theme-level chrome opacity multiplier (lets a wallpaper show through panels).
    static var chromeOpacity: Double { Palette.shared.chromeOpacity }

    // Fonts — historically monospaced, now the theme's UI font. The name stays
    // `mono` so the ~300 call sites keep working; selecting a non-mono design or
    // a custom family re-skins the whole UI through this one accessor.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let s = size * Palette.shared.fontScale
        if let name = Palette.shared.fontName, !name.isEmpty {
            return .custom(name, fixedSize: s).weight(weight)
        }
        return .system(size: s, weight: weight, design: Palette.shared.fontDesign)
    }
    // Computed (not stored) so they track live theme changes.
    static var title:   Font { mono(17, .bold) }
    static var body:    Font { mono(13) }
    static var small:   Font { mono(11) }
    static var caption: Font { mono(10) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension HostStatus {
    /// Bracketed status tag text, e.g. "已连接".
    var tagText: String {
        switch self {
        case .online: return "在线"
        case .offline: return "离线"
        case .checking: return "探测中"
        case .unknown: return "未知"
        }
    }
    var tagColor: Color {
        switch self {
        case .online: return WL.green
        case .offline: return WL.amber
        case .checking: return WL.teal
        case .unknown: return WL.textDim
        }
    }
}
