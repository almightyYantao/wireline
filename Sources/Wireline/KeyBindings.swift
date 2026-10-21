import SwiftUI
import AppKit
import Observation

/// A single customizable keyboard shortcut: one key plus modifier flags.
struct KeyShortcut: Codable, Equatable {
    /// The base key, stored lowercased (e.g. "t", "k", "1").
    var key: String
    var command: Bool = true
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    /// At least one modifier is required so a binding can never swallow plain typing.
    var hasModifier: Bool { command || control || option }

    /// Non-character keys, stored by name (as written in the config file).
    static let namedKeys: [String: (glyph: String, equivalent: KeyEquivalent, keyCode: UInt16)] = [
        "left": ("←", .leftArrow, 123), "right": ("→", .rightArrow, 124),
        "down": ("↓", .downArrow, 125), "up": ("↑", .upArrow, 126),
        "return": ("↩", .return, 36),
    ]

    /// Human-readable badge, e.g. "⇧⌘T".
    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += Self.namedKeys[key]?.glyph ?? key.uppercased()
        return s
    }

    // SwiftUI menu bridging ------------------------------------------------
    var keyEquivalent: KeyEquivalent {
        Self.namedKeys[key]?.equivalent ?? KeyEquivalent(Character(key.isEmpty ? " " : key))
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// Does an AppKit key event match this shortcut? Used by the terminal view.
    func matches(_ event: NSEvent) -> Bool {
        if let named = Self.namedKeys[key] {
            guard event.keyCode == named.keyCode else { return false }
        } else {
            guard event.charactersIgnoringModifiers?.lowercased() == key else { return false }
        }
        let f = event.modifierFlags
        return f.contains(.command) == command
            && f.contains(.shift) == shift
            && f.contains(.option) == option
            && f.contains(.control) == control
    }

    /// Build from a captured AppKit key-down event (nil if it has no usable key).
    static func from(event: NSEvent) -> KeyShortcut? {
        let f0 = event.modifierFlags
        if let name = namedKeys.first(where: { $0.value.keyCode == event.keyCode })?.key {
            return KeyShortcut(key: name, command: f0.contains(.command), shift: f0.contains(.shift),
                               option: f0.contains(.option), control: f0.contains(.control))
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let first = chars.first, first.isLetter || first.isNumber || "`-=[]\\;',./".contains(first)
        else { return nil }
        let f = event.modifierFlags
        return KeyShortcut(key: String(first),
                           command: f.contains(.command),
                           shift: f.contains(.shift),
                           option: f.contains(.option),
                           control: f.contains(.control))
    }
}

extension View {
    /// Apply the user's current shortcut for `action` to this menu button.
    func shortcut(_ action: ShortcutAction, _ keys: KeyBindingStore) -> some View {
        let s = keys.shortcut(for: action)
        return keyboardShortcut(s.keyEquivalent, modifiers: s.eventModifiers)
    }
}

/// Every user-remappable action in the app.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newConnection
    case newLocalTerminal
    case quickConnect
    case refreshStatuses
    case find
    case toggleSidebar
    case toggleAI
    case suggestCommand
    case editHost
    case closeShell
    case showTodos
    case focusTerminal
    case focusNextPane
    case focusPrevPane
    case commandPalette
    case showPet
    case splitRight
    case splitDown
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case equalizeSplits
    case toggleSplitZoom
    case jumpToPreviousPrompt
    case jumpToNextPrompt
    case copyLastOutput
    case toggleQuickTerminal

    var id: String { rawValue }

    @MainActor
    func name(_ loc: Localizer) -> String {
        switch self {
        case .newConnection:    return loc.t("新建连接", "New Connection")
        case .newLocalTerminal: return loc.t("新建本地终端", "New Local Terminal")
        case .quickConnect:     return loc.t("快速连接", "Quick Connect")
        case .refreshStatuses:  return loc.t("刷新状态", "Refresh Statuses")
        case .find:             return loc.t("搜索连接", "Find")
        case .toggleSidebar:    return loc.t("折叠 / 展开侧栏", "Toggle Sidebar")
        case .toggleAI:         return loc.t("显示 / 收起 AI 面板", "Toggle AI Panel")
        case .suggestCommand:   return loc.t("AI 建议下一条命令", "Suggest Next Command")
        case .editHost:         return loc.t("编辑当前主机", "Edit Host")
        case .closeShell:       return loc.t("关闭当前 Shell", "Close Current Shell")
        case .showTodos:        return loc.t("待办清单", "To-Do List")
        case .focusTerminal:    return loc.t("聚焦终端输入", "Focus Terminal")
        case .focusNextPane:    return loc.t("下一个分屏", "Focus Next Pane")
        case .focusPrevPane:    return loc.t("上一个分屏", "Focus Previous Pane")
        case .commandPalette:   return loc.t("命令面板", "Command Palette")
        case .showPet:          return loc.t("宠物对话窗口", "Desktop Pet Chat")
        case .splitRight:       return loc.t("分屏（每行两个，满了换行）", "Split (two per row, then a new row)")
        case .splitDown:        return loc.t("向下分屏", "Split Down")
        case .focusPaneLeft:    return loc.t("聚焦左侧分屏", "Focus Pane Left")
        case .focusPaneRight:   return loc.t("聚焦右侧分屏", "Focus Pane Right")
        case .focusPaneUp:      return loc.t("聚焦上方分屏", "Focus Pane Up")
        case .focusPaneDown:    return loc.t("聚焦下方分屏", "Focus Pane Down")
        case .equalizeSplits:   return loc.t("均分分屏", "Equalize Splits")
        case .toggleSplitZoom:  return loc.t("放大 / 还原分屏", "Zoom / Restore Pane")
        case .jumpToPreviousPrompt: return loc.t("跳到上一个提示符", "Jump to Previous Prompt")
        case .jumpToNextPrompt:     return loc.t("跳到下一个提示符", "Jump to Next Prompt")
        case .copyLastOutput:       return loc.t("复制上一条命令的输出", "Copy Last Command Output")
        case .toggleQuickTerminal:  return loc.t("快捷终端（全局）", "Quick Terminal (global)")
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .newConnection:    return KeyShortcut(key: "n")
        case .newLocalTerminal: return KeyShortcut(key: "t")
        case .quickConnect:     return KeyShortcut(key: "k", option: true)
        case .refreshStatuses:  return KeyShortcut(key: "r")
        case .find:             return KeyShortcut(key: "f")
        case .toggleSidebar:    return KeyShortcut(key: "s")
        case .toggleAI:         return KeyShortcut(key: "i")
        case .suggestCommand:   return KeyShortcut(key: ";")
        case .editHost:         return KeyShortcut(key: "e")
        case .closeShell:       return KeyShortcut(key: "w")
        case .showTodos:        return KeyShortcut(key: "d", option: true)   // ⌘D is Split Right
        case .focusTerminal:    return KeyShortcut(key: "l")
        case .focusNextPane:    return KeyShortcut(key: "]")
        case .focusPrevPane:    return KeyShortcut(key: "[")
        case .commandPalette:   return KeyShortcut(key: "p")
        case .showPet:          return KeyShortcut(key: "j", option: true)
        // Same keys as Ghostty / iTerm2.
        case .splitRight:       return KeyShortcut(key: "d")
        case .splitDown:        return KeyShortcut(key: "d", shift: true)
        case .focusPaneLeft:    return KeyShortcut(key: "left", option: true)
        case .focusPaneRight:   return KeyShortcut(key: "right", option: true)
        case .focusPaneUp:      return KeyShortcut(key: "up", option: true)
        case .focusPaneDown:    return KeyShortcut(key: "down", option: true)
        case .equalizeSplits:   return KeyShortcut(key: "=", control: true)
        case .toggleSplitZoom:  return KeyShortcut(key: "return", shift: true)
        case .jumpToPreviousPrompt: return KeyShortcut(key: "up")      // Ghostty's default
        case .jumpToNextPrompt:     return KeyShortcut(key: "down")
        case .copyLastOutput:       return KeyShortcut(key: "c", option: true)
        case .toggleQuickTerminal:  return KeyShortcut(key: "`", command: false, control: true)
        }
    }
}

