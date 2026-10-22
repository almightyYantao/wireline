import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WirelineCore

/// The Ghostty-style text config (`~/.config/wireline/config`), applied on top
/// of the GUI settings. A key present in the file wins and locks its control in
/// Settings; deleting the line unlocks it again (the last applied value stays).
/// Saved edits reload automatically; ⌘⇧, reloads by hand.
@Observable
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    let url = ConfigFile.defaultURL()
    /// Keys the file currently sets (their GUI controls are locked).
    private(set) var lockedKeys: Set<String> = []
    private(set) var issues: [ConfigFile.Issue] = []
    private(set) var loadedFiles: [URL] = []
    /// A short-lived message for the in-window toast.
    private(set) var toast: Toast?

    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private weak var store: HostStore?
    private var stamps: [String: Date] = [:]
    private var timer: Timer?

    func isLocked(_ key: String) -> Bool { lockedKeys.contains(key) }

    /// Hook up the stores the config writes into, load once, and start watching.
    func attach(_ store: HostStore) {
        guard self.store == nil else { return }
        self.store = store
        reload(announce: false)
        // Polling a handful of stat()s once a second is cheaper and more robust
        // than file-system events: it survives editors' atomic save-by-rename,
        // includes, and the directory not existing yet.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    func reload(announce: Bool = true) {
        let result = ConfigFile.load(url)
        loadedFiles = result.files
        // `files` already contains `url` once it exists, so de-duplicate — a
        // repeated key in `uniqueKeysWithValues` traps.
        stamps = Dictionary(([url] + result.files).map { ($0.path, Self.mtime($0)) },
                            uniquingKeysWith: { first, _ in first })
        var issues = result.issues
        var locked: Set<String> = []
        var keybinds: [ShortcutAction: KeyShortcut] = [:]

        for e in result.entries {
            if e.key == "keybind" {
                switch Self.parseKeybind(e.value) {
                case .success(let (action, shortcut)): keybinds[action] = shortcut
                case .failure(let err): issues.append(.init(source: e.source, line: e.line, message: err.message))
                }
                continue
            }
            guard let setting = Self.settings.first(where: { $0.key == e.key }) else {
                issues.append(.init(source: e.source, line: e.line, message: "unknown key `\(e.key)`"))
                continue
            }
            if let error = setting.apply(e.value, store) {
                issues.append(.init(source: e.source, line: e.line, message: "\(e.key): \(error)"))
            } else {
                locked.insert(e.key)
            }
        }
        KeyBindingStore.shared.setConfigOverrides(keybinds)
        if !keybinds.isEmpty { locked.insert("keybind") }
        lockedKeys = locked
        self.issues = issues

        guard announce else { return }
        let loc = Localizer.shared
        show(issues.isEmpty
             ? Toast(text: loc.t("已重新加载配置", "Configuration reloaded"), isError: false)
             : Toast(text: loc.t("配置有 \(issues.count) 处问题，详见设置", "\(issues.count) config issue(s) — see Settings"),
                     isError: true))
    }

    private func reloadIfChanged() {
        let paths = Set(stamps.keys).union([url.path])
        let changed = paths.contains { Self.mtime(URL(fileURLWithPath: $0)) != stamps[$0] }
        if changed { reload() }
    }

    /// The shared in-window toast, for other one-line confirmations too.
    func announce(_ text: String, isError: Bool = false) { show(Toast(text: text, isError: isError)) }

    private func show(_ t: Toast) {
        wlAnimate(Motion.banner) { toast = t }
        let id = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard self?.toast?.id == id else { return }
            wlAnimate(Motion.popOut) { self?.toast = nil }
        }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Open / template

    /// Open the file in the user's text editor, writing a commented template
    /// the first time.
    func openInEditor() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template().write(to: url, atomically: true, encoding: .utf8)
            reload(announce: false)
        }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Every key with its doc line, commented out and showing the current value.
    private func template() -> String {
        var out = """
        # Wireline configuration
        #
        # One `key = value` per line; `#` starts a comment. A key set here wins over
        # Settings (its control there is locked). Remove the line to hand it back.
        # Saving reloads automatically (⌘⇧, reloads by hand).
        # Pull in more files with:  config-file = ?~/.config/wireline/local
        # API keys are never read from this file — they stay in the Keychain.

        """
        var group = ""
        for s in Self.settings {
            if s.group != group {
                group = s.group
                out += "\n# --- \(group) ---\n"
            }
            out += "\n# \(s.doc)\n# \(s.key) = \(s.current(store))\n"
        }
        out += """

        # --- Keybindings ---

        # keybind = <mods>+<key>=<action>   mods: cmd shift opt ctrl
        # keys: a character, or left right up down return
        # Ghostty names work too: new_split:right, goto_split:left, toggle_split_zoom …
        # actions: \(ShortcutAction.allCases.map(\.configName).joined(separator: ", "))
        # keybind = cmd+shift+t=new_local_terminal

        """
        return out
    }

    // MARK: Keybinds

    private static func parseKeybind(_ value: String) -> Result<(ShortcutAction, KeyShortcut), KeybindError> {
        guard let kb = ConfigFile.keybind(value) else {
            return .failure(KeybindError("keybind: expected `mods+key=action`, e.g. cmd+shift+t=new_local_terminal"))
        }
        guard let action = ShortcutAction.allCases.first(where: { $0.configName == kb.action })
                ?? ShortcutAction.ghosttyAliases[kb.action] else {
            return .failure(KeybindError("keybind: unknown action `\(kb.action)`"))
        }
        let s = KeyShortcut(key: kb.key, command: kb.command, shift: kb.shift, option: kb.option, control: kb.control)
        guard s.hasModifier else { return .failure(KeybindError("keybind: needs cmd, ctrl or opt")) }
        return .success((action, s))
    }

    struct KeybindError: Error { let message: String; init(_ m: String) { message = m } }
}

