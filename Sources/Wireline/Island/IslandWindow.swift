import AppKit
import SwiftUI
import Observation
import WirelineCore

/// The island's sizes for each mode, around the notch (or, without one, a
/// virtual notch inside the pill under the menu bar).
struct IslandLayout: Equatable {
    /// The notch — or the pill minus its ears.
    var core: CGSize
    var hasNotch: Bool
    /// The notch's centre, in panel coordinates.
    var centerX: CGFloat
    /// The panel's size (room for the biggest card plus its shadow).
    var panel: CGSize

    /// Each ear's width beside the notch.
    static let ear: CGFloat = 34
    static let cardWidth: CGFloat = 400
    /// Taller lists scroll.
    static let maxListHeight: CGFloat = 400
    /// The strip below the notch a pulse uses.
    static let pulseStrip: CGFloat = 30
    static let panelSize = CGSize(width: 460, height: 520)

    static let fallback = IslandLayout(
        core: CGSize(width: NotchGeometry.pillSize.width - 2 * ear, height: NotchGeometry.pillSize.height),
        hasNotch: false, centerX: panelSize.width / 2, panel: panelSize)

    /// The black shape's size.
    func size(_ mode: IslandMode, list: CGFloat) -> CGSize {
        let collapsed = CGSize(width: core.width + 2 * Self.ear, height: core.height)
        switch mode {
        case .hidden, .dormant: return core
        case .collapsed: return collapsed
        case .pulse: return CGSize(width: max(collapsed.width, 300), height: core.height + Self.pulseStrip)
        case .expanded:
            return CGSize(width: max(collapsed.width, Self.cardWidth),
                          height: core.height + min(max(list, 44), Self.maxListHeight))
        }
    }

    /// Top flare (the notch's concave shoulders), top and bottom corner radii.
    func radii(_ mode: IslandMode) -> (flare: CGFloat, top: CGFloat, bottom: CGFloat) {
        let bottom: CGFloat = switch mode {
        case .hidden, .dormant, .collapsed: hasNotch ? 10 : core.height / 2
        case .pulse: 16
        case .expanded: 24
        }
        return hasNotch ? (flare: mode == .expanded ? 10 : 6, top: 0, bottom: bottom)
                        : (flare: 0, top: mode == .expanded ? 20 : bottom, bottom: bottom)
    }
}

/// A panel that never takes key or main status: clicking the island leaves
/// the user's focus where it was.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // AppKit pushes windows below the menu bar; the island belongs *in* it,
    // hugging the notch, so take the frame exactly as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets the first click on a non-key panel land on its buttons.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the island's window: a borderless, non-activating panel at the top
/// centre of the screen, above the menu bar, on every Space and over
/// full-screen apps. It's transparent and ignores the mouse except over the
/// black shape, so the menu bar beneath keeps working.
@Observable
@MainActor
final class IslandController {
    static let shared = IslandController()

    private(set) var layout = IslandLayout.fallback
    /// The expanded list's natural height (measured by the view).
    var listHeight: CGFloat = 0

    @ObservationIgnored private var panel: IslandPanel?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hoverWork: DispatchWorkItem?
    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored private var started = false

    private init() {}

    nonisolated static let panelID = NSUserInterfaceItemIdentifier("wireline.notch-island")

    private var center: IslandCenter { IslandCenter.shared }

