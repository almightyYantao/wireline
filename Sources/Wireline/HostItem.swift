import SwiftUI
import WirelineCore

/// A single host entry in the left panel: alias + endpoint + bracketed status
/// tag, draggable into groups, click to connect.
struct HostItem: View {
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    let host: Host
    let status: HostStatus?
    let isActive: Bool
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    var onConnect: () -> Void
    var onEdit: () -> Void
    var onForward: () -> Void = {}
    var onFiles: () -> Void = {}
    @State private var hover = false

    private var s: HostStatus { status ?? .unknown }
    private var statusText: String {
        switch s {
        case .online: return loc("在线", "online")
        case .offline: return loc("离线", "offline")
        case .checking: return loc("探测中", "checking")
        case .unknown: return loc("空闲", "idle")
        }
    }
    private var authSymbol: String { host.resolvedAuthMethod == .key ? "key.fill" : "lock.fill" }
    private var rowBackground: Color {
        // Keep the selected/active highlight translucent so the app wallpaper
        // shows through it, matching the rest of the chrome.
        (isActive || isSelected) ? WL.surface.opacity(0.55)
                                  : (hover ? WL.surface.opacity(0.3) : Color.clear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
                .padding(.horizontal, 16).padding(.top, 7)
                .padding(.bottom, isActive ? 3 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Single click selects; double click connects.
                .onTapGesture { onSelect() }
                .simultaneousGesture(TapGesture(count: 2).onEnded { onConnect() })
            if isActive {
                HStack(spacing: 16) {
                    InlineAction(symbol: "arrow.left.arrow.right", label: "端口转发",
                                 tint: WL.green, action: onForward)
                    Text("|").font(WL.caption).foregroundStyle(WL.border)
                    InlineAction(symbol: "folder", label: "文件", tint: WL.purple, action: onFiles)
                    Spacer()
                }
                .padding(.leading, 16).padding(.bottom, 8)
            }
        }
        .background(rowBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(WL.green).frame(width: 2).opacity(isActive || isSelected ? 1 : 0)
        }
        .onHover { hover = $0 }
        .draggable(host.alias) {
            Text(host.alias).font(WL.body).foregroundStyle(WL.green)
                .padding(6).background(WL.surface)
        }
        .wlContextMenu(menuItems)
    }

    private var menuItems: [WLMenuItem] {
        var items: [WLMenuItem] = [
            .item(loc("连接", "Connect"), systemImage: "play.fill") { onConnect() },
            .item(loc("编辑…", "Edit…"), systemImage: "pencil") { onEdit() },
            .item(loc("检测状态", "Check status"), systemImage: "arrow.clockwise") { Task { await store.check(host) } }
        ]
        for g in store.groups {
            items.append(.item(loc("移到分组：\(g)", "Move to: \(g)"), systemImage: "folder") { store.setGroup(g, for: [host.alias]) })
        }
        if !store.groups.isEmpty {
            items.append(.item(loc("移到未分组", "Move to Ungrouped"), systemImage: "tray") { store.setGroup(nil, for: [host.alias]) })
        }
        items.append(.divider)
        items.append(.item(loc("删除", "Delete"), systemImage: "trash", destructive: true) { store.delete(host) })
        return items
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: authSymbol).font(.system(size: 9)).foregroundStyle(WL.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).font(WL.body)
                    .foregroundStyle(isActive ? WL.greenBright : WL.textPrimary)
                Text(host.connectionSummary).font(WL.caption)
                    .foregroundStyle(WL.textDim).lineLimit(1)
            }
            Spacer(minLength: 6)
            if host.autoSudo {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(WL.amber)
            }
            if isActive {
                Text(loc("已连接", "connected")).font(WL.small).foregroundStyle(WL.green)
            } else {
                Text(statusText).font(WL.small).foregroundStyle(s.tagColor)
            }
        }
    }
}

/// A small icon+label action shown under the active host.
struct InlineAction: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(label).font(WL.small)
            }
            .foregroundStyle(hover ? tint : tint.opacity(0.8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
