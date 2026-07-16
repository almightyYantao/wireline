import SwiftUI
import WirelineCore

@main
struct WirelineApp: App {
    @State private var store = HostStore()
    @State private var forwards = ForwardStore()
    @State private var sessions = SessionStore()
    @State private var snippets = SnippetStore()
    @State private var todos = TodoStore()
    @State private var loc = Localizer.shared
    @State private var keys = KeyBindingStore.shared
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
                    // Let the backup layer see the to-do list without coupling
                    // HostStore to TodoStore.
                    store.currentTodos = { [todos] in todos.todos }
                    store.restoreTodos = { [todos] items in todos.replaceAll(items) }
                    Notifier.requestAuthorization()
                    // Reopen the tabs that were open at last quit (reconnects).
                    sessions.restoreIfNeeded(store: store)
                    if store.autoCheckOnLaunch { await store.checkAll() }
                    store.startMonitoring()
                    store.startAutoBackup()
                }
        }
        .windowStyle(.hiddenTitleBar)   // SwiftUI-managed, so it survives sheets & window switches
        .commands {
            CommandGroup(after: .newItem) {
                // `keys.version` is read so the menu rebuilds when a shortcut changes.
                let _ = keys.version
                Button("New Connection") { NotificationCenter.default.post(name: .newConnection, object: nil) }
                    .shortcut(.newConnection, keys)
                Button("New Local Terminal") {
                    openLocalShell(sessions: sessions, openWindow: openWindow)
                }
                .shortcut(.newLocalTerminal, keys)
                Button("Quick Connect…") { NotificationCenter.default.post(name: .showQuickConnect, object: nil) }
                    .shortcut(.quickConnect, keys)
                Button("Refresh Statuses") { Task { await store.checkAll() } }
                    .shortcut(.refreshStatuses, keys)
                // ⌘F searches the terminal scrollback when a session is active,
                // otherwise focuses the host-list search in the sidebar.
                Button("Find") {
                    if sessions.activeSession != nil {
                        NotificationCenter.default.post(name: .searchTerminal, object: nil)
                    } else {
                        NotificationCenter.default.post(name: .focusSearch, object: nil)
                    }
                }
                .shortcut(.find, keys)
                Button("Toggle Sidebar") { NotificationCenter.default.post(name: .toggleSidebar, object: nil) }
                    .shortcut(.toggleSidebar, keys)
                Button("Toggle AI Panel") { NotificationCenter.default.post(name: .toggleAI, object: nil) }
                    .shortcut(.toggleAI, keys)
                Button("Suggest Next Command") { NotificationCenter.default.post(name: .suggestCommand, object: nil) }
                    .shortcut(.suggestCommand, keys)
                Button("Focus Terminal") { NotificationCenter.default.post(name: .focusTerminal, object: nil) }
                    .shortcut(.focusTerminal, keys)
                Button("Focus Next Pane") { NotificationCenter.default.post(name: .focusNextPane, object: nil) }
                    .shortcut(.focusNextPane, keys)
                Button("Focus Previous Pane") { NotificationCenter.default.post(name: .focusPrevPane, object: nil) }
                    .shortcut(.focusPrevPane, keys)
                Button("Edit Host") { NotificationCenter.default.post(name: .editHost, object: nil) }
                    .shortcut(.editHost, keys)
                Button("To-Do List") { openWindow(id: "todos") }
                    .shortcut(.showTodos, keys)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Select Tab \(n)") {
                        NotificationCenter.default.post(name: .selectTab, object: n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                }
            }
            // Route ⌘, to our own settings window instead of the native one.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: [.command])
            }
        }

        // Custom settings window styled like the main window (hidden title bar,
        // dark chrome) rather than the native preferences window.
        Window("Wireline Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(loc)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Standalone to-do window, invoked from the menu / a customizable
        // shortcut (⌘D by default). A single unique window so re-invoking focuses
        // it instead of spawning duplicates.
        Window("Wireline To-Do", id: "todos") {
            TodoWindowView()
                .environment(todos)
                .environment(store)
                .environment(loc)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 440, height: 560)
        .defaultPosition(.topTrailing)

        // Menu-bar extra: a live count of open items plus quick add / toggle,
        // so the to-do list is one click away without opening a window.
        MenuBarExtra {
            TodoMenuBarView(openWindow: { openWindow(id: "todos") })
                .environment(todos)
                .environment(loc)
        } label: {
            let _ = todos.todos   // observe so the badge updates live
            Image(systemName: "checklist")
            if todos.activeCount > 0 { Text("\(todos.activeCount)") }
        }
        .menuBarExtraStyle(.window)
    }
}
