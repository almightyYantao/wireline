import SwiftUI
import WirelineCore

/// Routes a "connect" action to either the built-in terminal (opening a session
/// in the main window's terminal pane) or the user's external terminal, based
/// on the preference in `HostStore`.
@MainActor
func connectHost(_ host: Host, store: HostStore, sessions: SessionStore,
                 openWindow: OpenWindowAction) {
    if store.useBuiltInTerminal {
        sessions.open(host: host, password: store.password(for: host), sudoPassword: store.sudoPassword(for: host))
        // Bring the main window forward so the new session is visible (e.g. when
        // launched from Quick Connect or the menu bar).
        openWindow(id: "main")
    } else {
        store.connectExternal(host)
    }
}

/// Open a plain local shell session in the main window and focus it.
@MainActor
func openLocalShell(sessions: SessionStore, openWindow: OpenWindowAction) {
    sessions.openLocalShell()
    openWindow(id: "main")
}

/// Open an SFTP file-transfer session for a host.
@MainActor
func openFiles(_ host: Host, store: HostStore, sessions: SessionStore,
               openWindow: OpenWindowAction) {
    sessions.openSFTP(host: host, password: store.password(for: host))
    openWindow(id: "main")
}