extension ShortcutAction {
    /// Ghostty action names accepted as synonyms, so a Ghostty `keybind` line
    /// can be pasted as-is.
    static let ghosttyAliases: [String: ShortcutAction] = [
        "new_split:right": .splitRight, "new_split:down": .splitDown,
        "goto_split:left": .focusPaneLeft, "goto_split:right": .focusPaneRight,
        "goto_split:up": .focusPaneUp, "goto_split:down": .focusPaneDown,
        "goto_split:next": .focusNextPane, "goto_split:previous": .focusPrevPane,
        "equalize_splits": .equalizeSplits, "toggle_split_zoom": .toggleSplitZoom,
        "new_tab": .newLocalTerminal, "close_surface": .closeShell,
        "toggle_command_palette": .commandPalette,
        "jump_to_prompt:-1": .jumpToPreviousPrompt, "jump_to_prompt:1": .jumpToNextPrompt,
        "toggle_quick_terminal": .toggleQuickTerminal,
    ]

    /// snake_case spelling used by `keybind` lines: newLocalTerminal → new_local_terminal.
    var configName: String {
        rawValue.reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }
}

// MARK: - The settings table

extension ConfigStore {
    /// One config key: how to apply a value, and how to print the current one.
    struct Setting {
        let key: String
        let group: String
        let doc: String
        /// Apply the raw value; return an error message, or nil on success.
        /// An empty value resets to the default.
        let apply: (String, HostStore?) -> String?
        let current: (HostStore?) -> String
    }

