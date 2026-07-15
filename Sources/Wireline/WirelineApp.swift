import SwiftUI
import WirelineCore

@main
struct WirelineApp: App {
    @State private var store = HostStore()
    @State private var forwards = ForwardStore()
    @State private var sessions = SessionStore()
    @State private var snippets = SnippetStore()
    @State private var loc = Localizer.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        #if DEBUG
        // Connect to InjectionIII (if installed) for live hot reload in debug.
        // No-op when InjectionIII isn't present, and compiled out of release.
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        #endif
    }

    var body: some Scene {
        // Main window: a single, unique window so "connect" focuses it rather
        // than spawning a duplicate.
        Window("Wireline", id: "main") {
            ContentView()
                .environment(store)
                .environment(forwards)
                .environment(sessions)
                .environment(snippets)
                .environment(loc)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    if store.autoCheckOnLaunch { await store.checkAll() }
                    store.startMonitoring()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Local Terminal") {
                    openLocalShell(sessions: sessions, openWindow: openWindow)
                }
                .keyboardShortcut("t", modifiers: [.command])
                Button("Quick Connect…") { NotificationCenter.default.post(name: .showQuickConnect, object: nil) }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Refresh Statuses") { Task { await store.checkAll() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Find") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(loc)
                .preferredColorScheme(.dark)
        }
    }
}
