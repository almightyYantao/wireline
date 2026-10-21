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
    @State private var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
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
            HStack(spacing: 0) {
                // A drawer: the panel stays mounted at its full 340pt and slides
                // under a clip whose width animates, so its contents never re-lay
                // out mid-animation (and search text / scroll position survive).
                ZStack(alignment: .leading) {
                    collapsedSidebarStrip
                        .opacity(sidebarCollapsed ? 1 : 0)
                        .allowsHitTesting(sidebarCollapsed)
                    LeftPanel(query: $query, operation: $operation, selectedAlias: $selectedAlias,
                              onAdd: { editing = HostEditContext(host: nil, defaultGroup: $0) },
                              onEdit: { editing = HostEditContext(host: $0) },
                              onBackup: { showBackup = true },
                              onOpenFiles: { fileHost = $0; operation = .files },
                              onCollapse: toggleSidebar)
                        .frame(width: 340)
                        .offset(x: sidebarCollapsed ? -340 : 0)
                        .opacity(sidebarCollapsed ? 0 : 1)
                        .allowsHitTesting(!sidebarCollapsed)
                        .accessibilityHidden(sidebarCollapsed)
                }
                .frame(width: sidebarCollapsed ? 34 : 340, alignment: .leading)
                // One tint for the whole drawer, constant through the animation.
                // If the panel and strip each carried their own, the panel's fade
                // and the gap between its sliding edge and the shrinking clip
                // would let the undimmed wallpaper flash through.
                .background(WL.bg.opacity(store.terminalOpacity * WL.chromeOpacity))
                .clipped()
                Rectangle().fill(WL.border).frame(width: 1)
                RightPanel(operation: $operation, fileHost: $fileHost, selectedAlias: $selectedAlias,
                           onEditHost: { editing = HostEditContext(host: $0) },
                           sidebarCollapsed: sidebarCollapsed)
            }
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
                if !sidebarCollapsed { wlAnimateTerminalLayout { sidebarCollapsed = true } }
                UserDefaults.standard.set(true, forKey: "sidebarCollapsed")
            }
        }
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
                    QuickConnectView(onClose: { wlAnimate(Motion.modalOut) { showQuickConnect = false } })
                }
            }
            if showCommandPalette {
                scrim { wlAnimate(Motion.modalOut) { showCommandPalette = false } }
                modalCard(width: 640, height: 460) {
                    CommandPaletteView(onClose: { wlAnimate(Motion.modalOut) { showCommandPalette = false } })
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
        content()
            .frame(width: width, height: height)
            .background(WL.bg, in: RoundedRectangle(cornerRadius: WL.radius(12)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(12)).stroke(WL.border, lineWidth: WL.borderWidth))
            .clipShape(RoundedRectangle(cornerRadius: WL.radius(12)))
            .shadow(color: .black.opacity(WL.depth(0.5)), radius: 24, y: 8)
            .transition(.wlModal)
    }

    private func toggleSidebar() {
        // The sidebar's width resizes the terminal: animate the layout with the
        // terminal grid frozen, then reflow it exactly once at the end.
        wlAnimateTerminalLayout { sidebarCollapsed.toggle() }
        UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed")
    }

    /// Thin strip shown when the sidebar is collapsed, with an expand button.
    private var collapsedSidebarStrip: some View {
        VStack(spacing: 0) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left").font(.system(size: 13))
            }
            .buttonStyle(.wlIcon(tint: WL.green, size: 26))
            .padding(.top, 30).padding(.bottom, 10)
            .help("展开侧边栏")
            Spacer()
        }
        .frame(width: 34)
        .frame(maxHeight: .infinity)
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
        .padding(.leading, 84).padding(.trailing, 10)
        .frame(height: 52)
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
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(WL.textPrimary.opacity(searchFocused ? 0.07 : 0.045),
                    in: RoundedRectangle(cornerRadius: WL.radius(7)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(7))
            .stroke(WL.green.opacity(searchFocused ? 0.6 : 0), lineWidth: 1))
        .animation(Motion.hover, value: searchFocused)
        .animation(Motion.hover, value: query.isEmpty)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var functionRow: some View {
        HStack(spacing: 4) {
            FeatureButton(title: "SSH", symbol: "terminal", tint: WL.green,
                          active: operation == nil) { operation = nil }
            FeatureButton(title: loc("端口", "Ports"), symbol: "arrow.left.arrow.right", tint: WL.green,
                          active: operation == .forwarding) { operation = .forwarding }
            FeatureButton(title: loc("文件", "Files"), symbol: "folder", tint: WL.green,
                          active: operation == .files) { operation = .files }
            FeatureButton(title: loc("密钥", "Keys"), symbol: "key", tint: WL.green,
                          active: operation == .keys) { operation = .keys }
        }
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
            isSelected: selectedAlias == host.alias || highlighted,
            onSelect: { selectedAlias = host.alias; operation = nil; sessions.activeID = nil },
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
                Label(loc("新建主机", "New Host"), systemImage: "plus").font(WL.small)
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                Text(title).font(WL.small.weight(active ? .semibold : .regular))
            }
            .foregroundStyle(active ? tint : (hover ? WL.textPrimary : WL.textDim))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(active ? tint.opacity(0.13) : WL.textPrimary.opacity(hover ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: WL.radius(6)))
            .animation(Motion.state, value: active)
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
    }
}

struct BracketButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) { self.label = label; self.action = action }
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text("[\(label)]").font(WL.small)
                .foregroundStyle(hover ? WL.greenBright : WL.textDim)
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
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
        .background(background, in: RoundedRectangle(cornerRadius: WL.radius(6)))
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
        targeted ? WL.green.opacity(0.14) : .clear
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
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(WL.border.opacity(0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.bottom, 44)
                .transition(.wlSlide(.bottom))
                .id(t.id)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}
