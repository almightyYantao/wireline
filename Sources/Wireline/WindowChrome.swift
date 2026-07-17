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

/// Puts the app-wide wallpaper behind `content` and attaches the same window
/// chrome the main window uses, so secondary windows (the to-do list, …)
/// composite over the identical translucent backdrop. Panels inside `content`
/// should use `WL.bg.opacity(store.terminalOpacity * WL.chromeOpacity)` to let the wallpaper show
/// through, exactly like the main window's panels.
struct WallpaperBackground: ViewModifier {
    @Environment(HostStore.self) private var store
    @State private var chrome = WindowChromeController()

    func body(content: Content) -> some View {
        // Read the palette version so the tree rebuilds when the theme recolors.
        let _ = Palette.shared.version
        ZStack {
            WallpaperView(path: store.terminalBgImagePath)
                .ignoresSafeArea()
            content
        }
        .background(WindowAccessor { chrome.attach(to: $0) })
        .id(Palette.shared.version)
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Composite this view over the app-wide wallpaper with shared window chrome.
    func wlWallpaperBackground() -> some View { modifier(WallpaperBackground()) }
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
        // Don't let dragging arbitrary content move the window — otherwise
        // dragging a session tab is swallowed as a window move instead of an
        // `.onDrag`. The title-bar strip still moves the window.
        window.isMovableByWindowBackground = false
        installZoomMonitor(window)
    }

    /// No-op kept for call sites; the hidden title bar is now SwiftUI-managed.
    func reapply() {}

    private func installZoomMonitor(_ window: NSWindow) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window, event.clickCount == 2 else { return event }
            // Don't zoom when the double-click is over an interactive control that
            // lives in the title-bar strip (e.g. the session tab bar, which uses
            // double-click to rename). Otherwise the click would be swallowed here.
            if TitleBarZoomGuard.shared.pointerInNoZoomZone { return event }
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

/// Marks its region as non-window-draggable, so an `.onDrag` there (e.g. session
/// tabs sitting in the title-bar strip) isn't swallowed as a window move. Applied
/// as a `.background`; it doesn't intercept clicks/gestures on the content above.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

extension View {
    /// Prevent window dragging from starting on this view's area.
    func blocksWindowDrag() -> some View { background(WindowDragBlocker()) }
}

/// Shared flag: true while the pointer is over a title-bar-region control that
/// must not trigger window zoom on double-click (set by the session tab bar).
/// Read/written on the main thread only.
final class TitleBarZoomGuard: @unchecked Sendable {
    static let shared = TitleBarZoomGuard()
    var pointerInNoZoomZone = false
}
