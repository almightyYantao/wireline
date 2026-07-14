import SwiftUI
import WirelineCore

struct HostDetailView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let host: Host
    var onEdit: (Host) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                GroupBox("Connection") {
                    infoGrid([
                        ("Alias", host.alias),
                        ("Host", host.connectHostname),
                        ("User", host.user ?? "—"),
                        ("Port", String(host.effectivePort)),
                        ("Auth", host.resolvedAuthMethod == .key ? "Public key" : "Password"),
                        ("Identity", host.identityFile ?? "—"),
                        ("Jump Host", host.proxyJump ?? "—")
                    ])
                }

                if !host.extraOptions.isEmpty {
                    GroupBox("Other Options") {
                        infoGrid(host.extraOptions.map { ($0.keyword, $0.value) })
                    }
                }

                GroupBox("Wireline") {
                    infoGrid([
                        ("Group", host.group ?? "Ungrouped"),
                        ("Description", host.descriptionText ?? "—"),
                        ("Auto-sudo", host.autoSudo ? "Enabled" : "Disabled")
                    ])
                }

                Text("Alias resolves through ~/.ssh/config — the same `ssh \(host.alias)`, `scp`, and VS Code Remote all work in your terminal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle(host.alias)
    }

    private var header: some View {
        HStack(spacing: 14) {
            StatusDot(status: store.statuses[host.alias])
                .scaleEffect(1.6)
            VStack(alignment: .leading) {
                Text(host.alias).font(.title2.bold())
                Text(StatusDot(status: store.statuses[host.alias]).text)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.check(host) } } label: {
                Label("Check", systemImage: "arrow.clockwise")
            }
            Button { onEdit(host) } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func infoGrid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { key, value in
                GridRow {
                    Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(value).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
    }
}
