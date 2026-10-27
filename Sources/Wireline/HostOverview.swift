import SwiftUI
import WirelineCore

/// The home screen when nothing is open: every host as a card, grouped, with
/// live status, latency and when you last used it. One click connects.
struct HostOverview: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    var onEdit: (Host) -> Void
    var onNew: () -> Void
    var onFiles: (Host) -> Void
    var onDetails: (Host) -> Void
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var onlineCount: Int {
        store.hosts.filter { if case .online = store.statuses[$0.alias] { return true } else { return false } }.count
    }

    private var sections: [(title: String, group: String?, hosts: [Host])] {
        let q = HostQuery(filter)
        func match(_ h: Host) -> Bool { q.isEmpty || q.match(h) != nil }
        var out = store.groups.map { (title: $0, group: Optional($0), hosts: store.hosts(inGroup: $0).filter(match)) }
        if store.hasUngrouped {
            out.append((title: loc("未分组", "Ungrouped"), group: nil, hosts: store.hosts(inGroup: nil).filter(match)))
        }
        return out.filter { !$0.hosts.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.hosts.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(sections, id: \.title) { section in
                            groupSection(section.title, group: section.group, hosts: section.hosts)
                        }
                        if sections.isEmpty {
                            Text(loc("没有匹配的主机", "No matching hosts"))
                                .font(WL.small).foregroundStyle(WL.textDim)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Sits level with the tab bar, right of the drawer's corner button.
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("主机", "Hosts")).font(WL.mono(15, .semibold)).foregroundStyle(WL.textPrimary)
                Text(loc("\(store.hosts.count) 台 · \(onlineCount) 在线", "\(store.hosts.count) hosts · \(onlineCount) online"))
                    .font(WL.caption).foregroundStyle(WL.textDim)
                    .contentTransition(.numericText())
                    .animation(Motion.state, value: onlineCount)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(WL.textDim)
                TextField(loc("过滤", "Filter"), text: $filter)
                    .textFieldStyle(.plain).font(WL.small).foregroundStyle(WL.textPrimary)
                    .focused($filterFocused).frame(width: 150)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .wlSearchCapsule(focused: filterFocused)
            Button { Task { await store.checkAll() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.wlIcon).help(loc("刷新状态", "Refresh statuses"))
            Button { openLocalShell(sessions: sessions, openWindow: openWindow) } label: {
                Label(loc("本地终端", "Local Terminal"), systemImage: "terminal")
            }.buttonStyle(.wlSecondary)
            Button(action: onNew) { Label(loc("新建主机", "New Host"), systemImage: "plus") }
                .buttonStyle(.wlPrimary)
        }
        .padding(.leading, 24).padding(.trailing, 20).padding(.top, 28)
        .frame(minHeight: 64)
        .blocksWindowDrag()   // title-bar band: see WLPageHeader
        .padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(WL.textDim)
            Text(loc("还没有主机", "No hosts yet")).font(WL.body).foregroundStyle(WL.textPrimary)
            Text(loc("新建一台，或直接编辑 ~/.ssh/config —— Wireline 会自动读取。",
                     "Add one, or edit ~/.ssh/config — Wireline picks it up."))
                .font(WL.small).foregroundStyle(WL.textDim)
            Button(action: onNew) { Label(loc("新建主机", "New Host"), systemImage: "plus") }
                .buttonStyle(.wlPrimary).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupSection(_ title: String, group: String?, hosts: [Host]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let c = group.flatMap({ store.groupColors[$0] }) {
                    Circle().fill(c.color).frame(width: 7, height: 7)
                }
                Text(title).font(WL.small.weight(.semibold)).foregroundStyle(WL.textDim)
                Text("\(hosts.count)").font(WL.caption).foregroundStyle(WL.textDim.opacity(0.7))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(hosts) { host in
                    HostCard(host: host, color: group.flatMap { store.groupColors[$0] },
                             status: store.statuses[host.alias], last: store.lastConnected[host.alias],
                             onConnect: { connectHost(host, store: store, sessions: sessions, openWindow: openWindow) })
                        .wlContextMenu([
                            .item(loc("连接", "Connect"), systemImage: "play.fill") {
                                connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
                            },
                        ] + (host.isRDP ? [] : [
                            .item(loc("文件 (SFTP)", "Files (SFTP)"), systemImage: "folder") { onFiles(host) },
                        ]) + [
                            .item(loc("详情", "Details"), systemImage: "info.circle") { onDetails(host) },
                            .item(loc("编辑…", "Edit…"), systemImage: "pencil") { onEdit(host) },
                        ])
                }
            }
        }
    }
}

/// One host on the overview: colour stripe for its group, status, latency,
/// last connected. Lifts slightly on hover; click to connect.
private struct HostCard: View {
    @Environment(Localizer.self) private var loc
    let host: Host
    let color: GroupColor?
    let status: HostStatus?
    let last: Date?
    let onConnect: () -> Void
    @State private var hover = false

    private var s: HostStatus { status ?? .unknown }
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WL.radius(12), style: .continuous)
    }

    private var statusText: String {
        switch s {
        case .online(let ms): return "\(ms) ms"
        case .offline: return loc("离线", "offline")
        case .checking: return loc("探测中", "checking")
        case .unknown: return loc("未知", "unknown")
        }
    }

    private var lastText: String {
        guard let last else { return loc("从未连接", "never") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        // Follow the app's language, not the system's ("3 小时前", not "3 hr. ago").
        f.locale = Locale(identifier: Localizer.shared.isChinese ? "zh-Hans" : "en")
        return f.localizedString(for: last, relativeTo: Date())
    }

    var body: some View {
        Button(action: onConnect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(s.tagColor).frame(width: 7, height: 7)
                        .wlPulse(s == .checking, period: 0.8, low: 0.4)
                    Text(host.alias).font(WL.body.weight(.semibold)).foregroundStyle(WL.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: host.resolvedAuthMethod == .key ? "key.fill" : "lock.fill")
                        .font(.system(size: 9)).foregroundStyle(WL.textDim)
                }
                Text(host.connectionSummary).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
                HStack {
                    Text(statusText).font(WL.caption.monospacedDigit()).foregroundStyle(s.tagColor)
                    Spacer()
                    Text(lastText).font(WL.caption).foregroundStyle(WL.textDim)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A raised card; hover lifts it (deeper shadow on the shape only,
            // accent edge fading in over the hairline — same shape throughout).
            .background {
                cardShape.fill(WL.cardFill)
                    .overlay(cardShape.fill(WL.textPrimary.opacity(hover ? 0.03 : 0)))
                    .shadow(color: .black.opacity(WL.depth(hover ? 0.18 : 0.08)), radius: hover ? 9 : 3, y: hover ? 3 : 1)
            }
            .overlay(alignment: .leading) {
                // The group's colour label: a short capsule, as in the drawer.
                if let color {
                    Capsule().fill(color.color).frame(width: 3, height: 18).padding(.leading, 5)
                }
            }
            .overlay(cardShape.strokeBorder(WL.hairline, lineWidth: 1))
            .overlay(cardShape.strokeBorder(WL.green.opacity(hover ? 0.45 : 0), lineWidth: 1))
            .contentShape(cardShape)
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
        .draggable(host.alias)
        .help(loc("单击连接 · 右键更多", "Click to connect · right-click for more"))
    }
}
