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

    var body: some View {
        Group {
            switch operation {
            case .forwarding:
                ToolContainer(title: loc("端口转发", "Port Forwarding")) { PortForwardView() }
            case .files:
                if let host = fileHost {
                    ToolContainer(title: loc("文件 · \(host.alias)", "Files · \(host.alias)")) {
                        FileBrowserView(host: host) { operation = nil; fileHost = nil }
                    }
                } else {
                    ToolContainer(title: loc("文件 (SFTP)", "Files (SFTP)")) { FilesPicker(onPick: { fileHost = $0 }) }
                }
            case .none:
                sessionArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WL.bg)
    }

    private var detailHost: Host? {
        selectedAlias.flatMap { alias in store.hosts.first { $0.alias == alias } }
    }

    @ViewBuilder
    private var sessionArea: some View {
        VStack(spacing: 0) {
            if !sessions.sessions.isEmpty {
                SessionTabBar()
                Rectangle().fill(WL.border).frame(height: 1)
            }
            if let session = sessions.activeSession {
                ConnectionInfoBar(session: session)
                Rectangle().fill(WL.border).frame(height: 1)
                TerminalHostView(session: session).id(session.id)
                StatusBar(session: session)
            } else if let host = detailHost {
                HostDetailView(host: host, onEdit: onEditHost)
            } else {
                IdleConsole()
            }
        }
    }
}

// MARK: - Tab bar

struct SessionTabBar: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sessions.sessions) { session in
                    SessionTab(session: session, isActive: sessions.activeID == session.id)
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
    }
}

struct SessionTab: View {
    @Environment(SessionStore.self) private var sessions
    let session: TerminalSession
    let isActive: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(session.title).font(WL.small)
                .foregroundStyle(isActive ? WL.greenBright : WL.textDim)
            Button { sessions.close(session.id) } label: {
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
        .onTapGesture { sessions.activeID = session.id }
        .onHover { hover = $0 }
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
            Text(endpoint).font(WL.body).foregroundStyle(WL.greenBright)
            if let host {
                info(loc("端口", "Port"), String(host.effectivePort))
            }
            info(loc("协议", "Protocol"), "SSH-2")
            info(loc("延迟", "Latency"), latency)
            Spacer()
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

    private var endpoint: String {
        guard case .ssh(let alias, _, _) = session.kind else { return session.title }
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
        .background(WL.bg)
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
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(WL.body.weight(.semibold)).foregroundStyle(WL.green)
                .padding(.horizontal, 18).padding(.vertical, 12)
            Rectangle().fill(WL.border).frame(height: 1)
            content
        }
    }
}
