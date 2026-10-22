import SwiftUI
import Inject
import WirelineCore

extension Notification.Name {
    static let focusSearch = Notification.Name("wireline.focusSearch")
    static let showQuickConnect = Notification.Name("wireline.showQuickConnect")
    static let toggleSidebar = Notification.Name("wireline.toggleSidebar")
    static let editHost = Notification.Name("wireline.editHost")
    static let newConnection = Notification.Name("wireline.newConnection")
    static let selectTab = Notification.Name("wireline.selectTab")
    static let toggleAI = Notification.Name("wireline.toggleAI")
    static let suggestCommand = Notification.Name("wireline.suggestCommand")
    static let aiConnect = Notification.Name("wireline.aiConnect")
    static let aiOpenFiles = Notification.Name("wireline.aiOpenFiles")
    static let focusTerminal = Notification.Name("wireline.focusTerminal")
    static let searchTerminal = Notification.Name("wireline.searchTerminal")
    static let focusNextPane = Notification.Name("wireline.focusNextPane")
    static let focusPrevPane = Notification.Name("wireline.focusPrevPane")
    static let showCommandPalette = Notification.Name("wireline.showCommandPalette")
    static let cycleTab = Notification.Name("wireline.cycleTab")
    static let moveTab = Notification.Name("wireline.moveTab")
    static let zoomFont = Notification.Name("wireline.zoomFont")
    static let focusPet = Notification.Name("wireline.focusPet")
    /// Fired by the global hotkeys: bring Wireline forward, then open/focus the
    /// pet or the Quick Connect palette (from any app).
    static let summonPet = Notification.Name("wireline.summonPet")
    static let summonQuickConnect = Notification.Name("wireline.summonQuickConnect")
    /// Posted whenever a key binding changes, so global hotkeys can re-register.
    static let keyBindingsChanged = Notification.Name("wireline.keyBindingsChanged")
}

/// Right-panel mode. `nil` = SSH (terminal sessions).
enum SidebarItem: Hashable {
    case forwarding
    case files
    case keys
}

