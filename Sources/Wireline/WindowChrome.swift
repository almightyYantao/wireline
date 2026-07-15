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

/// Full-size-content transparent title bar so the app's dark chrome runs edge to
/// edge (no separate grey bar). Double-click-to-zoom is handled by a local event
/// monitor — reliable even though SwiftUI content overlays the title bar.
@MainActor
final class WindowChromeController {
    private var monitor: Any?
    private weak var window: NSWindow?

    func attach(to window: NSWindow) {
        self.window = window
        // The title bar itself is hidden via SwiftUI's `.windowStyle(.hiddenTitleBar)`
        // (persistent across sheets / window switches). Here we only tint the
        // window background (a fallback behind the wallpaper) and remove the
        // separator; these don't get clobbered.
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(Palette.shared.bg)
        installZoomMonitor(window)
    }

    /// No-op kept for call sites; the hidden title bar is now SwiftUI-managed.
    func reapply() {}

    private func installZoomMonitor(_ window: NSWindow) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window, event.clickCount == 2 else { return event }
            let h = window.contentView?.bounds.height ?? window.frame.height
            // Only the top title-bar strip (avoid the traffic-light buttons on the left).
            if event.locationInWindow.y > h - 28, event.locationInWindow.x > 78 {
                window.zoom(nil)
                return nil
            }
            return event
        }
    }
}
