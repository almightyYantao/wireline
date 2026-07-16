import SwiftUI
import AppKit
import WirelineCore

/// Embeds a session's AppKit terminal view into SwiftUI, with an optional
/// background image and adjustable opacity behind it. The terminal view is owned
/// by the `TerminalSession`, so the PTY is never recreated on redraw.
struct TerminalHostView: NSViewRepresentable {
    @Environment(HostStore.self) private var store
    let session: TerminalSession
    /// Whether this pane should take keyboard focus. In split view only the
    /// focused pane is `true`, so redraws never steal focus between panes.
    var autoFocus: Bool = true

    final class Coordinator { var didFocus = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .duringViewResize
        let term = session.terminalView
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        apply(to: container)
        if autoFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { container.window?.makeFirstResponder(term) }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
        // Grab focus only on a false→true transition — never on every redraw, or
        // split panes would fight over first responder.
        if autoFocus, !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            let term = session.terminalView
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        } else if !autoFocus {
            context.coordinator.didFocus = false
        }
    }

    private func apply(to container: NSView) {
        let opacity = max(0.2, min(1.0, store.terminalOpacity))
        let theme = store.terminalTheme ?? .wireline
        let term = session.terminalView

        // Color scheme (ANSI palette + fg/cursor).
        term.installColors(theme.ansiTermColors)
        term.nativeForegroundColor = theme.foregroundNS
        term.caretColor = theme.cursorNS

        // Font.
        if let name = store.terminalFontName, let f = NSFont(name: name, size: store.terminalFontSize) {
            term.font = f
        } else if let f = TerminalFont.preferred(size: store.terminalFontSize) {
            term.font = f
        }

        // The app-wide wallpaper sits behind everything. The terminal itself adds
        // NO background tint — it stays fully clear so the single translucent
        // `WL.bg.opacity(opacity)` layer painted by the enclosing RightPanel shows
        // through, exactly matching the sidebar's shade (no double-tinting).
        _ = opacity
        container.layer?.contents = nil
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        term.wantsLayer = true
        term.layer?.isOpaque = false
        term.nativeBackgroundColor = .clear
        term.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
