import SwiftUI
import WirelineCore

/// The menu-bar dropdown: search-and-connect without opening the main window.
struct MenuBarContent: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private var results: [Host] { Array(store.search(query).prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Connect to…", text: $query)
                .textFieldStyle(.roundedBorder)

            ForEach(results) { host in
                Button {
                    connectHost(host, store: store, sessions: sessions, openWindow: openWindow)
                } label: {
                    HStack {
                        StatusDot(status: store.statuses[host.alias])
                        Text(host.alias)
                        Spacer()
                        Text(host.connectionSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if results.isEmpty {
                Text("No matches").foregroundStyle(.secondary).font(.caption)
            }

            Divider()
            Button("New Local Terminal") {
                openLocalShell(sessions: sessions, openWindow: openWindow)
            }
            Button("Open Wireline") { openWindow(id: "main") }
            Button("Quick Connect…") { openWindow(id: "quick-connect") }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 300)
    }
}
