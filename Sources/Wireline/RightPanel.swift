import SwiftUI
import WirelineCore
import struct SwiftTerm.SearchOptions

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
    // Lifted out of AIPanelView so the ⌘I handler and tab switches can tell
    // whether the panel currently holds keyboard focus, and grab it if not.
    @FocusState private var aiFocused: Bool
    // Broadcast bar (type once → send to every session).
    @State private var showBroadcast = false
    @State private var broadcastText = ""
    @FocusState private var broadcastFocused: Bool
    // Terminal scrollback search (⌘F).
    @State private var showSearch = false
    @State private var searchTerm = ""
    @State private var matchIndex = 0
    @State private var matchTotal = 0
    @State private var searchCaseSensitive = false
    @State private var searchRegex = false
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
        .background(WL.bg.opacity(store.terminalOpacity * WL.chromeOpacity))
        .onReceive(NotificationCenter.default.publisher(for: .toggleAI)) { _ in
            guard ai.enabled else { return }
            if showAI {
                // Open but not focused → just focus it (don't hide). Only hide
                // when it already has focus, so ⌘I acts as "bring me to the AI".
                if aiFocused {
                    showAI = false
                    sessions.focusActiveTerminal()
                } else {
                    aiFocused = true
                }
            } else {
                showAI = true   // AIPanelView.onAppear takes focus on appear.
            }
        }
        .onChange(of: sessions.activeID) { _, _ in
            // Switching tab / pane while the AI panel is open keeps focus in the
            // panel — the terminal is built with autoFocus off (see below), so it
            // won't steal first responder, and we re-assert focus on the input.
            if showAI { aiFocused = true }
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
                            onClose: { showAI = false; sessions.focusActiveTerminal() },
                            inputFocused: $aiFocused)
                    // Bind the panel's identity to the conversation (per host; all
                    // local shells share "__local__"). Switching to a *different*
                    // host rebuilds the panel — its onDisappear cancels any in-flight
                    // stream and persists to the right conversation — so a streaming
                    // reply can never bleed into, or be saved under, another host.
                    // Two tabs of the same host keep one instance (shared convo).
                    .id(activeHost?.alias ?? "__local__")
            }
        }
        // The AI panel opens only via its keyboard shortcut (Toggle AI Panel) or
        // the command palette — no floating button. See the `.toggleAI` handler above.
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
                PaneTreeView(node: tab, aiOpen: showAI)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = sessions.activeSession {
                ConnectionInfoBar(session: session)
                Rectangle().fill(WL.border).frame(height: 1)
                TerminalHostView(session: session, autoFocus: !showAI).id(session.id)
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

    private var searchOptions: SearchOptions {
        SearchOptions(caseSensitive: searchCaseSensitive, regex: searchRegex)
    }

    private func terminalSearchBar(_ session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(WL.small).foregroundStyle(WL.textDim)
            TextField(loc("搜索终端…", "Search terminal…"), text: $searchTerm)
                .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                .frame(width: 170).focused($searchFocused)
                // Incremental: jump to the nearest match as you type.
                .onChange(of: searchTerm) { incrementalFind(session) }
                // Return = next, Shift+Return = previous.
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    runFind(session, forward: !press.modifiers.contains(.shift))
                    return .handled
                }
            // Match counter — blank while empty, red on no match.
            Group {
                if searchTerm.isEmpty {
                    EmptyView()
                } else if matchTotal > 0 {
                    Text("\(matchIndex)/\(matchTotal)").font(WL.caption).foregroundStyle(WL.textDim)
                } else {
                    Text(loc("无匹配", "no match")).font(WL.caption).foregroundStyle(WL.red.opacity(0.85))
                }
            }
            .frame(minWidth: 34, alignment: .trailing)
            searchOptionToggle("Aa", isOn: $searchCaseSensitive,
                               help: loc("区分大小写", "Case sensitive"), session: session)
            searchOptionToggle(".*", isOn: $searchRegex,
                               help: loc("正则表达式", "Regular expression"), session: session)
            Divider().frame(height: 14)
            Button { runFind(session, forward: false) } label: {
                Image(systemName: "chevron.up").font(WL.small)
            }.buttonStyle(.plain).disabled(matchTotal == 0)
                .help(loc("上一个 (⇧⏎)", "Previous (⇧⏎)"))
            Button { runFind(session, forward: true) } label: {
                Image(systemName: "chevron.down").font(WL.small)
            }.buttonStyle(.plain).disabled(matchTotal == 0)
                .help(loc("下一个 (⏎)", "Next (⏎)"))
            Button(action: closeSearch) { Image(systemName: "xmark").font(WL.small) }
                .buttonStyle(.plain).help(loc("关闭 (Esc)", "Close (Esc)"))
        }
        .foregroundStyle(WL.textDim)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(8)).stroke(WL.border, lineWidth: WL.borderWidth))
        .padding(8)
        .onExitCommand(perform: closeSearch)
    }

    /// A small "Aa" / ".*" chip that lights up green when its search option is on.
    private func searchOptionToggle(_ label: String, isOn: Binding<Bool>,
                                    help: String, session: TerminalSession) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            incrementalFind(session)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? WL.bg : WL.textDim)
                .frame(width: 22, height: 17)
                .background(isOn.wrappedValue ? WL.green : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn.wrappedValue ? Color.clear : WL.border, lineWidth: WL.borderWidth))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func runFind(_ session: TerminalSession, forward: Bool) {
        guard !searchTerm.isEmpty else { return }
        if forward { session.terminalView.findNext(searchTerm, options: searchOptions) }
        else { session.terminalView.findPrevious(searchTerm, options: searchOptions) }
        updateSummary(session)
    }

    /// Re-run the search from the top as the term or options change, so the
    /// selection and counter update live without pressing Return.
    private func incrementalFind(_ session: TerminalSession) {
        guard !searchTerm.isEmpty else {
            session.terminalView.clearSearch()
            matchIndex = 0; matchTotal = 0
            return
        }
        _ = session.terminalView.findNext(searchTerm, options: searchOptions)
        updateSummary(session)
    }

    private func updateSummary(_ session: TerminalSession) {
        let r = session.terminalView.searchMatchSummary(searchTerm, options: searchOptions)
        matchIndex = r.index; matchTotal = r.total
    }

    private func closeSearch() {
        sessions.activeSession?.terminalView.clearSearch()
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
        // Transparent so the wallpaper / panel translucency reaches the very top,
        // matching the rest of the panel instead of an opaque tab strip.
        .background(.clear)
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
    /// True when this (non-active) tab has a command still running — shows a
    /// "running…" badge so you know it's working while you're on another tab.
    private var running: Bool {
        tab.sessionIDs.contains { sessions.session($0)?.isBusy == true }
    }
    /// True when this (non-active) tab produced output you haven't seen yet — shows
    /// a small "new output" dot. The running badge takes precedence over it.
    private var unread: Bool {
        tab.sessionIDs.contains { sessions.session($0)?.hasUnread == true }
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
            if !isActive && running {
                RunningBadge()
            } else if !isActive && unread {
                UnreadDot()
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

/// A small pulsing "running…" badge shown on a backgrounded tab whose session is
/// still busy, so long jobs (a build, an AI CLI) are visible at a glance.
/// Animated connection-state indicator: a dot that pulses amber while dialing,
/// settles to a softly-glowing green when connected, and turns red on disconnect.
struct ConnectionStatusDot: View {
    let state: ConnectionState
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .connecting:   return WL.amber
        case .connected:    return WL.green
        case .disconnected: return WL.red
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(state == .connecting && pulse ? 0.25 : 1)
            .shadow(color: color.opacity(0.7), radius: state == .connected ? 3 : 0)
            .animation(.easeInOut(duration: 0.3), value: state)
            .onAppear { startPulseIfConnecting() }
            .onChange(of: state) { _, _ in pulse = false; startPulseIfConnecting() }
            .help(label)
    }

    private var label: String {
        let l = Localizer.shared
        switch state {
        case .connecting:   return l.t("连接中…", "Connecting…")
        case .connected:    return l.t("已连接", "Connected")
        case .disconnected: return l.t("已断开", "Disconnected")
        }
    }

    private func startPulseIfConnecting() {
        guard state == .connecting else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// A small green dot marking a backgrounded tab that has produced output you
/// haven't looked at yet.
struct UnreadDot: View {
    var body: some View {
        Circle().fill(WL.green).frame(width: 6, height: 6)
            .overlay(Circle().stroke(WL.bg.opacity(0.4), lineWidth: 1))
            .help(Localizer.shared.t("有新输出", "New output"))
            .transition(.scale.combined(with: .opacity))
    }
}

struct RunningBadge: View {
    @Environment(Localizer.self) private var loc
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(WL.amber).frame(width: 5, height: 5)
                .opacity(pulse ? 0.3 : 1)
            Text(loc("运行中…", "running…")).font(WL.caption).foregroundStyle(WL.amber)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(WL.amber.opacity(0.12), in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
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
            HStack(spacing: 8) {
                ConnectionStatusDot(state: session.connectionState)
                Text(endpoint).font(WL.body).foregroundStyle(endpointColor)
            }
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
        // Transparent so the panel's translucent background (and the wallpaper
        // behind it) shows through here too, instead of an opaque strip.
        .background(.clear)
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
        guard case .ssh(let alias, _, _, _, _) = session.kind else { return session.title }
        if let host { return "\(host.user ?? "root")@\(host.connectHostname)" }
        return alias
    }

    private var endpointColor: Color {
        switch session.connectionState {
        case .connecting:   return WL.amber
        case .connected:    return WL.greenBright
        case .disconnected: return WL.textDim
        }
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
                Text("[\(connLabel)]").font(WL.small).bold()
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
            .background(barColor)
            .animation(.easeInOut(duration: 0.3), value: session.connectionState)
        }
    }

    private var connLabel: String {
        switch session.connectionState {
        case .connecting:   return loc("连接中…", "connecting…")
        case .connected:    return loc("已连接", "connected")
        case .disconnected: return loc("已断开", "disconnected")
        }
    }

    /// The status bar tints itself by connection state — green connected, amber
    /// while dialing, muted red once the link is gone.
    private var barColor: Color {
        switch session.connectionState {
        case .connecting:   return WL.amber
        case .connected:    return WL.green
        case .disconnected: return WL.red.opacity(0.85)
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
