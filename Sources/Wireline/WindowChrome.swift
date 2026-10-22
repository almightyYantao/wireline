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
        .preferredColorScheme(WL.colorScheme)
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
        window.backgroundColor = WallpaperView.edgeColor ?? NSColor(Palette.shared.bg)
        // Don't let dragging arbitrary content move the window — otherwise
        // dragging a session tab is swallowed as a window move instead of an
        // `.onDrag`. The title-bar strip still moves the window.
        window.isMovableByWindowBackground = false
        // An empty compact toolbar makes the title bar a little taller and
        // centres the traffic lights in it, so the tabs can sit on the same row
        // (Safari / Ghostty style) instead of a strip below.
        if window.toolbar == nil {
            let tb = NSToolbar(identifier: "wireline.titlebar")
            tb.showsBaselineSeparator = false
            tb.allowsUserCustomization = false
            window.toolbar = tb
        }
        window.toolbarStyle = .unifiedCompact
        installZoomMonitor(window)
        DispatchQueue.main.async { TitleBand.shared.measure(window) }
        if resizeObserver == nil {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { TitleBand.shared.measure(window) } }
            }
        }
    }
    private var resizeObserver: NSObjectProtocol?

    /// No-op kept for call sites; the hidden title bar is now SwiftUI-managed.
    func reapply() {}

    private func installZoomMonitor(_ window: NSWindow) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak window] event in
            guard let window, event.window === window, event.clickCount >= 2 else { return event }
            // A double-click on a title-band control that uses it (the tab
            // track: double-click renames). The system title bar would zoom the
            // window on any double-click here, so hand the control a plain
            // single click and flag the double-click for it to read.
            let top = (window.contentView?.bounds.height ?? window.frame.height) - event.locationInWindow.y
            let p = CGPoint(x: event.locationInWindow.x, y: top)
            if TitleBarZoomGuard.shared.rects.values.contains(where: { $0.contains(p) }) {
                if event.type == .leftMouseDown { TitleBarZoomGuard.shared.doubleClickPending = true }
                return NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                                          modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                          windowNumber: event.windowNumber, context: nil,
                                          eventNumber: event.eventNumber, clickCount: 1,
                                          pressure: event.pressure) ?? event
            }
            guard event.type == .leftMouseDown, event.clickCount == 2 else { return event }
            if TitleBarZoomGuard.shared.pointerInNoZoomZone { return event }
            let h = window.contentView?.bounds.height ?? window.frame.height
            // Only the top title-bar strip (avoid the traffic-light buttons on the left).
            if event.locationInWindow.y > h - TitleBand.shared.height,
               event.locationInWindow.x > TitleBand.shared.lightsTrailing {
                window.zoom(nil)
                return nil
            }
            return event
        }
    }
}

/// The title-bar row, measured from the real traffic lights: its height (twice
/// the lights' centre from the top, so content centred in it lines up with
/// them) and where the lights end on the left.
@Observable
@MainActor
final class TitleBand {
    static let shared = TitleBand()
    private(set) var height: CGFloat = 38
    private(set) var lightsTrailing: CGFloat = 78

    func measure(_ window: NSWindow) {
        guard let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden,
              let content = window.contentView else { return }
        let r = zoom.convert(zoom.bounds, to: nil)
        let centreFromTop = content.bounds.height - r.midY
        let h = (centreFromTop * 2).rounded()
        let t = r.maxX.rounded()
        if h > 20, abs(h - height) > 0.5 { height = h }
        if abs(t - lightsTrailing) > 0.5 { lightsTrailing = t }
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
    /// Title-band controls that use double-click themselves, in window
    /// coordinates with a top-left origin (SwiftUI's global space).
    var rects: [UUID: CGRect] = [:]
    /// Set when a double-click inside `rects` was turned into a single click.
    var doubleClickPending = false

    /// Read (and clear) the flag.
    func takeDoubleClick() -> Bool {
        defer { doubleClickPending = false }
        return doubleClickPending
    }
}
