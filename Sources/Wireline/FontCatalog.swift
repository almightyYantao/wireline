import AppKit
import CoreText
import Observation

/// Installed font families, scanned once in the background at launch.
///
/// Enumerating every family and opening each one to test for fixed pitch takes
/// a noticeable moment; doing it lazily on the main thread made the first open
/// of Settings stutter. CoreText (unlike NSFontManager) is safe off the main
/// thread, so the scan runs on a utility task and Settings reads the result.
@MainActor
@Observable
final class FontCatalog {
    static let shared = FontCatalog()

    struct Family: Hashable, Sendable {
        let name: String
        /// Contains Nerd Font icon glyphs (so prompt / file icons render).
        let hasIcons: Bool
    }

    /// Monospaced families, icon-capable ones first.
    private(set) var mono: [Family] = []
    /// Every family, alphabetical (theme editor's UI font picker).
    private(set) var all: [String] = []
    private var scanning = false

    /// Kick off the background scan (idempotent).
    func warm() {
        guard mono.isEmpty, !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let result = Self.scan()
            await MainActor.run {
                self.mono = result.mono
                self.all = result.all
                self.scanning = false
            }
        }
    }

    /// The results, scanning synchronously if the warm-up hasn't finished yet.
    func monoFamilies() -> [Family] {
        if mono.isEmpty { let r = Self.scan(); mono = r.mono; all = r.all }
        return mono
    }

    func allFamilies() -> [String] {
        if all.isEmpty { let r = Self.scan(); mono = r.mono; all = r.all }
        return all
    }

    nonisolated private static func scan() -> (mono: [Family], all: [String]) {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var mono: [Family] = []
        for name in names {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            guard CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) else { continue }
            mono.append(Family(name: name, hasIcons: hasNerdIcons(font)))
        }
        // Icon-capable fonts first: they're what fancy prompts need.
        mono.sort { a, b in
            a.hasIcons != b.hasIcons ? a.hasIcons
                : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return (mono, names)
    }

    /// Nerd Fonts carry the Font Awesome range (U+F07B folder) and the
    /// Powerline/branch glyphs (U+E0A0). Plain "for Powerline" fonts have only
    /// the latter, which isn't enough for prompt icons.
    nonisolated private static func hasNerdIcons(_ font: CTFont) -> Bool {
        var chars: [UniChar] = [0xF07B, 0xE0A0]
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    }
}
