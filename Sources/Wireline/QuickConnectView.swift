import SwiftUI
import WirelineCore

/// A Spotlight-style palette: type a few letters of an alias, hit return, connect.
struct QuickConnectView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    @Environment(\.openWindow) private var openWindow
    /// Called to close the palette (it's an in-window overlay, not a sheet, so no
    /// AppKit sheet machinery resets the custom title bar).
    var onClose: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyboardNav = false
    @State private var results: [Host] = []
    @FocusState private var focused: Bool

    private func recompute() {
        results = store.search(query)
        highlighted = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(">").font(WL.mono(18, .bold)).foregroundStyle(WL.green)
                TextField(loc("连接到…", "Connect to…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(WL.mono(18))
                    .foregroundStyle(WL.textPrimary)
                    .focused($focused)
                    .onSubmit(connectHighlighted)
                    .onChange(of: query) { recompute() }
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
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, host in
                            QuickConnectRow(host: host,
                                            status: store.statuses[host.alias],
                                            isHighlighted: index == highlighted)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    if case .active = phase, highlighted != index, !keyboardNav {
                                        highlighted = index
                                    }
                                }
                                .onTapGesture { connect(host) }
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
                    Text(loc("无匹配主机", "No matching hosts"))
                        .font(WL.body).foregroundStyle(WL.textDim)
                        .transition(.opacity)
                }
            }
            .animation(Motion.state, value: results.isEmpty)
            .background(MouseMoveWatcher { keyboardNav = false })
        }
        .background(WL.bg)
        .preferredColorScheme(WL.colorScheme)
        .onAppear { focused = true; recompute() }
        .onExitCommand { onClose() }
    }

    private func connectHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        connect(results[highlighted])
    }

    private func connect(_ host: Host) {
        connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
        onClose()
    }
}

struct QuickConnectRow: View {
    let host: Host
    let status: HostStatus?
    let isHighlighted: Bool

    private var s: HostStatus { status ?? .unknown }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.resolvedAuthMethod == .key ? "key.fill" : "lock.fill")
                .font(.system(size: 9)).foregroundStyle(WL.textDim)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.alias).font(WL.body)
                    .foregroundStyle(WL.textPrimary)
                Text(host.connectionSummary).font(WL.caption).foregroundStyle(WL.textDim)
            }
            Spacer()
            if let g = host.group { Text(g).font(WL.caption).foregroundStyle(WL.textDim) }
            Text(s.tagText).font(WL.small).foregroundStyle(s.tagColor)
        }
        .wlResultHighlight(isHighlighted)
    }
}