struct ContentView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var editing: HostEditContext?
    @State private var showBackup = false
    @State private var operation: SidebarItem?
    @State private var fileHost: Host?
    @State private var selectedAlias: String?
    @State private var showQuickConnect = false
    @State private var showCommandPalette = false
    @State private var sidebarOpen = false
    @State private var openedByHover = false
    @State private var hoverOpenTask: DispatchWorkItem?
    @State private var chrome = WindowChromeController()
    @State private var palette = Palette.shared
    @ObserveInjection var inject

    var body: some View {
        ZStack {
            // App-wide wallpaper: the bottom-most layer, filling the entire window
            // (including under the transparent title bar) so every translucent
            // panel above composites over it uniformly.
            WallpaperView(path: store.terminalBgImagePath)
                .ignoresSafeArea()
            // The terminal area always fills the window; the host list is a
            // drawer that slides *over* it. Opening or closing it never resizes
            // a terminal, so there's nothing to reflow.
            RightPanel(operation: $operation, fileHost: $fileHost, selectedAlias: $selectedAlias,
                       onEditHost: { editing = HostEditContext(host: $0) },
                       sidebarCollapsed: true)
                .ignoresSafeArea()
            sidebarDrawer
                .ignoresSafeArea()

            overlays
        }
        .wlMenuHost()
        .background(WindowAccessor { w in chrome.attach(to: w) })
        .id(palette.version)   // rebuild the tree when the theme recolors the UI
        .preferredColorScheme(WL.colorScheme)
        .onChange(of: sessions.sessions.count) { old, new in
            // A new session opened (⌘T / quick connect / host connect): jump to
            // the terminal view and auto-collapse the sidebar for more room.
            if new > old {
                operation = nil
                setSidebar(false)
            }
        }
        .modifier(DrawerAutoClose(activeTab: sessions.activeTabID, selectedAlias: selectedAlias,
                                  operation: operation, close: { setSidebar(false) }))
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in toggleSidebar() }
        .onReceive(NotificationCenter.default.publisher(for: .editHost)) { _ in
            if let host = currentHost { editing = HostEditContext(host: host) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            editing = HostEditContext(host: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTab)) { note in
            if let n = note.object as? Int { sessions.selectIndex(n) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiConnect)) { note in
            if let alias = note.object as? String, let host = store.hosts.first(where: { $0.alias == alias }) {
                connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiOpenFiles)) { note in
            if let alias = note.object as? String, let host = store.hosts.first(where: { $0.alias == alias }) {
                fileHost = host; operation = .files
            }
        }
        .sheet(item: $editing) { ctx in
            HostEditorView(context: ctx).environment(store)
        }
        .sheet(isPresented: $showBackup) {
            BackupView().environment(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickConnect)) { _ in
            wlAnimate(Motion.modalIn) { showQuickConnect = true }
        }
        // Global-hotkey entry points: the app was just activated by the Carbon
        // handler; bring the right window forward and open the surface.
        .onReceive(NotificationCenter.default.publisher(for: .summonQuickConnect)) { _ in
            openWindow(id: "main")
            wlAnimate(Motion.modalIn) { showQuickConnect = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .summonPet)) { _ in
            openWindow(id: "pet")
            // Give a freshly-opened pet window a moment to mount & subscribe
            // before toggling it (mirrors the menu command).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NotificationCenter.default.post(name: .focusPet, object: nil)
            }
        }
        .modifier(PaletteTabHandlers(store: store, sessions: sessions, showCommandPalette: $showCommandPalette))
        .alert("Something went wrong", isPresented: .constant(store.lastError != nil)) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .enableInjection()
    }

    /// The host currently in focus — the selected one, else the active session's.
    private var currentHost: Host? {
        let alias = selectedAlias ?? sessions.activeSession?.alias
        return alias.flatMap { a in store.hosts.first { $0.alias == a } }
    }

    /// The keyboard-driven overlays (Quick Connect, Command Palette) — in-window
    /// overlays, not sheets, so they never trigger the AppKit title-bar reset /
    /// flash. Scrim and card are separate children of the `if` so each gets its
    /// own transition (scrim fades, card settles in).
    @ViewBuilder
    private var overlays: some View {
        ZStack {
            ConfigToast()
            if showQuickConnect {
                scrim { wlAnimate(Motion.modalOut) { showQuickConnect = false } }
                modalCard(width: 620, height: 420) {
                    CommandPaletteView(onClose: { wlAnimate(Motion.modalOut) { showQuickConnect = false } })
                }
            }
            if showCommandPalette {
                scrim { wlAnimate(Motion.modalOut) { showCommandPalette = false } }
                modalCard(width: 640, height: 460) {
                    CommandPaletteView(initialQuery: ">", onClose: { wlAnimate(Motion.modalOut) { showCommandPalette = false } })
                }
            }
        }
    }

    private func scrim(onTap: @escaping () -> Void) -> some View {
        Color.black.opacity(WL.depth(0.4))
            .ignoresSafeArea()
            .onTapGesture(perform: onTap)
            .transition(.wlScrim)
    }

    private func modalCard<C: View>(width: CGFloat, height: CGFloat,
                                    @ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: WL.radius(16), style: .continuous)
        return content()
            .frame(width: width, height: height)
            .clipShape(shape)
            .wlFloating(shape, shadow: 0.5, radius: 28, y: 10)
            .transition(.wlModal)
    }

    private func toggleSidebar() { setSidebar(!sidebarOpen) }

    private func setSidebar(_ open: Bool, byHover: Bool = false) {
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        guard open != sidebarOpen else { return }
        openedByHover = open && byHover
        wlAnimate(open ? Motion.expand : Motion.popOut) { sidebarOpen = open }
    }

    /// The host list as an overlay drawer: a 6pt hot zone on the window's left
    /// edge opens it on hover, ⌘S or the corner button toggle it, a click
    /// outside (or connecting) closes it, and one opened by hover closes when
    /// the pointer leaves.
    private var drawerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WL.radius(14), style: .continuous)
    }

    private var sidebarDrawer: some View {
        ZStack(alignment: .topLeading) {
            if sidebarOpen {
                Color.black.opacity(WL.depth(0.14))
                    .contentShape(Rectangle())
                    .onTapGesture { setSidebar(false) }
                    .transition(.opacity)
            }
            // Hover hot zone along the left edge.
            Color.clear
                .frame(width: 6).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside, !sidebarOpen else { hoverOpenTask?.cancel(); return }
                    let task = DispatchWorkItem { setSidebar(true, byHover: true) }
                    hoverOpenTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
                }
            // Corner button, level with the tab bar.
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.wlIcon(tint: WL.textDim, size: 26))
            .help(Localizer.shared.t("主机列表 (⌘S)", "Hosts (⌘S)"))
            .blocksWindowDrag()   // title-bar band: see WLPageHeader
            // In the title-bar row, just right of the traffic lights.
            .frame(height: TitleBand.shared.height)
            .padding(.leading, TitleBand.shared.lightsTrailing + 10)
            .opacity(sidebarOpen ? 0 : 1)

            // Only in the hierarchy while open. Merely sliding it off-screen
            // left its AppKit-backed pieces (the host list's NSScrollView, the
            // search field) catching clicks across the window's left 340pt —
            // SwiftUI's offset / allowsHitTesting don't reach them. Search text
            // and folded groups live outside the panel, so nothing is lost.
            if sidebarOpen {
                LeftPanel(query: $query, operation: $operation, selectedAlias: $selectedAlias,
                          onAdd: { editing = HostEditContext(host: nil, defaultGroup: $0) },
                          onEdit: { editing = HostEditContext(host: $0) },
                          onBackup: { showBackup = true },
                          onOpenFiles: { fileHost = $0; operation = .files; setSidebar(false) },
                          onCollapse: { setSidebar(false) })
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    // A floating card like the panes: opaque (no terminal text
                    // showing through), rounded, inset from the window edges.
                    .background {
                        drawerShape.fill(WL.bg)
                            .shadow(color: .black.opacity(WL.depth(0.32)), radius: 22, x: 4, y: 6)
                    }
                    .clipShape(drawerShape)
                    .overlay(drawerShape.strokeBorder(WL.textPrimary.opacity(WL.isLight ? 0.08 : 0.12), lineWidth: 1)
                        .allowsHitTesting(false))
                    .padding(wlPaneGap)
                    .wlOccludesTerminal()
                    .onHover { inside in
                        if !inside, openedByHover { setSidebar(false) }
                    }
                    .transition(Motion.reduce ? .opacity : .move(edge: .leading))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Handlers for the command palette, tab cycling/moving, and font zoom. Grouped
/// into a modifier so `ContentView.body`'s modifier chain stays short enough for
/// the Swift type-checker.
private struct PaletteTabHandlers: ViewModifier {
    let store: HostStore
    let sessions: SessionStore
    @Binding var showCommandPalette: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
                wlAnimate(Motion.modalIn) { showCommandPalette = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cycleTab)) { note in
                if let d = note.object as? Int { sessions.focusAdjacentTab(d) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveTab)) { note in
                if let d = note.object as? Int { sessions.moveActiveTab(d) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomFont)) { note in
                // Drive the app's real font-size setting; TerminalHostView re-applies
                // it to every terminal on redraw.
                guard let d = note.object as? Double else { return }
                store.terminalFontSize = d == 0 ? 13 : min(28, max(9, store.terminalFontSize + d))
            }
    }
}

