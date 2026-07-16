import SwiftUI
import WirelineCore

/// The right side: batch/forwarding tools when an operation is selected,
/// otherwise the terminal session area (tabs · connection info · terminal ·
/// status bar), or an idle console when nothing is connected.
struct RightPanel: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    @Binding var operation: SidebarItem?
    @Binding var fileHost: Host?
    @Binding var selectedAlias: String?
    var onEditHost: (Host) -> Void = { _ in }
    /// When the sidebar is collapsed the tab bar sits near the window's left edge;
    /// inset it so the first tab clears the traffic-light buttons.
    var sidebarCollapsed: Bool = false
    @State private var ai = AIConfig.shared
    @State private var showAI = false
    // Draggable position of the floating AI button (persisted; offset from the
    // bottom-right corner so it never has to block the command bar).
    @AppStorage("aiButtonX") private var aiBtnX = 0.0
    @AppStorage("aiButtonY") private var aiBtnY = 0.0
    @State private var aiDrag = CGSize.zero
    // Broadcast bar (type once → send to every session).
    @State private var showBroadcast = false
    @State private var broadcastText = ""
    @FocusState private var broadcastFocused: Bool
    // Terminal scrollback search (⌘F).
    @State private var showSearch = false
    @State private var searchTerm = ""
    @State private var matchIndex = 0
    @State private var matchTotal = 0
    @FocusState private var searchFocused: Bool
    // Highlight the single-session terminal while a tab is dragged over it.
    @State private var dropTargeted = false
    @State private var termSize: CGSize = .zero

    // When the sidebar is collapsed a tool header sits near the window's left
    // edge; inset it so its title clears the traffic-light buttons.
    private var headerInset: CGFloat { sidebarCollapsed ? 52 : 0 }

    var body: some View {
        Group {
            switch operation {
            case .forwarding:
                ToolContainer(title: loc("端口转发", "Port Forwarding"), leadingInset: headerInset) { PortForwardView() }
            case .files:
                if let host = fileHost {
                    ToolContainer(title: loc("文件 · \(host.alias)", "Files · \(host.alias)"), leadingInset: headerInset) {
                        FileBrowserView(host: host) { operation = nil; fileHost = nil }
                    }
                } else {
                    ToolContainer(title: loc("文件 (SFTP)", "Files (SFTP)"), leadingInset: headerInset) { FilesPicker(onPick: { fileHost = $0 }) }
                }
            case .keys:
                ToolContainer(title: loc("SSH 密钥", "SSH Keys"), leadingInset: headerInset) { KeyManagerView() }
            case .none:
                sessionArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WL.bg.opacity(store.terminalOpacity))
        .onReceive(NotificationCenter.default.publisher(for: .toggleAI)) { _ in
            if ai.enabled { showAI.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTerminal)) { _ in
            sessions.focusActiveTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusNextPane)) { _ in
            sessions.focusNextPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPrevPane)) { _ in
            sessions.focusPreviousPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchTerminal)) { _ in
            guard sessions.activeSession != nil else { return }
            showSearch = true
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var detailHost: Host? {
        selectedAlias.flatMap { alias in store.hosts.first { $0.alias == alias } }
    }

    @ViewBuilder
    private var sessionArea: some View {
        // AI panel sits BESIDE the terminal (a real column that shrinks the
        // terminal), not on top of it — so its translucent background reveals the
        // wallpaper, never the terminal underneath. No width animation, so the
        // terminal reflows exactly once (no garbling).
        HStack(spacing: 0) {
            terminalColumn
            if showAI {
                Rectangle().fill(WL.border).frame(width: 1)
                AIPanelView(session: sessions.activeSession,
                            host: activeHost,
                            onClose: { showAI = false })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if ai.enabled && !showAI {
                Image(systemName: "sparkles")
                    .font(.system(size: 14)).foregroundStyle(WL.green)
                    .frame(width: 36, height: 36)
                    .background(WL.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(WL.green.opacity(0.5), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .padding(14)
                    .offset(x: aiBtnX + aiDrag.width, y: aiBtnY + aiDrag.height)
                    // Drag follows the cursor live (minimumDistance 1 so a plain
                    // click still opens the panel); tap opens.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { aiDrag = $0.translation }
                            .onEnded { aiBtnX += $0.translation.width; aiBtnY += $0.translation.height; aiDrag = .zero }
                    )
                    .onTapGesture { showAI = true }
                    .help(loc("AI 助手（可拖动）", "AI Assistant (drag to move)"))
            }
        }
    }

    @ViewBuilder
    private var terminalColumn: some View {
        VStack(spacing: 0) {
            if !sessions.sessions.isEmpty {
                // A thin strip in the window's title-bar region: dragging here
                // moves the window, which keeps the tab bar below it in normal
                // content territory so a tab's `.onDrag` isn't stolen as a move.
                Color.clear.frame(height: 28).frame(maxWidth: .infinity)
                SessionTabBar()
                    .padding(.leading, sidebarCollapsed ? 52 : 0)
                    .overlay(alignment: .trailing) { broadcastToggle.padding(.trailing, 8) }
                Rectangle().fill(WL.border).frame(height: 1)
                if showBroadcast {
                    broadcastBar
                    Rectangle().fill(WL.border).frame(height: 1)
                }
            }
            if let tab = sessions.activeTab, tab.sessionIDs.count > 1 {
                // A merged tab: render its split layout.
                PaneTreeView(node: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = sessions.activeSession {
                ConnectionInfoBar(session: session)
                Rectangle().fill(WL.border).frame(height: 1)
                TerminalHostView(session: session).id(session.id)
                    .overlay(alignment: .top) {
                        if showSearch { terminalSearchBar(session) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if session.activeEditor == "vim" { VimHintView() }
                    }
                    .overlay(dropTargeted ? WL.teal.opacity(0.12) : .clear)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { termSize = geo.size }
                            .onChange(of: geo.size) { _, s in termSize = s }
                    })
                    // Drop another tab here (near an edge) to merge it into a
                    // split with this session.
                    .dropDestination(for: String.self) { items, location in
                        guard let str = items.first, let draggedTab = UUID(uuidString: str),
                              let leaf = sessions.activeTab?.anyLeafID else { return false }
                        sessions.mergeTab(draggedTab, ontoLeaf: leaf,
                                          edge: paneEdge(for: location, in: termSize))
                        return true
                    } isTargeted: { dropTargeted = $0 }
                if ai.enabled {
                    Rectangle().fill(WL.border).frame(height: 1)
                    SuggestionBar(session: session, host: activeHost)
                }
                StatusBar(session: session)
            } else if let host = detailHost {
                HostDetailView(host: host, onEdit: onEditHost)
            } else {
                IdleConsole()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The host backing the active session, for AI context.
    private var activeHost: Host? {
        guard let alias = sessions.activeSession?.alias, !alias.isEmpty else { return nil }
        return store.hosts.first { $0.alias == alias }
    }

    // MARK: - Broadcast

    private var broadcastToggle: some View {
        Button {
            showBroadcast.toggle()
            if showBroadcast { DispatchQueue.main.async { broadcastFocused = true } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right").font(WL.small)
                Text(loc("广播", "Broadcast")).font(WL.small)
            }
            .foregroundStyle(showBroadcast ? WL.bg : WL.textDim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(showBroadcast ? WL.amber : WL.surface.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(loc("广播输入到所有会话", "Broadcast input to all sessions"))
    }

    private var broadcastBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(WL.amber).font(WL.small)
            TextField(loc("发送到全部 \(sessions.sessions.count) 个会话，回车发送…",
                          "Send to all \(sessions.sessions.count) sessions, Return to send…"),
                      text: $broadcastText)
                .textFieldStyle(.plain).font(WL.body).foregroundStyle(WL.textPrimary)
                .focused($broadcastFocused)
                .onSubmit(sendBroadcast)
            BracketButton(loc("发送", "Send"), action: sendBroadcast)
            BracketButton(loc("关闭", "Close")) { showBroadcast = false }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(WL.amber.opacity(0.12))
    }

    private func sendBroadcast() {
        let text = broadcastText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sessions.broadcast(text + "\n")
        broadcastText = ""
    }


    // MARK: - Terminal search

    private func terminalSearchBar(_ session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(WL.small).foregroundStyle(WL.textDim)
            TextField(loc("搜索终端…", "Search terminal…"), text: $searchTerm)
                .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                .frame(width: 200).focused($searchFocused)
                .onSubmit { runFind(session, forward: true) }
                .onChange(of: searchTerm) { updateSummary(session) }
            Text(matchTotal > 0 ? "\(matchIndex)/\(matchTotal)" : loc("无匹配", "no match"))
                .font(WL.caption).foregroundStyle(WL.textDim)
            Button { runFind(session, forward: false) } label: {
                Image(systemName: "chevron.up").font(WL.small)
            }.buttonStyle(.plain)
            Button { runFind(session, forward: true) } label: {
                Image(systemName: "chevron.down").font(WL.small)
            }.buttonStyle(.plain)
            Button(action: closeSearch) { Image(systemName: "xmark").font(WL.small) }.buttonStyle(.plain)
        }
        .foregroundStyle(WL.textDim)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(WL.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WL.border, lineWidth: 1))
        .padding(8)
        .onExitCommand(perform: closeSearch)
    }

    private func runFind(_ session: TerminalSession, forward: Bool) {
        guard !searchTerm.isEmpty else { return }
        if forward { session.terminalView.findNext(searchTerm) }
        else { session.terminalView.findPrevious(searchTerm) }
        updateSummary(session)
    }

    private func updateSummary(_ session: TerminalSession) {
        let r = session.terminalView.searchMatchSummary(searchTerm)
        matchIndex = r.index; matchTotal = r.total
    }

    private func closeSearch() {
        showSearch = false
        searchTerm = ""
        matchIndex = 0; matchTotal = 0
    }
}

// MARK: - Tab bar

struct SessionTabBar: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { index, tab in
                    SessionTab(index: index + 1, tab: tab,
                               isActive: sessions.activeTabID == tab.id)
                }
                Button {
                    openLocalShell(sessions: sessions, openWindow: openWindow)
                } label: {
                    Text("+").font(WL.mono(15)).foregroundStyle(WL.textDim)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }.buttonStyle(.plain)
                Spacer()
            }
        }
        .frame(height: 36)
        .background(WL.bg)
        .blocksWindowDrag()
    }
}

/// One tab = a pane group. A single-session tab shows its title (and supports
/// inline rename); a merged tab shows its sessions' titles joined and a split
/// glyph. Dragging a tab onto another tab's pane merges them.
struct SessionTab: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    let index: Int
    let tab: PaneNode
    let isActive: Bool
    @State private var hover = false
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// The single session in a leaf tab (nil for a merged/group tab).
    private var soleSession: UUID? {
        tab.sessionIDs.count == 1 ? tab.sessionIDs.first : nil
    }
    private var title: String {
        tab.sessionIDs.compactMap { sessions.session($0)?.title }.joined(separator: " | ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)").font(WL.small.weight(.semibold))
                .foregroundStyle(isActive ? WL.green : WL.textDim.opacity(0.7))
            if tab.sessionIDs.count > 1 {
                Image(systemName: "rectangle.split.2x1").font(WL.small).foregroundStyle(WL.teal)
            }
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.greenBright)
                    .frame(minWidth: 40, maxWidth: 160).fixedSize(horizontal: true, vertical: false)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: focused) { _, f in if !f { commit() } }
            } else {
                Text(title).font(WL.small)
                    .foregroundStyle(isActive ? WL.greenBright : WL.textDim).lineLimit(1)
            }
            Button { closeTab() } label: {
                Text("[x]").font(WL.small)
                    .foregroundStyle(hover ? WL.red : WL.textDim.opacity(0.7))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(isActive ? WL.surface : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WL.green).frame(height: 2).opacity(isActive ? 1 : 0)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isEditing, soleSession != nil { beginEdit() } })
        .simultaneousGesture(TapGesture(count: 1).onEnded { if !isEditing { sessions.focusTab(tab.id) } })
        // Drag this tab onto another tab's pane to merge them into a split.
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onHover { hover = $0; TitleBarZoomGuard.shared.pointerInNoZoomZone = $0 }
        .help(title)
        .contextMenu {
            if soleSession != nil { Button(loc("重命名…", "Rename…")) { beginEdit() } }
            Button(loc("关闭", "Close"), role: .destructive) { closeTab() }
        }
    }

    private func closeTab() {
        for s in tab.sessionIDs { sessions.close(s) }
    }

    private func beginEdit() {
        guard let sid = soleSession else { return }
        draft = sessions.session(sid)?.title ?? ""
        isEditing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard isEditing, let sid = soleSession else { isEditing = false; return }
        sessions.rename(sid, to: draft)
        isEditing = false
    }

    private func cancel() { isEditing = false }
}

