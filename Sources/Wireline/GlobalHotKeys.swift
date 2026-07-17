import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys, registered with the Carbon Event Manager so they fire no
/// matter which app is frontmost (unlike SwiftUI `.keyboardShortcut`, which only
/// works while Wireline is active). Used to summon the desktop pet (⌘J) and the
/// Quick Connect palette (⌘K) from anywhere. RegisterEventHotKey needs no
/// Accessibility permission and works inside the App Sandbox.
///
/// Registrations track the user's live key bindings: `reload()` re-reads
/// `KeyBindingStore` and is called automatically whenever a binding changes.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    /// The actions we expose globally, each with what to do when it fires.
    private var handlers: [ShortcutAction: () -> Void] = [:]
    /// Live Carbon registrations, keyed by the numeric hot-key id we assigned.
    private var registered: [(ref: EventHotKeyRef, id: UInt32)] = []
    private var fired: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    /// Install the shared event handler once and register the given actions.
    func start(_ handlers: [ShortcutAction: () -> Void]) {
        self.handlers = handlers
        installHandler()
        reload()
        NotificationCenter.default.addObserver(
            forName: .keyBindingsChanged, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { GlobalHotKeys.shared.reload() } }
    }

    /// Re-register every hot key from the current bindings (call after a rebind).
    func reload() {
        for (ref, _) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        fired.removeAll()

        for (action, handler) in handlers {
            let s = KeyBindingStore.shared.shortcut(for: action)
            guard s.hasModifier, let code = Self.keyCode(for: s.key) else { continue }
            let id = nextID; nextID += 1
            let hkID = EventHotKeyID(signature: Self.signature, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), Self.carbonModifiers(s),
                                             hkID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered.append((ref, id))
                fired[id] = handler
            }
        }
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            // The Carbon callback runs on the main thread; hop through the main
            // queue so we can safely touch MainActor state.
            DispatchQueue.main.async {
                GlobalHotKeys.shared.fire(id)
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    private func fire(_ id: UInt32) { fired[id]?() }

    // MARK: - Encoding

    /// Four-char signature ("WLN1") so our hot-key ids don't collide with others.
    private static let signature = OSType(0x574C_4E31)

    private static func carbonModifiers(_ s: KeyShortcut) -> UInt32 {
        var m: UInt32 = 0
        if s.command { m |= UInt32(cmdKey) }
        if s.shift   { m |= UInt32(shiftKey) }
        if s.option  { m |= UInt32(optionKey) }
        if s.control { m |= UInt32(controlKey) }
        return m
    }

    /// Map a KeyShortcut's character to its ANSI virtual key code (layout-
    /// independent physical key). Covers letters, digits and the punctuation the
    /// binding UI allows.
    private static func keyCode(for key: String) -> Int? { map[key.lowercased()] }

    private static let map: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]
}