/// Wraps an optional host so `.sheet(item:)` can present both add and edit.
struct HostEditContext: Identifiable {
    let id = UUID()
    let host: Host?
    var defaultGroup: String? = nil
}

// MARK: - Left panel

struct LeftPanel: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Binding var query: String
    @Environment(Localizer.self) private var loc
    @Binding var operation: SidebarItem?
    @Binding var selectedAlias: String?
    /// The row a single click highlighted. Only that: opening the details page
    /// is a context-menu action, connecting is a double click.
    @State private var highlightedAlias: String?
    var onAdd: (String?) -> Void
    var onEdit: (Host) -> Void
    var onBackup: () -> Void
    var onOpenFiles: (Host) -> Void
    var onCollapse: () -> Void

    @State private var collapsed: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? ["未分组"])
    @State private var showNewGroup = false
    @State private var searchHighlight = 0
    @FocusState private var searchFocused: Bool
    @Namespace private var segment

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var searchResults: [Host] {
        let q = trimmed.lowercased()
        return store.hosts
            .compactMap { h in HostStore.fuzzyScore(query: q, host: h).map { ($0, h) } }
            .sorted { $0.0 > $1.0 }.map(\.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            functionRow
            Rectangle().fill(WL.border.opacity(0.5)).frame(height: 1)
            ScrollView {
                hostSections
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
                    .contentShape(Rectangle())
                    .wlContextMenuBackground([.item(loc("新建分组…", "New Group…"), systemImage: "plus") { presentNewGroup() }])
            }
            Rectangle().fill(WL.border.opacity(0.5)).frame(height: 1)
            bottomBar
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupSheet { name in store.createGroup(name) }
        }
    }

    private func presentNewGroup() { showNewGroup = true }

    /// Title row, level with the traffic lights; actions are quiet icons.
    private var header: some View {
        HStack(spacing: 2) {
            Text(loc("主机", "Hosts")).font(WL.mono(13, .semibold)).foregroundStyle(WL.textPrimary)
            Text("\(store.hosts.count)").font(WL.caption).foregroundStyle(WL.textDim)
                .padding(.leading, 6)
            Spacer()
            Button { Task { await store.checkAll() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.wlIcon).help(loc("刷新状态", "Refresh statuses"))
            Button(action: onBackup) {
                Image(systemName: "externaldrive").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.wlIcon).help(loc("备份", "Backup"))
            Button(action: onCollapse) {
                Image(systemName: "sidebar.left").font(.system(size: 12, weight: .medium))
            }.buttonStyle(.wlIcon).help(loc("收起侧边栏", "Collapse sidebar"))
        }
        // The card is inset by the pane gap; clear the traffic lights.
        .padding(.leading, TitleBand.shared.lightsTrailing + 6 - wlPaneGap).padding(.trailing, 8)
        .frame(height: TitleBand.shared.height - wlPaneGap + 6)
        .blocksWindowDrag()   // title-bar band: see WLPageHeader
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(WL.textDim)
            TextField(loc("搜索主机", "Search hosts"), text: $query)
                .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                .focused($searchFocused)
                .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                    searchFocused = true
                }
                .onChange(of: query) { searchHighlight = 0 }
                .onSubmit(connectSearchHighlighted)
                .onKeyPress(.downArrow) {
                    let n = searchResults.count
                    if n > 0 { searchHighlight = min(searchHighlight + 1, n - 1) }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    searchHighlight = max(searchHighlight - 1, 0); return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }.buttonStyle(.wlPlain).foregroundStyle(WL.textDim)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .wlSearchCapsule(focused: searchFocused)
        .animation(Motion.hover, value: query.isEmpty)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    /// A segmented capsule, like the tab bar: one raised pill slides to the
    /// selected section.
    private var functionRow: some View {
        HStack(spacing: 0) {
            FeatureButton(title: "SSH", symbol: "terminal", tint: WL.green,
                          active: operation == nil, pill: segment) { operation = nil }
            FeatureButton(title: loc("端口", "Ports"), symbol: "arrow.left.arrow.right", tint: WL.green,
                          active: operation == .forwarding, pill: segment) { operation = .forwarding }
            FeatureButton(title: loc("文件", "Files"), symbol: "folder", tint: WL.green,
                          active: operation == .files, pill: segment) { operation = .files }
            FeatureButton(title: loc("密钥", "Keys"), symbol: "key", tint: WL.green,
                          active: operation == .keys, pill: segment) { operation = .keys }
        }
        .wlCapsuleTrack()
        .animation(Motion.resolved(Motion.slide), value: operation)
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    @ViewBuilder
    private var hostSections: some View {
        if !trimmed.isEmpty {
            GroupHeader(title: "搜索结果", count: searchResults.count)
            ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, host in
                hostItem(host, highlighted: index == searchHighlight)
            }
            if searchResults.isEmpty {
                Text(loc("  无匹配主机", "  No matching hosts")).font(WL.small).foregroundStyle(WL.textDim)
                    .padding(.horizontal, 16).padding(.top, 4)
            }
        } else {
            ForEach(store.groups, id: \.self) { group in
                groupSection(title: group, hosts: store.hosts(inGroup: group),
                             onDrop: { store.setGroup(group, for: $0) },
                             onAdd: { onAdd(group) })
            }
            if store.hasUngrouped {
                groupSection(title: "未分组", hosts: store.hosts(inGroup: nil),
                             onDrop: { store.setGroup(nil, for: $0) }, onAdd: nil)
            }
        }
    }

    @ViewBuilder
    private func groupSection(title: String, hosts: [Host],
                              onDrop: @escaping ([String]) -> Void,
                              onAdd: (() -> Void)?) -> some View {
        let isCollapsed = collapsed.contains(title)
        GroupHeader(title: title, count: hosts.count, collapsed: isCollapsed,
                    color: onAdd != nil ? store.groupColors[title]?.color : nil,
                    onToggle: { toggle(title) }, onAdd: onAdd, onDrop: onDrop,
                    menu: groupMenu(title: title, deletable: onAdd != nil, onAdd: onAdd))
        if !isCollapsed {
            ForEach(hosts) { host in
                hostItem(host)
                    .transition(.wlDisclose)
            }
        }
    }

    private func groupMenu(title: String, deletable: Bool, onAdd: (() -> Void)?) -> [WLMenuItem] {
        var menu: [WLMenuItem] = [.item(loc("新建分组…", "New Group…"), systemImage: "plus") { presentNewGroup() }]
        if deletable {
            menu.append(.item(loc("在此新建主机", "New host here"), systemImage: "plus.circle") { onAdd?() })
            // Colour label: marks this group's hosts, tabs and terminals.
            let current = store.groupColors[title]
            var colors: [WLMenuItem] = GroupColor.allCases.map { c in
                .item(c.label, checked: current == c) { store.groupColors[title] = c }
            }
            colors.append(.divider)
            colors.append(.item(loc("无", "None"), checked: current == nil) { store.groupColors[title] = nil })
            menu.append(.submenu(loc("颜色标识", "Colour Label"), systemImage: "paintpalette", colors))
            menu.append(.divider)
            menu.append(.item(loc("删除分组", "Delete Group"), systemImage: "trash", destructive: true) {
                store.deleteGroup(title)
            })
        }
        return menu
    }

    private func toggle(_ group: String) {
        wlAnimate(Motion.disclose) {
            if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        }
        UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups")
    }

    private func connectSearchHighlighted() {
        guard searchResults.indices.contains(searchHighlight) else { return }
        let host = searchResults[searchHighlight]
        selectedAlias = host.alias; operation = nil; connectOrFocus(host)
        query = ""            // clear search after connecting
        searchFocused = false
    }

    private func hostItem(_ host: Host, highlighted: Bool = false) -> some View {
        let active = sessions.activeSession?.alias == host.alias && operation == nil
        return HostItem(
            host: host,
            status: store.statuses[host.alias],
            isActive: active,
            isSelected: highlightedAlias == host.alias || highlighted,
            onSelect: { highlightedAlias = host.alias },
            onDetails: { highlightedAlias = host.alias; selectedAlias = host.alias; operation = nil; sessions.activeID = nil },
            onConnect: { selectedAlias = host.alias; operation = nil; connectOrFocus(host) },
            onEdit: { onEdit(host) },
            onForward: { operation = .forwarding },
            onFiles: { onOpenFiles(host) }
        )
    }

    private func connectOrFocus(_ host: Host) {
        if let existing = sessions.sessions.first(where: { $0.alias == host.alias && sessionIsSSH($0) }) {
            sessions.activeID = existing.id
        } else {
            connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
        }
    }

    private func sessionIsSSH(_ s: TerminalSession) -> Bool {
        if case .ssh = s.kind { return true } else { return false }
    }

    private var bottomBar: some View {
        HStack {
            Button { onAdd(nil) } label: {
                Label(loc("新建主机", "New Host"), systemImage: "plus").font(WL.small.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(WL.green.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.wlPlain).foregroundStyle(WL.green)
            Spacer()
            Button { openWindow(id: "settings") } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
            }.buttonStyle(.wlIcon).help(loc("设置", "Settings"))
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8)
    }
}

// MARK: - Small components

struct FeatureButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let active: Bool
    /// Shared by a segmented row so the selected pill slides between buttons.
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                Text(title).font(WL.small.weight(active ? .semibold : .regular))
            }
            .foregroundStyle(active ? WL.textPrimary : (hover ? WL.textPrimary : WL.textDim))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .wlSegmentPill(active: active, hover: hover, in: pill, id: "segmentPill")
            .contentShape(Capsule())
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
    }
}

