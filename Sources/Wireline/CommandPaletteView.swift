import SwiftUI
import WirelineCore

/// One runnable entry in the command palette.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String? = nil
    let category: String
    let systemImage: String
    let tint: Color
    /// Shown instead of the category (a host's status / latency).
    var badge: (text: String, color: Color)? = nil
    let run: () -> Void
}

/// One bar for everything (Raycast-style). Typing searches hosts — Return
/// connects — followed by matching actions; a leading ">" searches only
/// commands (actions, snippets, themes). ⌘K opens it empty, ⌘P opens it with
/// ">". ↑/↓ to move, Return to run, Esc to close.
struct CommandPaletteView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(SnippetStore.self) private var snippets
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    var onClose: () -> Void
    @State private var query: String

    init(initialQuery: String = "", onClose: @escaping () -> Void) {
        self.onClose = onClose
        _query = State(initialValue: initialQuery)
    }
    @State private var highlighted = 0
    /// Set by arrow keys so the list scrolling under a resting pointer doesn't
    /// yank the highlight back; cleared as soon as the mouse actually moves.
    @State private var keyboardNav = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: commandMode ? "command" : "magnifyingglass")
                    .font(.system(size: 15)).foregroundStyle(WL.green)
                    .contentTransition(.symbolEffect(.replace))
                TextField(loc("搜索主机，或输入 > 执行命令", "Search hosts, or type > for commands"), text: $query)
                    .textFieldStyle(.plain)
                    .font(WL.mono(18))
                    .foregroundStyle(WL.textPrimary)
                    .focused($focused)
                    .onSubmit(runHighlighted)
                    .onChange(of: query) { highlighted = 0 }
                    .onKeyPress(.downArrow) {
                        keyboardNav = true
                        highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        keyboardNav = true
                        highlighted = max(highlighted - 1, 0); return .handled
                    }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)

            Rectangle().fill(WL.border).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, cmd in
                            PaletteRow(command: cmd, isHighlighted: index == highlighted)
                                .contentShape(Rectangle())
                                // Hover moves the one shared highlight (keyboard and
                                // mouse never show two). Instant, like the keyboard.
                                .onContinuousHover { phase in
                                    if case .active = phase, highlighted != index, !keyboardNav {
                                        highlighted = index
                                    }
                                }
                                .onTapGesture { run(cmd) }
                                .id(cmd.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) {
                    guard keyboardNav, results.indices.contains(highlighted) else { return }
                    proxy.scrollTo(results[highlighted].id)
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(loc("无匹配命令", "No matching commands"))
                        .font(WL.body).foregroundStyle(WL.textDim)
                        .transition(.opacity)
                }
            }
            .animation(Motion.state, value: results.isEmpty)
            .background(MouseMoveWatcher { keyboardNav = false })
        }
        .background(WL.bg)
        .preferredColorScheme(WL.colorScheme)
        .onAppear {
            focused = true
            // Focusing selects all; with a prefilled ">" the first keystroke
            // would replace it. Put the caret after it instead.
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            }
        }
        .onExitCommand { onClose() }
    }

    // MARK: - Filtering

    private var commandMode: Bool { query.hasPrefix(">") }

    private var results: [PaletteCommand] {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if commandMode { q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let cmds = q.isEmpty ? commands : commands.filter {
            ($0.title + " " + $0.category + " " + ($0.subtitle ?? "")).lowercased().contains(q)
        }
        return commandMode ? cmds : hostCommands(q) + cmds
    }

    /// Hosts first: fuzzy-ranked when typing, most recently used when empty.
    private func hostCommands(_ q: String) -> [PaletteCommand] {
        let hosts: [Host]
        if q.isEmpty {
            hosts = store.hosts.sorted {
                let a = store.lastConnected[$0.alias] ?? .distantPast, b = store.lastConnected[$1.alias] ?? .distantPast
                return a != b ? a > b : $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
            }
        } else {
            hosts = store.search(q)
        }
        return hosts.map { host in
            let s = store.statuses[host.alias] ?? .unknown
            let text: String = switch s {
            case .online(let ms): "\(ms) ms"
            case .offline: loc("离线", "offline")
            case .checking: loc("探测中", "checking")
            case .unknown: ""
            }
            return PaletteCommand(
                title: host.alias, subtitle: host.connectionSummary, category: loc("连接", "Connect"),
                systemImage: "network", tint: store.groupColor(forAlias: host.alias)?.color ?? WL.green,
                badge: text.isEmpty ? nil : (text, s.tagColor)) {
                connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
            }
        }
    }

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ cmd: PaletteCommand) {
        onClose()
        // Run on the next tick so this palette fully dismisses first — otherwise a
        // command that opens another overlay (e.g. Quick Connect) races with our
        // teardown and the new field never grabs focus.
        // …and only once its exit animation has finished, so a command that opens
        // a window (Settings) doesn't start its own animation over ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { cmd.run() }
    }

    // MARK: - The command list

    private var commands: [PaletteCommand] {
        var out: [PaletteCommand] = []
        let actions = loc("动作", "Actions")

        func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }

        out += [
            PaletteCommand(title: loc("新建连接", "New Connection"), category: actions,
                           systemImage: "plus", tint: WL.green) { post(.newConnection) },
            PaletteCommand(title: loc("新建本地终端", "New Local Terminal"), category: actions,
                           systemImage: "terminal", tint: WL.green) {
                openLocalShell(sessions: sessions, openWindow: openWindow)
            },
            PaletteCommand(title: loc("快速连接", "Quick Connect"), category: actions,
                           systemImage: "bolt", tint: WL.teal) { post(.showQuickConnect) },
            PaletteCommand(title: loc("刷新状态", "Refresh Statuses"), category: actions,
                           systemImage: "arrow.clockwise", tint: WL.teal) { Task { await store.checkAll() } },
            PaletteCommand(title: loc("搜索终端", "Search Terminal"), category: actions,
                           systemImage: "magnifyingglass", tint: WL.amber) {
                post(sessions.activeSession != nil ? .searchTerminal : .focusSearch)
            },
            PaletteCommand(title: loc("折叠 / 展开侧栏", "Toggle Sidebar"), category: actions,
                           systemImage: "sidebar.left", tint: WL.textDim) { post(.toggleSidebar) },
            PaletteCommand(title: loc("显示 / 收起 AI 面板", "Toggle AI Panel"), category: actions,
                           systemImage: "sparkles", tint: WL.purple) { post(.toggleAI) },
            PaletteCommand(title: loc("聚焦终端输入", "Focus Terminal"), category: actions,
                           systemImage: "cursorarrow", tint: WL.textDim) { post(.focusTerminal) },
            PaletteCommand(title: loc("向右分屏", "Split Right"), category: actions,
                           systemImage: "rectangle.split.2x1", tint: WL.green) {
                wlAnimateTerminalLayout { sessions.splitActive(.trailing) }
            },
            PaletteCommand(title: loc("向下分屏", "Split Down"), category: actions,
                           systemImage: "rectangle.split.1x2", tint: WL.green) {
                wlAnimateTerminalLayout { sessions.splitActive(.bottom) }
            },
            PaletteCommand(title: loc("均分分屏", "Equalize Splits"), category: actions,
                           systemImage: "equal.square", tint: WL.textDim) {
                wlAnimateTerminalLayout { sessions.equalizeSplits() }
            },
            PaletteCommand(title: loc("放大 / 还原分屏", "Zoom / Restore Pane"), category: actions,
                           systemImage: "arrow.up.left.and.arrow.down.right", tint: WL.textDim) {
                wlAnimateTerminalLayout { sessions.toggleZoom() }
            },
            PaletteCommand(title: loc("复制上一条命令的输出", "Copy Last Command Output"), category: actions,
                           systemImage: "doc.on.clipboard", tint: WL.teal) { copyLastOutput(sessions) },
            PaletteCommand(title: loc("快捷终端", "Quick Terminal"), category: actions,
                           systemImage: "rectangle.topthird.inset.filled", tint: WL.green) {
                QuickTerminalController.shared.toggle()
            },
            PaletteCommand(title: loc("待办清单", "To-Do List"), category: actions,
                           systemImage: "checklist", tint: WL.amber) { openWindow(id: "todos") },
            PaletteCommand(title: loc("设置", "Settings"), category: actions,
                           systemImage: "gearshape", tint: WL.textDim) { openWindow(id: "settings") },
        ]

        // Run a snippet in the active session (inserts it so you can review / fill).
        if let session = sessions.activeSession {
            let snip = loc("片段", "Snippet")
            for s in snippets.snippets {
                out.append(PaletteCommand(
                    title: s.name, subtitle: s.command, category: snip,
                    systemImage: "text.alignleft", tint: WL.teal) {
                    session.insertIntoTerminal(s.command)
                    sessions.focusActiveTerminal()
                })
            }
        }

        // Switch theme / skin (recolors & restyles the whole UI).
        let theme = loc("主题", "Theme")
        for t in store.allThemes {
            out.append(PaletteCommand(title: t.name,
                                      subtitle: t.isBuiltIn ? nil : loc("自定义", "Custom"),
                                      category: theme, systemImage: "paintpalette",
                                      tint: t.isBuiltIn ? WL.green : WL.purple) {
                store.selectedThemeName = t.name
            })
        }

        return out
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(command.tint)
                .frame(width: 26, height: 26)
                .background(command.tint.opacity(isHighlighted ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: WL.radius(6)))
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(WL.body).foregroundStyle(WL.textPrimary).lineLimit(1)
                if let sub = command.subtitle {
                    Text(sub).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
                }
            }
            Spacer()
            if let badge = command.badge {
                Text(badge.text).font(WL.caption.monospacedDigit()).foregroundStyle(badge.color)
            } else {
                Text(command.category).font(WL.caption).foregroundStyle(WL.textDim)
            }
            if isHighlighted {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WL.textDim)
            }
        }
        .wlResultHighlight(isHighlighted)
    }
}

/// Calls back on real mouse movement inside the view (not on content scrolling
/// under a still pointer) — lets hover take over from keyboard navigation.
struct MouseMoveWatcher: NSViewRepresentable {
    let onMove: () -> Void
    func makeNSView(context: Context) -> NSView { Tracker(onMove: onMove) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Tracker)?.onMove = onMove }

    final class Tracker: NSView {
        var onMove: () -> Void
        init(onMove: @escaping () -> Void) { self.onMove = onMove; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
        override func mouseMoved(with event: NSEvent) { onMove() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