    static let settings: [Setting] = {
        let ai = AIConfig.shared
        func flag(_ key: String, _ group: String, _ doc: String, default d: Bool,
                  get: @escaping (HostStore?) -> Bool, set: @escaping (HostStore?, Bool) -> Void) -> Setting {
            Setting(key: key, group: group, doc: doc, apply: { v, s in
                if v.isEmpty { set(s, d); return nil }
                guard let b = ConfigFile.bool(v) else { return "expected true or false" }
                set(s, b); return nil
            }, current: { String(get($0)) })
        }
        func number(_ key: String, _ group: String, _ doc: String, _ range: ClosedRange<Double>, default d: Double,
                    get: @escaping (HostStore?) -> Double, set: @escaping (HostStore?, Double) -> Void) -> Setting {
            Setting(key: key, group: group, doc: doc, apply: { v, s in
                if v.isEmpty { set(s, d); return nil }
                guard let n = ConfigFile.number(v, in: range) else {
                    return "expected a number in \(range.lowerBound.clean)…\(range.upperBound.clean)"
                }
                set(s, n); return nil
            }, current: { get($0).clean })
        }
        func text(_ key: String, _ group: String, _ doc: String, default d: String,
                  get: @escaping (HostStore?) -> String, set: @escaping (HostStore?, String) -> Void) -> Setting {
            Setting(key: key, group: group, doc: doc, apply: { v, s in set(s, v.isEmpty ? d : v); return nil },
                    current: { get($0) })
        }
        func choice<E: RawRepresentable & CaseIterable>(
            _ key: String, _ group: String, _ doc: String, _ type: E.Type, default d: E,
            get: @escaping (HostStore?) -> E, set: @escaping (HostStore?, E) -> Void
        ) -> Setting where E.RawValue == String {
            let names = E.allCases.map(\.rawValue)
            return Setting(key: key, group: group, doc: "\(doc) (\(names.joined(separator: " | ")))", apply: { v, s in
                if v.isEmpty { set(s, d); return nil }
                guard let e = E.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) else {
                    return "expected one of \(names.joined(separator: ", "))"
                }
                set(s, e); return nil
            }, current: { get($0).rawValue })
        }