/// Holds the active shortcut for every action, persisted to `UserDefaults`.
/// A shared singleton so both the SwiftUI menu commands and the AppKit terminal
/// view read the same live bindings.
@Observable
final class KeyBindingStore: @unchecked Sendable {
    static let shared = KeyBindingStore()

    /// Bumped on any change so SwiftUI menus rebuild with the new shortcuts.
    private(set) var version = 0

    private var map: [String: KeyShortcut] = [:]
    private let defaultsKey = "wireline.keyBindings"

    init() { load() }

    func shortcut(for action: ShortcutAction) -> KeyShortcut {
        configOverrides[action] ?? map[action.rawValue] ?? action.defaultShortcut
    }

    /// `keybind` lines from the config file; they win over the GUI bindings.
    private(set) var configOverrides: [ShortcutAction: KeyShortcut] = [:]

    func isFromConfig(_ action: ShortcutAction) -> Bool { configOverrides[action] != nil }

    func setConfigOverrides(_ overrides: [ShortcutAction: KeyShortcut]) {
        guard overrides != configOverrides else { return }
        configOverrides = overrides
        version += 1
        NotificationCenter.default.post(name: .keyBindingsChanged, object: nil)
    }

    /// The action currently bound to `s`, if any (used for conflict detection).
    func conflict(for s: KeyShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && shortcut(for: $0) == s }
    }

    @discardableResult
    func set(_ s: KeyShortcut, for action: ShortcutAction) -> ShortcutAction? {
        if let clash = conflict(for: s, excluding: action) { return clash }
        map[action.rawValue] = s
        persist()
        return nil
    }

    func reset(_ action: ShortcutAction) {
        map[action.rawValue] = nil
        persist()
    }

    func resetAll() {
        map.removeAll()
        persist()
    }

    // Persistence ----------------------------------------------------------
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: KeyShortcut].self, from: data)
        else { return }
        map = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        version += 1
        NotificationCenter.default.post(name: .keyBindingsChanged, object: nil)
    }
}
