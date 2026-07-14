import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Sendable {
    case system, zh, en
    var displayName: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// Lightweight runtime localization with a system default and a user override.
/// Views read `loc.t("中文", "English")` and re-render when the language changes.
@Observable
@MainActor
final class Localizer {
    static let shared = Localizer()

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        self.language = saved.flatMap(AppLanguage.init) ?? .system
    }

    var isChinese: Bool {
        switch language {
        case .zh: return true
        case .en: return false
        case .system:
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }

    /// Pick the Chinese or English string for the current language.
    func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

    /// Convenience callable form: `loc("中文", "English")`.
    func callAsFunction(_ zh: String, _ en: String) -> String { t(zh, en) }
}
