import SwiftUI

/// A complete "skin": colors + shape + typography + background. This is the unit
/// users create, rename, save, import and export — an `AppTheme` encoded as JSON
/// *is* the shareable theme file. Colors reuse `TerminalTheme` so the same scheme
/// drives both the terminal and the app chrome.
struct AppTheme: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var colors: TerminalTheme
    var shape: Shape = .init()
    var type: Typography = .init()
    var background: Background = .init()

    /// Built-in themes are read-only; custom ones can be edited/deleted.
    var isBuiltIn: Bool = false

    // MARK: - Shape / density

    struct Shape: Codable, Equatable {
        /// Multiplies every corner radius. 0 = square, 1 = stock, 2 = very round.
        var radiusScale: Double = 1.0
        /// Border thickness in points.
        var borderWidth: Double = 1.0
        /// Controls padding/spacing throughout.
        var density: Density = .normal

        enum Density: String, Codable, CaseIterable, Identifiable {
            case compact, normal, relaxed
            var id: String { rawValue }
            /// Multiplier applied to base paddings.
            var pad: Double {
                switch self {
                case .compact: return 0.8
                case .normal:  return 1.0
                case .relaxed: return 1.25
                }
            }
            var label: (String, String) {
                switch self {
                case .compact: return ("紧凑", "Compact")
                case .normal:  return ("正常", "Normal")
                case .relaxed: return ("宽松", "Relaxed")
                }
            }
        }
    }

    // MARK: - Typography

    struct Typography: Codable, Equatable {
        /// Built-in font design (used when `fontName` is nil).
        var design: Design = .monospaced
        /// An explicit font family name; overrides `design` when set.
        var fontName: String? = nil
        /// Multiplies every font size.
        var sizeScale: Double = 1.0

        enum Design: String, Codable, CaseIterable, Identifiable {
            case monospaced, rounded, standard, serif
            var id: String { rawValue }
            var swiftUI: Font.Design {
                switch self {
                case .monospaced: return .monospaced
                case .rounded:    return .rounded
                case .standard:   return .default
                case .serif:      return .serif
                }
            }
            var label: (String, String) {
                switch self {
                case .monospaced: return ("等宽", "Monospaced")
                case .rounded:    return ("圆体", "Rounded")
                case .standard:   return ("默认", "System")
                case .serif:      return ("衬线", "Serif")
                }
            }
        }
    }

    // MARK: - Background

    struct Background: Codable, Equatable {
        /// Path to a wallpaper image (drives the app-wide `WallpaperView`).
        var imagePath: String? = nil
        /// Overall chrome opacity (0.2…1.0) — lets the wallpaper show through panels.
        var chromeOpacity: Double = 1.0
    }

    // MARK: - Derived

    /// True when the colors are the built-in green-on-black default (so the
    /// terminal path can be left at `nil`, its native default).
    var usesDefaultColors: Bool { colors == .wireline }
}

// MARK: - Built-in library

extension AppTheme {
    /// The green-on-black original.
    static let wirelineDefault = AppTheme(
        name: "Wireline",
        colors: .wireline,
        isBuiltIn: true
    )

    /// Built-ins = the default + every bundled terminal color scheme, each with
    /// stock shape/typography so they read as pure recolors.
    static var builtIns: [AppTheme] {
        [wirelineDefault] + TerminalTheme.presets.map {
            AppTheme(name: $0.name, colors: $0, isBuiltIn: true)
        }
    }
}

// MARK: - Shareable theme pack

/// A self-contained, shareable skin bundle: the theme plus its wallpaper bytes
/// embedded, so it imports cleanly on someone else's machine (a bare file would
/// only carry a local wallpaper *path*, which breaks off the original device).
struct ThemePack: Codable {
    var format: String = "wireline-theme/1"
    var theme: AppTheme
    /// Embedded wallpaper image bytes (nil if the theme has no wallpaper).
    var wallpaper: Data? = nil
    /// Wallpaper file extension, e.g. "png"/"jpg".
    var wallpaperExt: String? = nil
}

/// Where imported wallpapers are materialized so their paths stay valid.
enum ThemeStorage {
    /// ~/Library/Application Support/Wireline/Themes
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Wireline/Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - Simple color derivation

extension TerminalTheme {
    /// Build a full 16-color scheme from just three picks (background, foreground,
    /// accent). ANSI colors follow canonical hues nudged for legibility, so the
    /// "simple" editor stays foolproof while advanced users can still tweak all 16.
    static func derived(name: String, bg: [Double], fg: [Double], accent: [Double]) -> TerminalTheme {
        func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
            zip(a, b).map { $0 + ($1 - $0) * t }
        }
        func lighten(_ c: [Double], _ t: Double) -> [Double] { c.map { min(1, $0 + t) } }

        let normal: [[Double]] = [
            mix(bg, fg, 0.18),        // 0 black  (bg-ish)
            [0.86, 0.30, 0.30],       // 1 red
            [0.30, 0.74, 0.44],       // 2 green
            [0.85, 0.68, 0.30],       // 3 yellow
            [0.34, 0.56, 0.92],       // 4 blue
            [0.72, 0.52, 0.92],       // 5 magenta
            [0.30, 0.80, 0.74],       // 6 cyan
            fg,                       // 7 white  (fg)
        ]
        let bright = normal.map { lighten($0, 0.16) }
        return TerminalTheme(name: name, ansi: normal + bright,
                             background: bg, foreground: fg, cursor: accent)
    }
}
