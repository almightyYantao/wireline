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
    /// Pinned as a column vs floating over the terminal (default).
    @AppStorage("aiDocked") private var aiDocked = false
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
        // Switching tool ↔ terminal cross-fades instead of cutting. Each side
        // mounts at its final size, so the terminal never resizes mid-fade.
        .id(operation)
        .transition(.opacity)
        .animation(Motion.resolved(Motion.fade), value: operation)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WL.bg.opacity(store.terminalOpacity * WL.chromeOpacity))
        .onReceive(NotificationCenter.default.publisher(for: .toggleAI)) { _ in
            guard ai.enabled else { return }
            if showAI {
                // Open but not focused → just focus it (don't hide). Only hide
                // when it already has focus, so ⌘I acts as "bring me to the AI".
                if aiFocused {
                    setAI(false)
                    sessions.focusActiveTerminal()
                } else {
                    aiFocused = true
                }
            } else {
                setAI(true)   // AIPanelView.onAppear takes focus on appear.
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
            wlAnimate(Motion.banner) { showSearch = true }
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var detailHost: Host? {
        selectedAlias.flatMap { alias in store.hosts.first { $0.alias == alias } }
    }

    @ViewBuilder
    private var sessionArea: some View {
        // The AI panel floats over the terminal by default (opening it resizes
        // nothing); pinned, it becomes a column beside it, sliding in while the
        // terminal grid is frozen (see TerminalResizeGate) so it reflows once.
        HStack(spacing: 0) {
            terminalColumn
            if showAI && aiDocked {
                Rectangle().fill(WL.border).frame(width: 1)
                aiPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Unpinned, the panel floats over the terminal: opening it resizes
        // nothing. Pinned, it's a real column (the terminal makes room once).
        .overlay(alignment: .trailing) {
            if showAI && !aiDocked {
                aiPanel
                    .background(WL.bg.opacity(0.94))
                    .overlay(alignment: .leading) { Rectangle().fill(WL.border).frame(width: 1) }
                    .shadow(color: .black.opacity(WL.depth(0.28)), radius: 18, x: -4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The AI panel opens only via its keyboard shortcut (Toggle AI Panel) or
        // the command palette — no floating button. See the `.toggleAI` handler above.
    }

    private var aiPanel: some View {
        AIPanelView(session: sessions.activeSession,
                    host: activeHost,
                    onClose: { setAI(false); sessions.focusActiveTerminal() },
                    inputFocused: $aiFocused,
                    docked: aiDocked,
                    onTogglePin: { wlAnimateTerminalLayout { aiDocked.toggle() } })
            // Bind the panel's identity to the conversation (per host; all
            // local shells share "__local__"), so switching to a *different*
            // host gives it a fresh view with that host's transcript. The
            // conversation itself lives in `AIConvoState`, outside the view,
            // so the rebuild neither loses nor cross-contaminates a reply
            // that's still streaming. Two tabs of one host share the panel.
            .id(activeHost?.alias ?? "__local__")
    }

    /// Open / close the AI panel: a pinned column goes through the terminal
    /// layout freeze; a floating one just slides.
    private func setAI(_ on: Bool) {
        if aiDocked { wlAnimateTerminalLayout { showAI = on } }
        else { wlAnimate(on ? Motion.expand : Motion.popOut) { showAI = on } }
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
                    VStack(spacing: 0) {
                        broadcastBar
                        Rectangle().fill(WL.border).frame(height: 1)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            if let tab = sessions.activeTab, tab.sessionIDs.count > 1 {
                // A merged tab: render its split layout — or just the zoomed pane.
                Group {
                    if let z = sessions.zoomedSession(inTab: tab.id), let leaf = tab.leafID(for: z) {
                        PaneLeafView(paneID: leaf, sessionID: z, aiOpen: showAI, zoomed: true)
                    } else {
                        PaneTreeView(node: tab, aiOpen: showAI)
                    }
                }
                .id(sessions.zoomedSession(inTab: tab.id))
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = sessions.activeSession {
                ConnectionInfoBar(session: session)
                GroupColorRule(alias: session.alias)
                TerminalHostView(session: session, autoFocus: !showAI).id(session.id)
                    .wlTerminalPadding(store)
                    .overlay(alignment: .top) {
                        if showSearch { terminalSearchBar(session) }
                        else if session.connectionState == .disconnected {
                            DisconnectedBanner(session: session)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if session.activeEditor == "vim" { VimHintView() }
                    }
                    .overlay { InlineAICommandView(session: session, isActive: true) }
                    .animation(Motion.banner, value: session.connectionState)
                    .animation(Motion.banner, value: showSearch)
                    .overlay(dropTargeted ? WL.teal.opacity(0.12) : .clear)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { termSize = geo.size }
                            .onChange(of: geo.size) { _, s in termSize = s }
                    })
                    // Drop another tab here (near an edge) to merge it into a
                    // split with this session.
                    .dropDestination(for: String.self) { items, location in
                        guard let str = items.first, let leaf = sessions.activeTab?.anyLeafID else { return false }
                        return dropOntoPane(str, leaf: leaf, edge: paneEdge(for: location, in: termSize),
                                            store: store, sessions: sessions)
                    } isTargeted: { dropTargeted = $0 }
                StatusBar(session: session)
            } else if let host = detailHost {
                HostDetailView(host: host, onEdit: onEditHost, onBack: { selectedAlias = nil })
            } else {
                HostOverview(onEdit: onEditHost,
                             onNew: { NotificationCenter.default.post(name: .newConnection, object: nil) },
                             onFiles: { fileHost = $0; operation = .files },
                             onDetails: { selectedAlias = $0.alias })
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
            wlAnimateTerminalLayout(Motion.disclose, duration: 0.3) { showBroadcast.toggle() }
            if showBroadcast { DispatchQueue.main.async { broadcastFocused = true } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right").font(WL.small)
                Text(loc("广播", "Broadcast")).font(WL.small)
            }
            .foregroundStyle(showBroadcast ? WL.bg : WL.textDim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(showBroadcast ? WL.amber : WL.surface.opacity(0.6), in: Capsule())
            .animation(Motion.state, value: showBroadcast)
        }
        .buttonStyle(.wlPlain)
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
            BracketButton(loc("关闭", "Close")) {
                wlAnimateTerminalLayout(Motion.disclose, duration: 0.3) { showBroadcast = false }
            }
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
            }.buttonStyle(.wlPlain).disabled(matchTotal == 0)
                .help(loc("上一个 (⇧⏎)", "Previous (⇧⏎)"))
            Button { runFind(session, forward: true) } label: {
                Image(systemName: "chevron.down").font(WL.small)
            }.buttonStyle(.wlPlain).disabled(matchTotal == 0)
                .help(loc("下一个 (⏎)", "Next (⏎)"))
            Button(action: closeSearch) { Image(systemName: "xmark").font(WL.small) }
                .buttonStyle(.wlPlain).help(loc("关闭 (Esc)", "Close (Esc)"))
        }
        .foregroundStyle(WL.textDim)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(WL.surface, in: RoundedRectangle(cornerRadius: WL.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(8)).stroke(WL.border, lineWidth: WL.borderWidth))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(8)
        .transition(.wlSlide(.top))
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
        .buttonStyle(.wlPlain)
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
        wlAnimate(Motion.popOut) { showSearch = false }
        searchTerm = ""
        matchIndex = 0; matchTotal = 0
    }
}

// MARK: - Tab bar

struct SessionTabBar: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Environment(Localizer.self) private var loc

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
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.wlIcon)
                .padding(.horizontal, 6)
                .help(loc("新建本地终端", "New local terminal"))
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
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    let index: Int
    let tab: PaneNode
    let isActive: Bool
    @State private var hover = false
    @State private var closeHover = false
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
    /// Tooltip text: the full working-directory path when the shell has reported
    /// one, else the tab title. Lets a short "wireline" tab reveal its full path.
    private var tooltip: String {
        tab.sessionIDs.compactMap { sessions.session($0).map { $0.currentDirectory ?? $0.title } }
            .joined(separator: " | ")
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
            if let label = tab.sessionIDs.lazy.compactMap({ sessions.session($0) })
                .compactMap({ store.groupColor(forAlias: $0.alias) }).first {
                Circle().fill(label.color).frame(width: 6, height: 6)
            }
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
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(closeHover ? WL.textPrimary : WL.textDim)
                    .frame(width: 16, height: 16)
                    .background(WL.textPrimary.opacity(closeHover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: WL.radius(4)))
            }.buttonStyle(.wlPlain)
            .wlHover($closeHover)
            .opacity(hover || isActive ? 1 : 0)
            .help(loc("关闭标签", "Close tab"))
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 9)
        .background(isActive ? WL.surface.opacity(0.7) : (hover ? WL.textPrimary.opacity(0.04) : .clear))
        .overlay(alignment: .bottom) {
            Capsule().fill(WL.green).frame(height: 2).padding(.horizontal, 10).opacity(isActive ? 1 : 0)
        }
        .animation(Motion.state, value: isActive)
        .animation(Motion.state, value: running)
        .animation(Motion.state, value: unread)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isEditing, soleSession != nil { beginEdit() } })
        .simultaneousGesture(TapGesture(count: 1).onEnded { if !isEditing { sessions.focusTab(tab.id) } })
        // Drag this tab onto another tab's pane to merge them into a split.
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .wlHover($hover) { TitleBarZoomGuard.shared.pointerInNoZoomZone = $0 }
        .help(tooltip)
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

    private var color: Color {
        switch state {
        case .connecting:   return WL.amber
        case .connected:    return WL.green
        case .disconnected: return WL.red
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .wlPulse(state == .connecting, period: 0.7, low: 0.25)
            .shadow(color: color.opacity(0.7), radius: state == .connected ? 3 : 0)
            .animation(Motion.state, value: state)
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
}

/// A small green dot marking a backgrounded tab that has produced output you
/// haven't looked at yet.
struct UnreadDot: View {
    var body: some View {
        Circle().fill(WL.green).frame(width: 6, height: 6)
            .overlay(Circle().stroke(WL.bg.opacity(0.4), lineWidth: 1))
            .help(Localizer.shared.t("有新输出", "New output"))
            .transition(.wlBadge)
    }
}

struct RunningBadge: View {
    @Environment(Localizer.self) private var loc

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(WL.amber).frame(width: 5, height: 5)
                .wlPulse(period: 0.8)
            Text(loc("运行中…", "running…")).font(WL.caption).foregroundStyle(WL.amber)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(WL.amber.opacity(0.12), in: Capsule())
        .transition(.wlBadge)
    }
}

// MARK: - Disconnected banner

/// A floating notice shown over a terminal whose link has dropped (or whose shell
/// exited), offering a one-click reconnect. Discoverable where the connection
/// info bar's `[重连]` button isn't visible — split panes, and at a glance.
struct DisconnectedBanner: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(WL.red).frame(width: 6, height: 6)
            Text(loc("连接已断开", "Connection closed"))
                .font(WL.small).foregroundStyle(WL.textPrimary)
            Button(action: session.reconnect) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(WL.small)
                    Text(loc("重新连接", "Reconnect")).font(WL.small.weight(.semibold))
                }
            }
            .buttonStyle(.wlPill(WL.green))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(WL.border, lineWidth: WL.borderWidth))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.top, 10)
        .transition(.wlSlide(.top))
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
        HStack(spacing: 10) {
            ConnectionStatusDot(state: session.connectionState)
            Text(endpoint).font(WL.small.weight(.medium)).foregroundStyle(endpointColor)
                .lineLimit(1).truncationMode(.middle)
            Text(meta).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
                .contentTransition(.numericText())
                .animation(Motion.state, value: latency)
            Spacer()
            HStack(spacing: 2) {
                recordButton
                Button { showSnippets = true } label: {
                    Image(systemName: "text.badge.plus").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.wlIcon).help(loc("片段", "Snippets"))
                Button(action: reconnect) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.wlIcon).help(loc("重新连接", "Reconnect"))
                Button { sessions.close(session.id) } label: {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.wlIcon).help(loc("断开", "Disconnect"))
            }
        }
        .padding(.leading, 18).padding(.trailing, 10).frame(height: 34)
        // Transparent so the panel's translucent background (and the wallpaper
        // behind it) shows through here too, instead of an opaque strip.
        .background(.clear)
        .sheet(isPresented: $showSnippets) {
            SnippetsSheet { command in session.terminalView.send(txt: command + "\n") }
        }
    }

    /// "SSH-2 · :2222 · 23 ms" — quiet metadata after the endpoint.
    private var meta: String {
        // A local shell has no protocol or latency — show where it is instead.
        guard case .ssh = session.kind else {
            return session.currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        }
        var parts = ["SSH-2"]
        if let host, host.effectivePort != 22 { parts.append(":\(host.effectivePort)") }
        parts.append(latency)
        return parts.joined(separator: " · ")
    }

    /// Toggle output logging. While recording the icon turns red and pulses;
    /// stopping reveals the log in Finder.
    private var recordButton: some View {
        Button {
            let wasLogging = session.isLogging
            session.toggleLogging()
            if wasLogging, let url = session.logURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            Image(systemName: session.isLogging ? "record.circle.fill" : "record.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.isLogging ? WL.red : WL.textDim)
                .wlPulse(session.isLogging, period: 1.0, low: 0.45)
        }
        .buttonStyle(.wlIcon(tint: session.isLogging ? WL.red : nil))
        .help(session.isLogging ? loc("停止录制并在访达中显示", "Stop recording and reveal in Finder")
                                : loc("把本会话输出录制到日志文件", "Record this session's output to a log file"))
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
        if case .online(let ms)? = store.statuses[session.alias] { return "\(ms) ms" }
        return "-- ms"
    }

    /// Relaunch the PTY in place — keeps the scrollback and tab, and works for
    /// local shells / SFTP too (unlike a close-and-reopen, which needs a host).
    private func reconnect() { session.reconnect() }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession

    private var isSSH: Bool { if case .ssh = session.kind { return true } else { return false } }

    var body: some View {
        let stats = session.stats.stats
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(barColor).frame(width: 6, height: 6)
                    Text(connLabel).foregroundStyle(WL.textPrimary)
                }
                if isSSH {
                    metric("CPU", stats.cpuPercent.map { String(format: "%.0f%%", $0) })
                    metric("MEM", stats.memPercent.map { p in
                        stats.memTotalGB.map { String(format: "%.0f%% / %.1fG", p, $0) }
                            ?? String(format: "%.0f%%", p)
                    })
                }
                Spacer()
                if isSSH, let t = stats.remoteTime { Text(loc("远端 \(t)", "remote \(t)")) }
                Text(elapsed(to: ctx.date))
            }
            .font(WL.caption).monospacedDigit()
            .foregroundStyle(WL.textDim)
            .padding(.horizontal, 18).frame(height: 24)
            .overlay(alignment: .top) { Rectangle().fill(WL.border.opacity(0.5)).frame(height: 1) }
            .animation(Motion.state, value: session.connectionState)
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
        case .disconnected: return WL.red
        }
    }

    private func metric(_ key: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text(key)
            Text(value ?? "--").foregroundStyle(WL.textPrimary.opacity(0.85))
        }
    }

    private func elapsed(to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(session.startedAt)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Idle / tool containers

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
            WLPageHeader(title)
            Rectangle().fill(WL.border.opacity(0.6)).frame(height: 1)
            content
        }
    }
}

/// The line under a terminal's header: a 2pt band in the host group's colour
/// label (red = production …), else the usual hairline.
struct GroupColorRule: View {
    @Environment(HostStore.self) private var store
    let alias: String
    var body: some View {
        if let c = store.groupColor(forAlias: alias) {
            Rectangle().fill(c.color).frame(height: 2)
        } else {
            Rectangle().fill(WL.border).frame(height: 1)
        }
    }
}
