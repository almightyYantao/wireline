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
}

/// Right-panel mode. `nil` = SSH (terminal sessions).
enum SidebarItem: Hashable {
    case forwarding
    case files
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
                if sidebarCollapsed {
                    collapsedSidebarStrip
                } else {
                    LeftPanel(query: $query, operation: $operation, selectedAlias: $selectedAlias,
                              onAdd: { editing = HostEditContext(host: nil, defaultGroup: $0) },
                              onEdit: { editing = HostEditContext(host: $0) },
                              onBackup: { showBackup = true },
                              onOpenFiles: { fileHost = $0; operation = .files },
                              onCollapse: toggleSidebar)
                        .frame(width: 340)
                }
                Rectangle().fill(WL.border).frame(width: 1)
                RightPanel(operation: $operation, fileHost: $fileHost, selectedAlias: $selectedAlias,
                           onEditHost: { editing = HostEditContext(host: $0) },
                           sidebarCollapsed: sidebarCollapsed)
            }
            .ignoresSafeArea()

            if showQuickConnect {
                quickConnectOverlay
            }
        }
        .wlMenuHost()
        .background(WindowAccessor { w in chrome.attach(to: w) })
        .id(palette.version)   // rebuild the tree when the theme recolors the UI
        .preferredColorScheme(.dark)
        .onChange(of: sessions.sessions.count) { old, new in
            // A new session opened (⌘T / quick connect / host connect): jump to
            // the terminal view and auto-collapse the sidebar for more room.
            if new > old {
                operation = nil
                sidebarCollapsed = true
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
        .sheet(item: $editing) { ctx in
            HostEditorView(context: ctx).environment(store)
        }
        .sheet(isPresented: $showBackup) {
            BackupView().environment(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickConnect)) { _ in
            showQuickConnect = true
        }
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

    /// The ⌘K quick-connect palette, as an in-window overlay (not a sheet) so it
    /// never triggers the AppKit title-bar reset / flash.
    private var quickConnectOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showQuickConnect = false }
            QuickConnectView(onClose: { showQuickConnect = false })
                .frame(width: 620, height: 420)
                .background(WL.bg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WL.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
        .transition(.opacity)
    }

    private func toggleSidebar() {
        sidebarCollapsed.toggle()
        UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed")
    }

    /// Thin strip shown when the sidebar is collapsed, with an expand button.
    private var collapsedSidebarStrip: some View {
        VStack(spacing: 0) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(WL.green)
            }
            .buttonStyle(.plain)
            .padding(.top, 34).padding(.bottom, 10)
            .help("展开侧边栏")
            Spacer()
        }
        .frame(width: 34)
        .frame(maxHeight: .infinity)
        .background(WL.bg.opacity(store.terminalOpacity))
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
            Rectangle().fill(WL.border).frame(height: 1)
            functionRow
            Rectangle().fill(WL.border).frame(height: 1)
            ScrollView {
                hostSections
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
                    .contentShape(Rectangle())
                    .wlContextMenuBackground([.item(loc("新建分组…", "New Group…"), systemImage: "plus") { presentNewGroup() }])
            }
            Rectangle().fill(WL.border).frame(height: 1)
            bottomBar
        }
        .background(WL.bg.opacity(store.terminalOpacity))
        .sheet(isPresented: $showNewGroup) {
            NewGroupSheet { name in store.createGroup(name) }
        }
    }

    private func presentNewGroup() { showNewGroup = true }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("> ssh_client").font(WL.title).foregroundStyle(WL.green)
                Spacer()
                BracketButton(loc("刷新", "Refresh")) { Task { await store.checkAll() } }
                BracketButton(loc("备份", "Backup"), action: onBackup)
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(WL.textDim)
                }.buttonStyle(.plain).help(loc("收起侧边栏", "Collapse sidebar"))
            }
            Text(loc("连接管理器 v0.1", "connection manager v0.1")).font(WL.small).foregroundStyle(WL.textDim)
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Text("/").font(WL.body).foregroundStyle(WL.green)
            TextField(loc("搜索连接 ...", "Search hosts ..."), text: $query)
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
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
                    Image(systemName: "xmark").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundStyle(WL.textDim)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var functionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("功能", "FEATURES")).font(WL.caption).foregroundStyle(WL.textDim)
            HStack(spacing: 8) {
                FeatureButton(title: "SSH", symbol: "chevron.right.square", tint: WL.green,
                              active: operation == nil) { operation = nil }
                FeatureButton(title: loc("端口", "Ports"), symbol: "arrow.left.arrow.right", tint: WL.teal,
                              active: operation == .forwarding) { operation = .forwarding }
                FeatureButton(title: loc("文件", "Files"), symbol: "folder", tint: WL.purple,
                              active: operation == .files) { operation = .files }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        withAnimation(.easeInOut(duration: 0.22)) {
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
                Text(loc("$ 新建连接", "$ new host")).font(WL.body).foregroundStyle(WL.green)
            }.buttonStyle(.plain)
            Spacer()
            Button { openWindow(id: "settings") } label: {
                Text("[\(loc("设置", "Settings"))]").font(WL.small).foregroundStyle(WL.textDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(WL.small)
            }
            .foregroundStyle(active ? tint : (hover ? WL.textPrimary : WL.textDim))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(active ? tint.opacity(0.14) : WL.surface.opacity(hover ? 0.7 : 0.4),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(active ? tint.opacity(0.6) : WL.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Themed sheet for creating a new group.
struct NewGroupSheet: View {
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("新建分组", "New Group"))
                .font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(WL.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(loc("分组名称", "Group name")).font(WL.small).foregroundStyle(WL.textDim)
                TextField("", text: $name,
                          prompt: Text(loc("如 生产环境", "e.g. Production")).foregroundStyle(WL.textDim))
                    .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(WL.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(WL.border, lineWidth: 1))
                    .onSubmit(create)
                Text(loc("创建后把主机拖进去即可。", "Create it, then drag hosts in."))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
            .padding(20)

            Spacer()
            Rectangle().fill(WL.border).frame(height: 1)
            HStack(spacing: 18) {
                Spacer()
                BracketButton(loc("取消", "Cancel")) { dismiss() }
                Button(action: create) {
                    Text("[\(loc("创建", "Create"))]").font(WL.small)
                        .foregroundStyle(name.trimmingCharacters(in: .whitespaces).isEmpty ? WL.textDim : WL.green)
                }.buttonStyle(.plain).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .frame(width: 380, height: 240)
        .background(WL.bg)
        .preferredColorScheme(.dark)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 9)).foregroundStyle(WL.green)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 10)
            }
            Text(displayTitle).font(WL.small.weight(.semibold))
                .foregroundStyle(targeted ? WL.greenBright : WL.green)
            if count > 0 {
                Text("\(count)").font(WL.caption).foregroundStyle(WL.textDim)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(WL.bg, in: Capsule())
            }
            Spacer()
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(WL.textDim)
                }
                .buttonStyle(.plain)
                .help("在此分组新建主机")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(WL.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
        .onHover { hover = $0 }
        .dropDestination(for: String.self) { aliases, _ in
            onDrop?(aliases); return onDrop != nil
        } isTargeted: { if onDrop != nil { targeted = $0 } }
    }

    private var displayTitle: String {
        switch title {
        case "未分组": return loc("未分组", "Ungrouped")
        case "搜索结果": return loc("搜索结果", "Results")
        default: return title
        }
    }

    private var background: some ShapeStyle {
        if targeted { return AnyShapeStyle(WL.green.opacity(0.18)) }
        if hover && onToggle != nil { return AnyShapeStyle(WL.surface) }
        return AnyShapeStyle(WL.surface.opacity(0.45))
    }
}