/// A small inline action (Copy, Retry, Refresh…). Named for the old
/// `[label]` look; it's now a quiet capsule chip (`.wlChip()`), so every inline
/// action across the app shares the card / capsule language.
struct BracketButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) { self.label = label; self.action = action }
    var body: some View {
        Button(action: action) { Text(label).lineLimit(1) }
            .buttonStyle(.wlChip())
    }
}

/// Themed sheet for creating a new group.
struct NewGroupSheet: View {
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String) -> Void
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        WLSheet(loc("新建分组", "New Group"),
                subtitle: loc("创建后把主机拖进去即可", "Create it, then drag hosts in"),
                symbol: "folder.badge.plus", width: 400, scrolls: false,
                onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("分组名称", "Group name")).font(WL.small).foregroundStyle(WL.textDim)
                TextField("", text: $name,
                          prompt: Text(loc("如 生产环境", "e.g. Production")).foregroundStyle(WL.textDim))
                    .wlField(font: WL.body)
                    .onSubmit(create)
            }
        } footer: {
            Spacer()
            Button(loc("取消", "Cancel")) { dismiss() }
                .buttonStyle(.wlSecondary).keyboardShortcut(.cancelAction)
            Button(loc("创建", "Create"), action: create)
                .buttonStyle(.wlPrimary).keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

struct GroupHeader: View {
    @Environment(Localizer.self) private var loc
    let title: String
    var count: Int = 0
    var collapsed: Bool = false
    var color: Color? = nil
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?
    var onDrop: (([String]) -> Void)?
    var menu: [WLMenuItem] = []
    @State private var targeted = false
    @State private var hover = false

    var body: some View {
        headerRow.applyWLMenu(menu)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if onToggle != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(WL.textDim)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
            }
            if let color { Circle().fill(color).frame(width: 7, height: 7) }
            Text(displayTitle).font(WL.small.weight(.semibold))
                .foregroundStyle(targeted ? WL.green : WL.textDim)
            if count > 0 {
                Text("\(count)").font(WL.caption).foregroundStyle(WL.textDim.opacity(0.7))
                    .contentTransition(.numericText())
                    .animation(Motion.state, value: count)
            }
            Spacer()
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.wlIcon(size: 20))
                .opacity(hover ? 1 : 0)
                .help(loc("在此分组新建主机", "New host in this group"))
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 4)
        .background(background, in: RoundedRectangle(cornerRadius: WL.radius(8), style: .continuous))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
        .wlHover($hover)
        .dropDestination(for: String.self) { aliases, _ in
            onDrop?(aliases); return onDrop != nil
        } isTargeted: { t in if onDrop != nil { withAnimation(Motion.hover) { targeted = t } } }
    }

    private var displayTitle: String {
        switch title {
        case "未分组": return loc("未分组", "Ungrouped")
        case "搜索结果": return loc("搜索结果", "Results")
        default: return title
        }
    }

    private var background: Color {
        WL.green.opacity(targeted ? 0.14 : 0)
    }
}

/// Bottom-center capsule announcing a config reload (or its problems).
private struct ConfigToast: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        VStack {
            Spacer()
            if let t = config.toast {
                HStack(spacing: 8) {
                    Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.isError ? WL.amber : WL.green)
                    Text(t.text).font(WL.small).foregroundStyle(WL.textPrimary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .wlFloating(Capsule(style: .continuous), fill: WL.bg.opacity(0.96), shadow: 0.25, radius: 12, y: 4)
                .padding(.bottom, 44)
                .transition(.wlSlide(.bottom))
                .id(t.id)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// Anything picked in the host drawer that changes what the main area shows —
/// an open host's tab, a host's details, a tool (ports / files / keys) — puts
/// the drawer away, so you never close it yourself. Searching, folding groups
/// and context menus leave it open. (A modifier to keep `ContentView.body`
/// within the type-checker's budget.)
private struct DrawerAutoClose: ViewModifier {
    let activeTab: UUID?
    let selectedAlias: String?
    let operation: SidebarItem?
    let close: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: activeTab) { _, new in if new != nil { close() } }
            .onChange(of: selectedAlias) { _, new in if new != nil { close() } }
            .onChange(of: operation) { _, _ in close() }
    }
}
