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
    let run: () -> Void
}

/// A Spotlight-style "do anything" palette (⌘P): fuzzy-search every app action —
/// connect a host, open a terminal, run a snippet, switch theme, open settings —
/// and run it, all from the keyboard. ↑/↓ to move, Return to run, Esc to close.
struct CommandPaletteView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(SnippetStore.self) private var snippets
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    var onClose: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.system(size: 15)).foregroundStyle(WL.green)
                TextField(loc("执行命令…", "Run a command…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(WL.mono(18))
                    .foregroundStyle(WL.textPrimary)
                    .focused($focused)
                    .onSubmit(runHighlighted)
                    .onChange(of: query) { highlighted = 0 }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0); return .handled
                    }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)

            Rectangle().fill(WL.border).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, cmd in
                            PaletteRow(command: cmd, isHighlighted: index == highlighted)
                                .contentShape(Rectangle())
                                .onTapGesture { run(cmd) }
                                .id(cmd.id)
                        }
                    }
                }
                .onChange(of: highlighted) {
                    if results.indices.contains(highlighted) {
                        proxy.scrollTo(results[highlighted].id, anchor: .center)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(loc("无匹配命令", "No matching commands"))
                        .font(WL.body).foregroundStyle(WL.textDim)
                }
            }
        }
        .background(WL.bg)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .onExitCommand { onClose() }
    }

    // MARK: - Filtering

    private var results: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter {
            ($0.title + " " + $0.category + " " + ($0.subtitle ?? "")).lowercased().contains(q)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { cmd.run() }
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
            PaletteCommand(title: loc("待办清单", "To-Do List"), category: actions,
                           systemImage: "checklist", tint: WL.amber) { openWindow(id: "todos") },
            PaletteCommand(title: loc("设置", "Settings"), category: actions,
                           systemImage: "gearshape", tint: WL.textDim) { openWindow(id: "settings") },
        ]

        // Connect to any host.
        let connect = loc("连接", "Connect")
        for host in store.hosts {
            out.append(PaletteCommand(
                title: host.alias, subtitle: host.connectionSummary, category: connect,
                systemImage: "network", tint: WL.green) {
                connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
            })
        }

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
                .font(.system(size: 11)).foregroundStyle(command.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(WL.body)
                    .foregroundStyle(isHighlighted ? WL.greenBright : WL.textPrimary).lineLimit(1)
                if let sub = command.subtitle {
                    Text(sub).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
                }
            }
            Spacer()
            Text(command.category).font(WL.caption).foregroundStyle(WL.textDim)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(isHighlighted ? WL.green.opacity(0.16) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(WL.green).frame(width: 2).opacity(isHighlighted ? 1 : 0)
        }
    }
}
