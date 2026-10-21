import SwiftUI
import AppKit
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
                    // Bring up the Touch ID ssh-agent first (when any key is
                    // protected) so restored sessions launch already pointed at it.
                    SSHAgentController.shared.startIfNeeded()
                    // Apply ~/.config/wireline/config over the GUI settings and
                    // start watching it.
                    ConfigStore.shared.attach(store)
                    QuickTerminalController.shared.attach(store)
                    // Follow the system's light / dark switch when a theme pair is set.
                    store.applyAppearanceTheme()
                    DistributedNotificationCenter.default().addObserver(
                        forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                        object: nil, queue: .main
                    ) { [store] _ in MainActor.assumeIsolated { store.applyAppearanceTheme() } }
                    // Scan installed fonts off the main thread so Settings opens instantly.
                    FontCatalog.shared.warm()
                    // Let the backup layer see the to-do list without coupling
                    // HostStore to TodoStore.
                    store.currentTodos = { [todos] in todos.todos }
                    store.restoreTodos = { [todos] items in todos.replaceAll(items) }
                    Notifier.requestAuthorization()
                    // Reopen the tabs that were open at last quit (reconnects).
                    sessions.restoreIfNeeded(store: store)
                    // Flush scrollback (and snapshots) on quit so the very last
                    // output is restored next launch, not just up to the last tab change.
                    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                           object: nil, queue: .main) { [sessions] _ in
                        MainActor.assumeIsolated { sessions.persist() }
                    }
                    if store.autoCheckOnLaunch { await store.checkAll() }
                    store.startMonitoring()
                    store.startAutoBackup()
                    // Reconnect enabled MCP servers so their tools are available to the AI.
                    await MCPStore.shared.connectEnabled()
                    // Float the desktop pet on launch (unless the user disabled it).
                    // It grabs key status when opened, so re-assert terminal focus
                    // afterwards — otherwise a restored session starts unfocused.
                    if AIConfig.shared.petEnabled { openWindow(id: "pet") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [sessions] in
                        sessions.focusActiveTerminal()
                    }
                    // System-wide hotkeys: summon the pet / Quick Connect from any
                    // app. The Carbon handler activates us, then these post the UI.
                    GlobalHotKeys.shared.start([
                        .showPet: {
                            NSApp.activate(ignoringOtherApps: true)
                            NotificationCenter.default.post(name: .summonPet, object: nil)
                        },
                        .toggleQuickTerminal: { QuickTerminalController.shared.toggle() },
                        .quickConnect: {
                            NSApp.activate(ignoringOtherApps: true)
                            NotificationCenter.default.post(name: .summonQuickConnect, object: nil)
                        },
                    ])
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
                Button("Command Palette…") { NotificationCenter.default.post(name: .showCommandPalette, object: nil) }
                    .shortcut(.commandPalette, keys)
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
                // Splits — every layout change runs freeze → animate → one reflow.
                Button("Split Right") { wlAnimateTerminalLayout { sessions.splitActive(.trailing) } }
                    .shortcut(.splitRight, keys)
                Button("Split Down") { wlAnimateTerminalLayout { sessions.splitActive(.bottom) } }
                    .shortcut(.splitDown, keys)
                Button("Focus Pane Left") { sessions.focusPane(.left) }.shortcut(.focusPaneLeft, keys)
                Button("Focus Pane Right") { sessions.focusPane(.right) }.shortcut(.focusPaneRight, keys)
                Button("Focus Pane Up") { sessions.focusPane(.up) }.shortcut(.focusPaneUp, keys)
                Button("Focus Pane Down") { sessions.focusPane(.down) }.shortcut(.focusPaneDown, keys)
                Button("Equalize Splits") { wlAnimateTerminalLayout { sessions.equalizeSplits() } }
                    .shortcut(.equalizeSplits, keys)
                Button("Zoom Pane") { wlAnimateTerminalLayout { sessions.toggleZoom() } }
                    .shortcut(.toggleSplitZoom, keys)
                Divider()
                // OSC 133 command marks (shell integration).
                Button("Jump to Previous Prompt") { sessions.activeSession?.terminalView.jumpToPrompt(-1) }
                    .shortcut(.jumpToPreviousPrompt, keys)
                Button("Jump to Next Prompt") { sessions.activeSession?.terminalView.jumpToPrompt(1) }
                    .shortcut(.jumpToNextPrompt, keys)
                Button("Copy Last Command Output") { copyLastOutput(sessions) }
                    .shortcut(.copyLastOutput, keys)
                Button("Quick Terminal") { QuickTerminalController.shared.toggle() }
                    .shortcut(.toggleQuickTerminal, keys)
                Button("Edit Host") { NotificationCenter.default.post(name: .editHost, object: nil) }
                    .shortcut(.editHost, keys)
                if todos.enabled {
                    Button("To-Do List") { openWindow(id: "todos") }
                        .shortcut(.showTodos, keys)
                }
                Button("Desktop Pet") {
                    openWindow(id: "pet")
                    // Post after the window has a chance to mount & subscribe, so a
                    // freshly-opened pet still receives the toggle/focus signal.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        NotificationCenter.default.post(name: .focusPet, object: nil)
                    }
                }
                .shortcut(.showPet, keys)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Select Tab \(n)") {
                        NotificationCenter.default.post(name: .selectTab, object: n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                }
                Button("Next Tab") { NotificationCenter.default.post(name: .cycleTab, object: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { NotificationCenter.default.post(name: .cycleTab, object: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Move Tab Right") { NotificationCenter.default.post(name: .moveTab, object: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                Button("Move Tab Left") { NotificationCenter.default.post(name: .moveTab, object: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                Divider()
                Button("Zoom In") { NotificationCenter.default.post(name: .zoomFont, object: 1.0) }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("Zoom Out") { NotificationCenter.default.post(name: .zoomFont, object: -1.0) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Reset Zoom") { NotificationCenter.default.post(name: .zoomFont, object: 0.0) }
                    .keyboardShortcut("0", modifiers: [.command])
            }
            // Route ⌘, to our own settings window instead of the native one.
            CommandGroup(replacing: .appSettings) {
                Button(loc("设置…", "Settings…")) { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: [.command])
                Button(loc("打开配置文件…", "Open Config File…")) { ConfigStore.shared.openInEditor() }
                Button(loc("重新加载配置", "Reload Configuration")) { ConfigStore.shared.reload() }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { Updater.shared.checkForUpdates() }
            }
        }

        // Custom settings window styled like the main window (hidden title bar,
        // dark chrome) rather than the native preferences window.
        Window("Wireline Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(todos)
                .environment(loc)
                .preferredColorScheme(WL.colorScheme)
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

        // The floating desktop pet: a draggable, always-on-top AI companion that
        // operates the currently active terminal tab. A single unique window.
        Window("Wireline Pet", id: "pet") {
            PetView()
                .environment(store)
                .environment(sessions)
                .environment(snippets)
                .environment(forwards)
                .environment(loc)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)

        // Menu-bar extra: a live count of open items plus quick add / toggle,
        // so the to-do list is one click away without opening a window. Removed
        // from the menu bar entirely when the to-do feature is disabled.
        MenuBarExtra(isInserted: Binding(get: { todos.enabled }, set: { todos.enabled = $0 })) {
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

/// Put the active session's last command output on the pasteboard.
@MainActor
func copyLastOutput(_ sessions: SessionStore) {
    let loc = Localizer.shared
    guard let text = sessions.activeSession?.terminalView.lastCommandOutput() else {
        ConfigStore.shared.announce(loc.t("没有可复制的命令输出（需要 shell 集成）",
                                          "No command output to copy (needs shell integration)"), isError: true)
        return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
    ConfigStore.shared.announce(loc.t("已复制上一条命令的输出（\(n) 行）", "Copied last command output (\(n) lines)"))
}
