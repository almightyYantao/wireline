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