// MARK: - Connection info bar

struct ConnectionInfoBar: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    let session: TerminalSession
    @State private var showSnippets = false

    private var host: Host? { store.hosts.first { $0.alias == session.alias } }

    var body: some View {
        HStack(spacing: 18) {
            Text(endpoint).font(WL.body).foregroundStyle(WL.greenBright)
            if let host {
                info(loc("端口", "Port"), String(host.effectivePort))
            }
            info(loc("协议", "Protocol"), "SSH-2")
            info(loc("延迟", "Latency"), latency)
            Spacer()
            logButton
            BracketButton(loc("片段", "Snippets")) { showSnippets = true }
            BracketButton(loc("断开", "Disconnect")) { sessions.close(session.id) }
            BracketButton(loc("重连", "Reconnect")) { reconnect() }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(WL.bg)
        .sheet(isPresented: $showSnippets) {
            SnippetsSheet { command in session.terminalView.send(txt: command + "\n") }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(spacing: 5) {
            Text("\(k):").font(WL.small).foregroundStyle(WL.textDim)
            Text(v).font(WL.small).foregroundStyle(WL.textPrimary)
        }
    }

    /// Toggle output logging; when a log exists, right-click / long items reveal it.
    @ViewBuilder private var logButton: some View {
        if session.isLogging {
            Button {
                session.toggleLogging()
                if let url = session.logURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Text("[● \(loc("录制中", "recording"))]").font(WL.small).foregroundStyle(WL.red)
            }
            .buttonStyle(.plain)
            .help(loc("停止录制并在访达中显示", "Stop recording and reveal in Finder"))
        } else {
            BracketButton(loc("录制", "Record")) { session.toggleLogging() }
                .help(loc("把本会话输出录制到日志文件", "Record this session's output to a log file"))
        }
    }

    private var endpoint: String {
        guard case .ssh(let alias, _, _, _) = session.kind else { return session.title }
        if let host { return "\(host.user ?? "root")@\(host.connectHostname)" }
        return alias
    }

    private var latency: String {
        if case .online(let ms)? = store.statuses[session.alias] { return "\(ms)ms" }
        return "--"
    }

    private func reconnect() {
        guard let host else { return }
        sessions.close(session.id)
        connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession

    private var isSSH: Bool { if case .ssh = session.kind { return true } else { return false } }

    var body: some View {
        let stats = session.stats.stats
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 16) {
                Text(session.isRunning ? "[\(loc("已连接", "connected"))]" : "[\(loc("已断开", "disconnected"))]").font(WL.small).bold()
                Text("SSH-2").font(WL.small)
                if isSSH {
                    metric("CPU", stats.cpuPercent.map { String(format: "%.0f%%", $0) })
                    metric("MEM", stats.memPercent.map { p in
                        stats.memTotalGB.map { String(format: "%.0f%% / %.1fG", p, $0) }
                            ?? String(format: "%.0f%%", p)
                    })
                }
                Spacer()
                if isSSH, let t = stats.remoteTime { Text(loc("远端 \(t)", "remote \(t)")).font(WL.small) }
                Text(loc("时长 \(elapsed(to: ctx.date))", "up \(elapsed(to: ctx.date))")).font(WL.small)
            }
            .foregroundStyle(WL.bg)
            .padding(.horizontal, 18).padding(.vertical, 5)
            .background(WL.green)
        }
    }

    private func metric(_ key: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text("\(key):").font(WL.small).bold()
            Text(value ?? "--").font(WL.small)
        }
    }

    private func elapsed(to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(session.startedAt)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Idle / tool containers

struct IdleConsole: View {
    @Environment(Localizer.self) private var loc
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("> wireline").font(WL.mono(22, .bold)).foregroundStyle(WL.green)
            Text(loc("未连接", "Not connected")).font(WL.body).foregroundStyle(WL.textDim)
            Text(loc("选择左侧主机连接，或按 ⌘K 快速连接，⌘T 打开本地终端。",
                     "Pick a host on the left, or press ⌘K to quick-connect, ⌘T for a local terminal."))
                .font(WL.body).foregroundStyle(WL.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(.clear)
    }
}

/// A panel to pick a host and open its visual SFTP file browser. Single click
/// selects a row; double click opens it.
struct FilesPicker: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    var onPick: (Host) -> Void
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("双击主机打开文件浏览器：", "Double-click a host to open its file browser:"))
                .font(WL.body).foregroundStyle(WL.textDim)
                .padding(.horizontal, 18).padding(.vertical, 12)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.hosts) { host in
                        HStack(spacing: 10) {
                            Image(systemName: "folder").foregroundStyle(WL.purple)
                            Text(host.alias).font(WL.body)
                                .foregroundStyle(selected == host.alias ? WL.greenBright : WL.textPrimary)
                            Text(host.connectionSummary).font(WL.caption).foregroundStyle(WL.textDim)
                            Spacer()
                        }
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == host.alias ? WL.green.opacity(0.16) : .clear)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(WL.green).frame(width: 2)
                                .opacity(selected == host.alias ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onPick(host) })
                        .simultaneousGesture(TapGesture(count: 1).onEnded { selected = host.alias })
                    }
                }
            }
        }
    }
}

/// Placeholder for features still in progress.
struct ComingSoon: View {
    @Environment(Localizer.self) private var loc
    let feature: String
    var body: some View {
        VStack(spacing: 8) {
            Text(feature).font(WL.mono(18, .bold)).foregroundStyle(WL.textDim)
            Text(loc("即将支持", "Coming soon")).font(WL.body).foregroundStyle(WL.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wraps the batch / forwarding views with a themed header.
struct ToolContainer<Content: View>: View {
    let title: String
    var leadingInset: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                .padding(.leading, 18 + leadingInset).padding(.trailing, 18).padding(.vertical, 12)
            Rectangle().fill(WL.border).frame(height: 1)
            content
        }
    }
}
