import SwiftUI
import AppKit

/// Captures the hosting `NSWindow`.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

/// Configures a real, transparent, dark title bar (NOT full-size content). The
/// system title bar stays a genuine ~28pt strip above the content, so native
/// drag and double-click-to-zoom work; the content never covers it.
@MainActor
final class WindowChromeController {
    func attach(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.remove(.fullSizeContentView)   // keep a real title bar
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.039, green: 0.055, blue: 0.039, alpha: 1)
        window.titlebarSeparatorStyle = .none            // seamless with content
    }
}