        let t = "Terminal", a = "Appearance", g = "General", m = "AI"
        return [
            // Terminal
            text("font-family", t, "Terminal font family; empty = auto (Nerd Font)", default: "",
                 get: { $0?.terminalFontName ?? "" },
                 set: { s, v in s?.terminalFontName = v.isEmpty ? nil : v }),
            number("font-size", t, "Terminal font size in points", 6...72, default: 13,
                   get: { $0?.terminalFontSize ?? 13 }, set: { $0?.terminalFontSize = $1 }),
            choice("cursor-style", t, "Cursor shape", CursorShape.self, default: .block,
                   get: { $0?.terminalCursorShape ?? .block }, set: { $0?.terminalCursorShape = $1 }),
            flag("cursor-style-blink", t, "Blink the cursor", default: true,
                 get: { $0?.terminalCursorBlink ?? true }, set: { $0?.terminalCursorBlink = $1 }),
            number("window-padding-x", t, "Horizontal space around the terminal (points)", 0...80, default: 16,
                   get: { $0?.terminalPaddingX ?? 16 }, set: { $0?.terminalPaddingX = $1 }),
            number("window-padding-y", t, "Vertical space around the terminal (points)", 0...80, default: 10,
                   get: { $0?.terminalPaddingY ?? 10 }, set: { $0?.terminalPaddingY = $1 }),
            choice("terminal-engine", t, "Terminal renderer for new sessions", TerminalEngineKind.self,
                   default: .ghostty,
                   get: { $0?.terminalEngine ?? .ghostty }, set: { $0?.terminalEngine = $1 }),
            flag("gpu-rendering", t, "Render terminals on the GPU (Metal)", default: true,
                 get: { $0?.terminalGPU ?? true }, set: { $0?.terminalGPU = $1 }),
            flag("window-inherit-working-directory", t, "New tabs start in the focused local shell's directory",
                 default: true, get: { $0?.inheritWorkingDirectory ?? true }, set: { $0?.inheritWorkingDirectory = $1 }),
            number("notify-on-command-finish-after", t,
                   "Notify when a command that ran this many seconds finishes in the background", 1...86400, default: 10,
                   get: { $0?.notifyCommandAfter ?? 10 }, set: { $0?.notifyCommandAfter = $1 }),
            Setting(key: "quick-terminal-size", group: t,
                    doc: "Quick terminal height: a fraction (0.4) or a percentage (40%) of the screen",
                    apply: { v, s in
                        if v.isEmpty { s?.quickTerminalHeight = 0.4; return nil }
                        let pct = v.hasSuffix("%")
                        guard let n = Double(pct ? String(v.dropLast()) : v), n > 0 else {
                            return "expected e.g. 0.4 or 40%"
                        }
                        s?.quickTerminalHeight = min(max(pct ? n / 100 : n, 0.15), 1); return nil
                    }, current: { "\(Int((($0?.quickTerminalHeight ?? 0.4) * 100).rounded()))%" }),
            flag("quick-terminal-autohide", t, "Hide the quick terminal when it loses focus", default: true,
                 get: { $0?.quickTerminalAutohide ?? true }, set: { $0?.quickTerminalAutohide = $1 }),
            number("unfocused-split-opacity", t, "How visible unfocused split panes stay (1 = no dimming)",
                   0.15...1, default: 0.7,
                   get: { $0?.unfocusedSplitOpacity ?? 0.7 }, set: { $0?.unfocusedSplitOpacity = $1 }),
            flag("builtin-terminal", t, "Open sessions in Wireline's own terminal", default: true,
                 get: { $0?.useBuiltInTerminal ?? true }, set: { $0?.useBuiltInTerminal = $1 }),
            choice("external-terminal", t, "Terminal app used when builtin-terminal = false", ExternalTerminal.self,
                   default: .terminal,
                   get: { ExternalTerminal($0?.terminalApp ?? .terminal) }, set: { $0?.terminalApp = $1.app }),

            // Appearance
            Setting(key: "theme", group: a,
                    doc: "Theme name as in Settings → Theme, or light:<name>,dark:<name> to follow the system",
                    apply: { v, s in
                        guard let s else { return nil }
                        @MainActor func find(_ n: String) -> String? {
                            let n = n.trimmingCharacters(in: .whitespaces)
                            return s.allThemes.first { $0.name.lowercased() == n.lowercased() }?.name
                        }
                        if v.isEmpty {
                            s.themeForLight = nil; s.themeForDark = nil
                            s.selectedThemeName = AppTheme.builtIns.first?.name ?? s.selectedThemeName; return nil
                        }
                        if v.lowercased().contains("light:") || v.lowercased().contains("dark:") {
                            var light: String?, dark: String?
                            for part in v.split(separator: ",") {
                                let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
                                guard kv.count == 2 else { return "expected light:<name>,dark:<name>" }
                                switch kv[0].trimmingCharacters(in: .whitespaces).lowercased() {
                                case "light": light = kv[1]
                                case "dark": dark = kv[1]
                                default: return "expected light:<name>,dark:<name>"
                                }
                            }
                            guard let l = light.flatMap({ find($0) }) else { return "no light theme “\(light ?? "")”" }
                            guard let d = dark.flatMap({ find($0) }) else { return "no dark theme “\(dark ?? "")”" }
                            s.themeForLight = l; s.themeForDark = d; return nil
                        }
                        guard let t = find(v) else { return "no theme named “\(v)”" }
                        s.themeForLight = nil; s.themeForDark = nil
                        s.selectedThemeName = t; return nil
                    }, current: { s in
                        if let l = s?.themeForLight, let d = s?.themeForDark { return "light:\(l),dark:\(d)" }
                        return s?.selectedThemeName ?? ""
                    }),
            number("background-opacity", a, "Panel opacity over the wallpaper", 0.2...1, default: 1,
                   get: { $0?.terminalOpacity ?? 1 }, set: { $0?.terminalOpacity = $1 }),
            Setting(key: "background-image", group: a, doc: "Wallpaper image or video path; empty = none",
                    apply: { v, s in
                        if v.isEmpty { s?.terminalBgImagePath = nil; return nil }
                        let path = (v as NSString).expandingTildeInPath
                        guard FileManager.default.fileExists(atPath: path) else { return "file not found: \(v)" }
                        s?.terminalBgImagePath = path; return nil
                    }, current: { $0?.terminalBgImagePath ?? "" }),

            // General
            choice("language", g, "Interface language", AppLanguage.self, default: .system,
                   get: { _ in Localizer.shared.language }, set: { Localizer.shared.language = $1 }),
            flag("check-on-launch", g, "Probe every host when the app starts", default: true,
                 get: { $0?.autoCheckOnLaunch ?? true }, set: { $0?.autoCheckOnLaunch = $1 }),
            flag("background-monitor", g, "Re-check hosts in the background and notify on changes", default: false,
                 get: { $0?.backgroundMonitor ?? false }, set: { $0?.backgroundMonitor = $1 }),
            number("monitor-interval", g, "Seconds between background checks", 15...3600, default: 60,
                   get: { $0?.monitorInterval ?? 60 }, set: { $0?.monitorInterval = $1 }),

            // AI
            flag("ai-enabled", m, "Enable the AI assistant", default: false,
                 get: { _ in ai.enabled }, set: { ai.enabled = $1 }),
            choice("ai-provider", m, "AI backend", AIProvider.self, default: .relay,
                   get: { _ in ai.provider }, set: { ai.provider = $1 }),
            text("ai-base-url", m, "OpenAI-compatible /v1 endpoint (relay backend)", default: "",
                 get: { _ in ai.relayBaseURL }, set: { ai.relayBaseURL = $1 }),
            text("ai-model", m, "Main model (relay backend)", default: "",
                 get: { _ in ai.relayModel }, set: { ai.relayModel = $1 }),
            text("ai-model-fast", m, "Optional fast model (relay backend)", default: "",
                 get: { _ in ai.relayModelFast }, set: { ai.relayModelFast = $1 }),
            text("ai-ollama-url", m, "Ollama endpoint", default: "http://localhost:11434/v1",
                 get: { _ in ai.ollamaBaseURL }, set: { ai.ollamaBaseURL = $1 }),
            text("ai-ollama-model", m, "Ollama main model", default: "",
                 get: { _ in ai.ollamaModel }, set: { ai.ollamaModel = $1 }),
            text("ai-ollama-model-fast", m, "Ollama fast model", default: "",
                 get: { _ in ai.ollamaModelFast }, set: { ai.ollamaModelFast = $1 }),
            number("ai-font-size", m, "AI panel font size", 10...22, default: 13,
                   get: { _ in ai.fontSize }, set: { ai.fontSize = $1 }),
            number("ai-history-limit", m, "Messages kept per conversation", 10...500, default: 100,
                   get: { _ in Double(ai.historyLimit) }, set: { ai.historyLimit = Int($1) }),
            flag("ai-redact", m, "Mask passwords / tokens before sending to the model", default: true,
                 get: { _ in ai.redact }, set: { ai.redact = $1 }),
            flag("ai-agent-in-terminal", m, "Agent runs commands visibly in the terminal (false = out-of-band)",
                 default: true, get: { _ in ai.agentInTerminal }, set: { ai.agentInTerminal = $1 }),
            flag("ai-agent-read-only", m, "Agent may only run read-only commands", default: false,
                 get: { _ in ai.agentReadOnly }, set: { ai.agentReadOnly = $1 }),
        ]
    }()
}

/// `TerminalApp`'s raw values ("Terminal", "iTerm") are display-ish; the config
/// spells them lowercase.
enum ExternalTerminal: String, CaseIterable {
    case terminal, iterm
    init(_ app: TerminalApp) { self = app == .iterm ? .iterm : .terminal }
    var app: TerminalApp { self == .iterm ? .iterm : .terminal }
}

private extension Double {
    /// 13.0 → "13", 0.85 → "0.85".
    var clean: String {
        rounded() == self ? String(Int(self)) : String(format: "%g", self)
    }
}
