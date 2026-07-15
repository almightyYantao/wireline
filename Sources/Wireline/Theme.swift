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

    // Fonts (monospaced)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let title   = mono(17, .bold)
    static let body    = mono(13)
    static let small   = mono(11)
    static let caption = mono(10)
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
