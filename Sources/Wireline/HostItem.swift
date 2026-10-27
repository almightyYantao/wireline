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
    var onDetails: () -> Void = {}
    var onConnect: () -> Void
    var onEdit: () -> Void
    var onForward: () -> Void = {}
    var onFiles: () -> Void = {}
    /// Set in search results: which fields hit, and the words to highlight.
    var match: HostSearchMatch? = nil
    var highlightTerms: [String] = []
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
    private var authSymbol: String {
        host.resolvedAuthMethod == .key ? "key.fill" : "lock.fill"
    }
    private var rowBackground: Color {
        if isActive { return WL.green.opacity(WL.isLight ? 0.12 : 0.14) }
        if isSelected { return WL.textPrimary.opacity(WL.isLight ? 0.07 : 0.09) }
        return WL.textPrimary.opacity(hover ? 0.045 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
                .padding(.horizontal, 12).padding(.top, 7)
                .padding(.bottom, isActive ? 3 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Single click highlights; double click connects.
                .onTapGesture { onSelect() }
                .simultaneousGesture(TapGesture(count: 2).onEnded { onConnect() })
            // Forwards and SFTP need a shell: not for a Windows desktop.
            if isActive, !host.isRDP {
                HStack(spacing: 16) {
                    InlineAction(symbol: "arrow.left.arrow.right", label: "端口转发",
                                 tint: WL.green, action: onForward)
                    Text("|").font(WL.caption).foregroundStyle(WL.border)
                    InlineAction(symbol: "folder", label: "文件", tint: WL.purple, action: onFiles)
                    Spacer()
                }
                .padding(.leading, 12).padding(.bottom, 8)
                .transition(.wlDisclose)
            }
        }
        .animation(Motion.disclose, value: isActive)
        // An inset rounded highlight (like the tabs' pills), not a full-bleed band.
        .background(rowBackground, in: RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
        .overlay(alignment: .leading) {
            // The group's colour label: a short capsule inside the row.
            if let label = store.groupColor(forAlias: host.alias)?.color {
                Capsule().fill(label).frame(width: 3, height: 16).padding(.leading, 5)
            }
        }
        .animation(Motion.state, value: isSelected)
        .animation(Motion.hover, value: hover)
        .padding(.horizontal, 8).padding(.vertical, 1)
        .wlHover($hover)
        .draggable(host.alias) {
            Text(host.alias).font(WL.body).foregroundStyle(WL.green)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(WL.surface, in: Capsule(style: .continuous))
        }
        .wlContextMenu(menuItems)
    }

    private var menuItems: [WLMenuItem] {
        var items: [WLMenuItem] = [
            .item(loc("连接", "Connect"), systemImage: "play.fill") { onConnect() },
            .item(loc("详情", "Details"), systemImage: "info.circle") { onDetails() },
            .item(loc("编辑…", "Edit…"), systemImage: "pencil") { onEdit() },
            .item(loc("检测状态", "Check status"), systemImage: "arrow.clockwise") { Task { await store.check(host) } }
        ]
        if !store.groups.isEmpty {
            var move: [WLMenuItem] = store.groups.map { g in
                .item(g, checked: host.group == g) { store.setGroup(g, for: [host.alias]) }
            }
            move.append(.divider)
            move.append(.item(loc("未分组", "Ungrouped"), checked: host.group == nil) { store.setGroup(nil, for: [host.alias]) })
            items.append(.submenu(loc("移到分组", "Move to Group"), systemImage: "folder", move))
        }
        items.append(.divider)
        items.append(.item(loc("删除", "Delete"), systemImage: "trash", destructive: true) { store.delete(host) })
        return items
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 8) {
            if host.isRDP {
                WindowsGlyph(size: 9)
            } else {
                Image(systemName: authSymbol).font(.system(size: 9)).foregroundStyle(WL.textDim)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(host.alias, highlightTerms)).font(WL.body)
                    .foregroundStyle(isActive ? WL.greenBright : WL.textPrimary)
                Text(highlighted(host.connectionSummary, highlightTerms)).font(WL.caption)
                    .foregroundStyle(WL.textDim).lineLimit(1)
                if let match, let note = hostMatchNote(match) {
                    Text(highlighted(note, highlightTerms)).font(WL.small)
                        .foregroundStyle(WL.textDim).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if host.autoSudo {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(WL.amber)
            }
            if isActive {
                Text(loc("已连接", "connected")).font(WL.small).foregroundStyle(WL.green)
            } else {
                Text(statusText).font(WL.small).foregroundStyle(s.tagColor)
                    .wlPulse(s == .checking, period: 0.8, low: 0.45)
                    .contentTransition(.opacity)
                    .animation(Motion.state, value: statusText)
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
        .buttonStyle(.wlPlain)
        .wlHover($hover)
    }
}

/// `text` with every occurrence of `terms` emphasised.
func highlighted(_ text: String, _ terms: [String]) -> AttributedString {
    var out = AttributedString(text)
    for r in HostSearch.highlightRanges(in: text, terms: terms) {
        guard let lo = AttributedString.Index(r.lowerBound, within: out),
              let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
        out[lo..<hi].foregroundColor = WL.amber
        out[lo..<hi].underlineStyle = .single
    }
    return out
}

/// A line naming the matched fields that the row doesn't already show.
@MainActor
func hostMatchNote(_ m: HostSearchMatch) -> String? {
    let loc = Localizer.shared
    var parts: [String] = []
    let h = m.host
    if m.fields.contains(.group), let g = h.group { parts.append(loc.t("分组 ", "group ") + g) }
    if m.fields.contains(.tag), !h.tags.isEmpty { parts.append(h.tags.map { "#" + $0 }.joined(separator: " ")) }
    if m.fields.contains(.description), !m.fields.contains(.tag), let d = h.descriptionText { parts.append(d) }
    if m.fields.contains(.address), let j = h.proxyJump { parts.append("via " + j) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