    func start(sessions: SessionStore) {
        center.sessions = sessions
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let fromIsland = (note.object as? NSWindow)?.identifier == IslandController.panelID
                MainActor.assumeIsolated {
                    guard let self, !fromIsland else { return }
                    self.refresh()
                }
            })
        }
        // Hover is tracked here, not with SwiftUI's onHover: the panel ignores
        // the mouse outside the shape, so it never sees the pointer arrive.
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return e
        }) { monitors.append(m) }
        track()
        refresh()
    }

    /// Re-run whenever what's shown changes.
    private func track() {
        withObservationTracking {
            _ = center.mode
            _ = listHeight
            _ = IslandSettings.shared.enabled
            _ = IslandSettings.shared.alwaysShow
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.modeChanged()
                    self?.track()
                }
            }
        }
    }

    // MARK: - Placement

    /// The screen you're on: the one under the pointer. There the island hugs
    /// the notch, or sits as a pill at the top on a screen without one. (Keyed
    /// to Wireline's window it jumped away whenever another app had focus.)
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return s }
        if let key = NSApp.keyWindow, key !== panel, let s = key.screen { return s }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first { Self.isBuiltIn($0) }
            ?? NSScreen.main
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(n.uint32Value) != 0
    }

    /// Re-place the panel (screen, notch) and show / hide it.
    func refresh() {
        guard started else { return }
        guard IslandSettings.shared.enabled, let screen = targetScreen() else {
            hide(immediately: true)
            return
        }
        let g = NotchGeometry.resolve(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                      safeAreaTop: screen.safeAreaInsets.top,
                                      auxiliaryLeft: screen.auxiliaryTopLeftArea,
                                      auxiliaryRight: screen.auxiliaryTopRightArea)
        geometry = g
        placedScreen = screen.frame
        let frame = g.panelFrame(cardSize: IslandLayout.panelSize, in: screen.frame)
        let core = g.hasNotch ? g.anchor.size
            : CGSize(width: g.anchor.width - 2 * IslandLayout.ear, height: g.anchor.height)
        let new = IslandLayout(core: core, hasNotch: g.hasNotch, centerX: g.anchor.midX - frame.minX,
                               panel: frame.size)
        if new != layout { layout = new }
        let panel = panel ?? makePanel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        modeChanged()
    }

    private func makePanel() -> IslandPanel {
        let p = IslandPanel(contentRect: CGRect(origin: .zero, size: IslandLayout.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Above the menu bar (the island is drawn over it), below menus and alerts.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                 // the shape draws its own
        p.animationBehavior = .none
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = true
        p.isExcludedFromWindowsMenu = true
        p.identifier = Self.panelID
        p.appearance = NSAppearance(named: .darkAqua)   // the island is part of the (black) notch
        let host = IslandHostingView(rootView: IslandRootView())
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    // MARK: - Show / hide

    private var isShowable: Bool {
        guard IslandSettings.shared.enabled, let g = geometry else { return false }
        switch center.mode {
        case .hidden: return false
        case .dormant: return g.hasNotch          // an invisible, hoverable notch
        default: return true
        }
    }

    private func modeChanged() {
        guard let panel else { return }
        if isShowable {
            hideWork?.cancel(); hideWork = nil
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            hide(immediately: false)
        }
        pointerMoved()
    }

    /// Order out once the fade-out has played.
    private func hide(immediately: Bool) {
        center.hovering = false
        guard let panel, panel.isVisible, hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                if !self.isShowable { self.panel?.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.35), execute: work)
    }

    // MARK: - Pointer

    /// The black shape's rect on screen, slightly inflated so the bare notch
    /// is easy to hit.
    private func hotRect() -> CGRect? {
        guard let panel, panel.isVisible, let g = geometry else { return nil }
        let size = layout.size(center.mode, list: listHeight)
        let rect = CGRect(x: g.anchor.midX - size.width / 2, y: panel.frame.maxY - size.height,
                          width: size.width, height: size.height)
        switch center.mode {
        case .hidden: return nil
        case .dormant, .collapsed, .pulse: return rect.insetBy(dx: -6, dy: -4)
        case .expanded: return rect
        }
    }

    /// The screen the island was last placed on.
    private var placedScreen: CGRect?

    private func pointerMoved() {
        // Follow the pointer to another display.
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           s.frame != placedScreen, !center.hovering {
            refresh()
        }
        guard let panel else { return }
        let inside = hotRect()?.contains(NSEvent.mouseLocation) ?? false
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != center.hovering else { hoverWork?.cancel(); hoverWork = nil; return }
        guard hoverWork == nil else { return }
        // In quickly (a beat, so sweeping past the notch doesn't pop it open);
        // out after a short grace, so a slip off the edge doesn't fold it.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverWork = nil
                let now = self.hotRect()?.contains(NSEvent.mouseLocation) ?? false
                if now != self.center.hovering { self.center.hovering = now }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.08 : 0.45), execute: work)
    }
}
