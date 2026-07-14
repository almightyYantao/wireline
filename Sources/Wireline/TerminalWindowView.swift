import SwiftUI
import AppKit
import WirelineCore

/// Embeds a session's AppKit terminal view into SwiftUI, with an optional
/// background image and adjustable opacity behind it. The terminal view is owned
/// by the `TerminalSession`, so the PTY is never recreated on redraw.
struct TerminalHostView: NSViewRepresentable {
    @Environment(HostStore.self) private var store
    let session: TerminalSession

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
        DispatchQueue.main.async { container.window?.makeFirstResponder(term) }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
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

        // Background: image if set, else the theme background color.
        if let path = store.terminalBgImagePath, let image = NSImage(contentsOfFile: path) {
            container.layer?.contents = image
            container.layer?.contentsGravity = .resizeAspectFill
            container.layer?.backgroundColor = NSColor.black.cgColor
        } else {
            container.layer?.contents = nil
            container.layer?.backgroundColor = theme.backgroundNS.cgColor
        }

        // Terminal background alpha lets the background show through when < 1.
        term.wantsLayer = true
        term.layer?.isOpaque = opacity >= 1.0
        term.nativeBackgroundColor = theme.backgroundNS.withAlphaComponent(opacity)
        DispatchQueue.main.async { container.window?.makeFirstResponder(term) }
    }
}
