import SwiftUI
import WirelineCore

/// A Spotlight-style palette: type a few letters of an alias, hit return, connect.
struct QuickConnectView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [Host] { store.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Connect to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit(connectHighlighted)
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                List(Array(results.enumerated()), id: \.element.id) { index, host in
                    QuickConnectRow(host: host,
                                    status: store.statuses[host.alias],
                                    isHighlighted: index == highlighted)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { connect(host) }
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted, anchor: .center) }
            }
            .overlay {
                if results.isEmpty {
                    Text("No matching hosts").foregroundStyle(.secondary)
                }
            }
        }
        .background(.ultraThinMaterial)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0); return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func connectHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        connect(results[highlighted])
    }

    private func connect(_ host: Host) {
        connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
        dismiss()
    }
}

struct QuickConnectRow: View {
    let host: Host
    let status: HostStatus?
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.alias).font(.body.weight(.medium))
                Text(host.connectionSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let g = host.group { Text(g).font(.caption2).foregroundStyle(.tertiary) }
            AuthBadge(method: host.resolvedAuthMethod)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(isHighlighted ? Color.accentColor.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
