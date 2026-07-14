import SwiftUI
import WirelineCore

/// The terminal / "hacker console" visual language: monospace everywhere,
/// green-on-black, bracketed status tags.
enum WL {
    // Palette
    static let bg          = Color(hex: 0x0A0E0A)
    static let surface     = Color(hex: 0x0F150F)   // selected/raised rows
    static let border      = Color(hex: 0x1B241B)
    static let green       = Color(hex: 0x35D07F)   // primary accent
    static let greenBright = Color(hex: 0x5CF0A2)
    static let textPrimary = Color(hex: 0xC8D3C8)
    static let textDim     = Color(hex: 0x63755F)
    static let amber       = Color(hex: 0xE3B341)
    static let red         = Color(hex: 0xF85149)
    static let purple      = Color(hex: 0xB084F0)
    static let teal        = Color(hex: 0x35D0C0)

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
