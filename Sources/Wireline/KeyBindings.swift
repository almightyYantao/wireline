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

    /// Human-readable badge, e.g. "⇧⌘T".
    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += key.uppercased()
        return s
    }

    // SwiftUI menu bridging ------------------------------------------------
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key.isEmpty ? " " : key)) }

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
        guard event.charactersIgnoringModifiers?.lowercased() == key else { return false }
        let f = event.modifierFlags
        return f.contains(.command) == command
            && f.contains(.shift) == shift
            && f.contains(.option) == option
            && f.contains(.control) == control
    }

    /// Build from a captured AppKit key-down event (nil if it has no usable key).
    static func from(event: NSEvent) -> KeyShortcut? {
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
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .newConnection:    return KeyShortcut(key: "n")
        case .newLocalTerminal: return KeyShortcut(key: "t")
        case .quickConnect:     return KeyShortcut(key: "k")
        case .refreshStatuses:  return KeyShortcut(key: "r")
        case .find:             return KeyShortcut(key: "f")
        case .toggleSidebar:    return KeyShortcut(key: "s")
        case .toggleAI:         return KeyShortcut(key: "i")
        case .suggestCommand:   return KeyShortcut(key: ";")
        case .editHost:         return KeyShortcut(key: "e")
        case .closeShell:       return KeyShortcut(key: "w")
        case .showTodos:        return KeyShortcut(key: "d")
        case .focusTerminal:    return KeyShortcut(key: "l")
        case .focusNextPane:    return KeyShortcut(key: "]")
        case .focusPrevPane:    return KeyShortcut(key: "[")
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
        map[action.rawValue] ?? action.defaultShortcut
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
    }
}
