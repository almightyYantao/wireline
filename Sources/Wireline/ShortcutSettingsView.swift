import SwiftUI
import AppKit

/// Preferences tab that lists every remappable action and lets the user record a
/// new shortcut for each one. Recording uses a local key-down monitor so any
/// modifier combination can be captured.
struct ShortcutSettingsView: View {
    @Environment(Localizer.self) private var loc
    @State private var keys = KeyBindingStore.shared
    @State private var recording: ShortcutAction?
    @State private var monitor = KeyRecorder()
    @State private var warning: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WLFormSection(loc("键盘快捷键", "Keyboard Shortcuts"),
                              footer: loc("点击右侧快捷键，然后按下新的组合键（需含 ⌘ / ⌃ / ⌥）。按 Esc 取消。",
                                          "Click a shortcut, then press the new combination (must include ⌘ / ⌃ / ⌥). Press Esc to cancel.")) {
                    ForEach(ShortcutAction.allCases) { action in
                        row(action)
                        if action != ShortcutAction.allCases.last { WLFormDivider() }
                    }
                }

                HStack {
                    if let warning {
                        Text(warning).font(WL.caption).foregroundStyle(WL.red)
                    }
                    Spacer()
                    Button(loc("全部恢复默认", "Reset All")) {
                        keys.resetAll(); warning = nil; stopRecording()
                    }
                    .buttonStyle(.wlSecondary)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { stopRecording() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = recording == action
        return HStack(spacing: 10) {
            Text(action.name(loc)).font(WL.body).foregroundStyle(WL.textPrimary)
            Spacer()
            if keys.isFromConfig(action) {
                ConfigLockTag(key: "keybind")
            } else if keys.shortcut(for: action) != action.defaultShortcut {
                Button(loc("默认", "Default")) {
                    keys.reset(action); warning = nil
                    if isRecording { stopRecording() }
                }
                .buttonStyle(.wlChip())
            }
            // The key cap: a capsule like the fields; recording lights it up.
            Button {
                if isRecording { stopRecording() } else { startRecording(action) }
            } label: {
                Text(isRecording ? loc("按下按键…", "Press keys…")
                                 : keys.shortcut(for: action).display)
                    .font(WL.mono(12, .medium))
                    .foregroundStyle(isRecording ? WL.green : WL.textPrimary)
                    .frame(minWidth: 74)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(isRecording ? WL.green.opacity(0.14) : WL.fieldFill, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(WL.green.opacity(isRecording ? 0.7 : 0), lineWidth: 1))
                    .animation(Motion.state, value: isRecording)
            }
            .buttonStyle(.wlPlain)
            .disabled(keys.isFromConfig(action))
        }
        .frame(minHeight: 38)
        .padding(.vertical, 2)
    }

    private func startRecording(_ action: ShortcutAction) {
        warning = nil
        recording = action
        monitor.start { event in
            // Esc cancels.
            if event.keyCode == 53 { stopRecording(); return }
            guard let s = KeyShortcut.from(event: event) else { return }
            guard s.hasModifier else {
                warning = loc("快捷键至少需要一个修饰键（⌘ / ⌃ / ⌥）。",
                              "A shortcut needs at least one modifier (⌘ / ⌃ / ⌥).")
                return
            }
            if let clash = keys.set(s, for: action) {
                warning = loc("\(s.display) 已被「\(clash.name(loc))」占用。",
                              "\(s.display) is already used by “\(clash.name(loc))”.")
            } else {
                warning = nil
            }
            stopRecording()
        }
    }

    private func stopRecording() {
        monitor.stop()
        recording = nil
    }
}

/// Wraps a local NSEvent key-down monitor for capturing a shortcut. Kept in a
/// reference type so SwiftUI's value-type views can start/stop it safely.
@MainActor
final class KeyRecorder {
    private var handle: Any?

    func start(_ onKey: @escaping (NSEvent) -> Void) {
        stop()
        handle = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(event)
            return nil   // swallow the event while recording
        }
    }

    func stop() {
        if let handle { NSEvent.removeMonitor(handle) }
        handle = nil
    }
}
