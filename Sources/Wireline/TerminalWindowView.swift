import SwiftUI
import AppKit
import SwiftTerm
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
        let term = session.terminalView
        let container = TerminalContainerView(term: term)
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
        let theme = store.terminalTheme ?? .wireline
        let font = store.terminalFontName.flatMap { NSFont(name: $0, size: store.terminalFontSize) }
            ?? TerminalFont.preferred(size: store.terminalFontSize)
            ?? .monospacedSystemFont(ofSize: store.terminalFontSize, weight: .regular)
        session.terminalView.applyAppearance(TerminalAppearance(
            theme: theme, font: font, gpu: store.terminalGPU,
            cursorShape: store.terminalCursorShape, cursorBlink: store.terminalCursorBlink))

        // The app-wide wallpaper sits behind everything; the container stays
        // clear so the enclosing panel's translucent layer shows through.
        container.layer?.contents = nil
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
    }
}

// MARK: - Smooth resizing

/// Hosts a terminal view and lets its grid size be *frozen* while the
/// surrounding layout animates (sidebar, AI panel, broadcast bar). SwiftTerm
/// reflows on every `setFrameSize` and each reflow sends SIGWINCH to the remote
/// shell, so animating the real frame would rewrap ~20 times and make the
/// remote prompt redraw over and over. Instead the terminal keeps its size
/// (clipped, pinned bottom-left), and when the animation ends it is resized
/// once, with a snapshot of the old frame cross-fading over the single reflow.
final class TerminalContainerView: NSView {
    let term: NSView
    private var frozenSize: NSSize?
    /// While frozen, the old frame is shown as a split snapshot (see
    /// `SplitSnapshotView`) and the live terminal sits hidden underneath.
    private var cover: SplitSnapshotView?
    /// The themed overlay scrollbar, a sibling above the terminal (and above
    /// the freeze cover, so it doesn't blink during a layout animation — the
    /// frozen grid's scroll state can't change under it anyway).
    let scrollbar: TerminalScrollbar?
    private static let scrollbarWidth: CGFloat = 16

    init(term: NSView) {
        self.term = term
        let engine = term as? any TerminalEngine
        scrollbar = engine.map { _ in TerminalScrollbar(frame: .zero) }
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
        term.translatesAutoresizingMaskIntoConstraints = true
        term.autoresizingMask = []
        addSubview(term)
        if let engine, let scrollbar {
            scrollbar.term = engine
            // The newest host of a re-embedded terminal takes it over.
            engine.onScrollChange = { [weak scrollbar] in scrollbar?.reflectScroll() }
            addSubview(scrollbar, positioned: .above, relativeTo: term)
        }
        TerminalResizeGate.shared.register(self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // A drag resizes live, like Terminal.app — never frozen.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        commit(animated: false)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layoutTerminal()
    }

    /// When the container last changed size by a visible amount (≥ 0.5pt) —
    /// the gate waits for this to go quiet before committing.
    private(set) var lastSizeChange: CFTimeInterval = 0

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if abs(bounds.width - oldSize.width) >= 0.5 || abs(bounds.height - oldSize.height) >= 0.5 {
            lastSizeChange = CACurrentMediaTime()
        }
        layoutTerminal()
    }
    override func layout() { super.layout(); layoutTerminal() }

    /// Pending commit for a burst of non-interactive resizes (fullscreen).
    private var burstCommit: DispatchWorkItem?
    private var lastBurstSize: NSSize = .zero
    /// The container size the terminal grid was last committed at. A burst is
    /// "the container moved away from this" — never "terminal ≠ bounds", which
    /// is also true on first attach and at the very moment of a commit.
    private var settledSize: NSSize = .zero

    /// Squeezed to (nearly) nothing — a pane hidden behind a zoomed one. Its
    /// grid stays as it was: reflowing to a sliver would rewrap everything (and
    /// make the shell redraw) only to undo it when the zoom is released.
    private var isCollapsed: Bool { bounds.width < 80 || bounds.height < 48 }

    private func layoutTerminal() {
        // A re-embedded terminal belongs to its new host — and so does its bar.
        guard term.superview === self else { scrollbar?.isHidden = true; return }
        scrollbar?.isHidden = false
        // Pinned to the container's right edge — over the live terminal, the
        // cover's trailing half, or a frozen grid alike.
        let barFrame = CGRect(x: bounds.maxX - Self.scrollbarWidth, y: 0, width: Self.scrollbarWidth, height: bounds.height)
        if let scrollbar, scrollbar.frame != barFrame { scrollbar.frame = barFrame }
        if frozenSize == nil, isCollapsed, settledSize != .zero {
            let origin = NSPoint(x: 0, y: bounds.height - settledSize.height)
            if term.frame.size != settledSize { term.setFrameSize(settledSize) }
            if term.frame.origin != origin { term.setFrameOrigin(origin) }
            return
        }
        // Programmatic size bursts the user isn't dragging — entering / leaving
        // fullscreen, zoom, window tiling — arrive as dozens of frames. Treat
        // them like our own layout animations: hold the grid, reflow once when
        // the size settles.
        if frozenSize == nil, !inLiveResize, settledSize != .zero, bounds.width > 0,
           bounds.size != settledSize {
            freeze()
        }
        if let frozen = frozenSize, !inLiveResize {
            // The hidden terminal keeps its old grid, pinned bottom-left.
            let origin = NSPoint(x: 0, y: bounds.height - frozen.height)
            if term.frame.size != frozen { term.setFrameSize(frozen) }
            if term.frame.origin != origin { term.setFrameOrigin(origin) }
            cover?.frame = bounds
            // Re-arm only when the size actually moved, so ordinary layout passes
            // can't postpone the commit forever. Gate holds commit on their own.
            if TerminalResizeGate.shared.isIdle, bounds.size != lastBurstSize || burstCommit == nil {
                lastBurstSize = bounds.size
                burstCommit?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.commit(animated: true) }
                }
                burstCommit = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        } else {
            if term.frame != bounds { term.frame = bounds }
            if bounds.width > 0, bounds.height > 0 { settledSize = bounds.size }
        }
    }

    /// Hold the grid and put the split snapshot over it.
    func freeze() {
        guard frozenSize == nil, term.superview === self, bounds.width > 0,
              term.frame.width > 0, !Motion.reduce, !inLiveResize else { return }
        frozenSize = term.frame.size
        guard let image = snapshotImage() else { return }
        let v = SplitSnapshotView(image: image)
        v.frame = bounds
        addSubview(v, positioned: .above, relativeTo: term)
        cover = v
        term.alphaValue = 0
    }

    func commit(animated: Bool) {
        burstCommit?.cancel(); burstCommit = nil
        guard frozenSize != nil else { return }
        if isCollapsed, settledSize != .zero {
            // Ended up hidden: drop the cover, keep the old grid (see isCollapsed).
            frozenSize = nil
            cover?.removeFromSuperview(); cover = nil
            term.alphaValue = 1
            layoutTerminal()
            return
        }
        frozenSize = nil
        // Record the target first, so the layout pass below fills the bounds
        // instead of seeing a "new burst" and freezing again.
        settledSize = bounds.size
        let cover = self.cover
        self.cover = nil
        // Under the cover: blank the prompt, reflow once, and tell the shell
        // right away (no throttle wait — the size has settled).
        layoutTerminal()
        let wterm = term as? any TerminalEngine
        let signalled = wterm?.flushPendingResize() ?? false

        guard let cover, animated else {
            cover?.removeFromSuperview()
            term.alphaValue = 1
            return
        }
        let reveal = RevealOnce { [weak self, weak cover] in
            guard let self else { return }
            (self.term as? any TerminalEngine)?.outputObserver = nil
            // The new frame goes fully opaque at once and only the cover fades.
            // Fading both would dip mid-way (two translucent layers over a clear
            // background) — a visible blink. This way unchanged text stays
            // solid; only what moved cross-dissolves.
            self.term.alphaValue = 1
            guard let cover else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cover.animator().alphaValue = 0
            } completionHandler: { [weak cover] in
                MainActor.assumeIsolated { cover?.removeFromSuperview() }
            }
        }
        if signalled, let wterm {
            // Keep the old frame up until the shell's redraw has *finished*:
            // reveal once output has been quiet for 35 ms (p10k can arrive in
            // several chunks — left prompt, right prompt, async segments).
            // Give up after 400 ms (shell didn't redraw).
            let quiet = QuietTimer(interval: 0.035) { reveal.fire() }
            wterm.outputObserver = { quiet.poke() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reveal.fire() }
        } else {
            reveal.fire()
        }
    }

    private func snapshotImage() -> NSImage? {
        // Works under the Metal renderer too (see WirelineTerminalView).
        (term as? any TerminalEngine)?.snapshotImage()
    }
}

/// The frozen terminal frame, split down the middle: the left half rides the
/// leading edge, the right half the trailing edge. Shell prompts are exactly
/// that shape — left segments, blank middle, right-aligned segments — so while
/// the column slides, both ends of the prompt stay in view and in place, and
/// only the empty middle is squeezed or opened up. (A single pinned snapshot
/// would clip or strand the right prompt mid-animation.)
private final class SplitSnapshotView: NSView {
    private let left = NSImageView()
    private let right = NSImageView()
    private let imageWidth: CGFloat

    init(image: NSImage) {
        imageWidth = image.size.width
        super.init(frame: .zero)
        wantsLayer = true
        for (v, align) in [(left, NSImageAlignment.alignBottomLeft), (right, .alignBottomRight)] {
            v.image = image
            v.imageScaling = .scaleNone
            v.imageAlignment = align
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            addSubview(v)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }
    override func layout() { super.layout(); place() }

    private func place() {
        // Each half shows at most half of the image, so a wider column opens a
        // gap in the middle instead of repeating content.
        let half = min(floor(bounds.width / 2), floor(imageWidth / 2))
        left.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        right.frame = NSRect(x: bounds.width - half, y: 0, width: half, height: bounds.height)
    }
}

/// Coordinates freezes across every visible terminal. Call `hold(for:)` right
/// before an animated layout change that resizes terminals; overlapping holds
/// extend the window and all terminals commit together.
@MainActor
final class TerminalResizeGate {
    static let shared = TerminalResizeGate()
    private var containers: [WeakContainer] = []
    private var deadline: DispatchTime = .now()
    private var pending: DispatchWorkItem?
    /// No hold in progress — containers may run their own burst commits.
    var isIdle: Bool { pending == nil }

    private struct WeakContainer { weak var view: TerminalContainerView? }

    func register(_ c: TerminalContainerView) {
        containers.removeAll { $0.view == nil }
        containers.append(WeakContainer(view: c))
    }

    /// Freeze terminal grids for `duration` (the layout animation's length).
    func hold(for duration: Double = 0.34) {
        containers.removeAll { $0.view == nil }
        if Motion.reduce { return }   // no layout animation → nothing to smooth
        containers.forEach { $0.view?.freeze() }
        let end = DispatchTime.now() + duration
        guard end > deadline || pending == nil else { return }
        deadline = end
        pending?.cancel()
        schedule(at: end, started: CACurrentMediaTime())
    }

    /// Commit once every container has stopped moving — a spring's tail runs
    /// past its nominal duration, and committing mid-tail means a second reflow
    /// (and a second SIGWINCH) a moment later. Capped so it can't wait forever.
    private func schedule(at when: DispatchTime, started: CFTimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let moving = self.containers.contains { ($0.view?.lastSizeChange ?? 0) > now - 0.06 }
                if moving, now - started < 1.2 {
                    self.schedule(at: .now() + 0.06, started: started)
                    return
                }
                self.pending = nil
                self.containers.forEach { $0.view?.commit(animated: true) }
            }
        }
        pending?.cancel()
        pending = work
        DispatchQueue.main.asyncAfter(deadline: when, execute: work)
    }
}

/// Run an animated layout change that resizes terminals: freeze their grids,
/// animate, then reflow each terminal exactly once.
@MainActor
func wlAnimateTerminalLayout(_ animation: Animation = Motion.disclose, duration: Double = 0.34,
                             _ body: () -> Void) {
    if Motion.reduce { wlSnap(body); return }
    TerminalResizeGate.shared.hold(for: duration)
    withAnimation(animation, body)
}

/// Runs its action at most once, from whichever trigger comes first.
private final class RevealOnce: @unchecked Sendable {
    private var action: (@MainActor () -> Void)?
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func fire() {
        MainActor.assumeIsolated {
            guard let a = action else { return }
            action = nil
            a()
        }
    }
}

/// Fires `action` once no `poke()` has arrived for `interval`.
private final class QuietTimer: @unchecked Sendable {
    private let interval: TimeInterval
    private let action: () -> Void
    private var work: DispatchWorkItem?
    init(interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = interval; self.action = action
    }
    func poke() {
        work?.cancel()
        let w = DispatchWorkItem { [action] in action() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: w)
    }
}

extension View {
    /// Breathing room between the terminal grid and the panel edges (Ghostty's
    /// window-padding-x / -y). The padding is part of the terminal's tinted
    /// area, so it reads as margin, not as a border.
    func wlTerminalPadding(_ store: HostStore) -> some View {
        padding(.horizontal, store.terminalPaddingX).padding(.vertical, store.terminalPaddingY)
    }
}

/// Overlays currently covering terminals (host drawer, floating AI panel).
/// SwiftTerm watches mouse movement window-wide, so a terminal *under* an
/// overlay would keep reporting the pointer to htop / vim / tmux as it moves
/// over the overlay. While any overlay is up, mouse reporting is paused.
@MainActor
final class TerminalOcclusion {
    static let shared = TerminalOcclusion()
    /// Each overlay's frame, in SwiftUI global (window, top-left) coordinates.
    private var rects: [UUID: CGRect] = [:]

    func set(_ id: UUID, _ r: CGRect?) {
        guard rects[id] != r else { return }
        rects[id] = r
        apply()
    }

    /// Pause only the terminals an overlay actually covers — a card left up in
    /// some other pane or tab mustn't take the mouse from every terminal.
    private func apply() {
        for w in NSApp.windows {
            guard let root = w.contentView else { continue }
            var stack: [NSView] = [root]
            while let v = stack.popLast() {
                if let t = v as? any TerminalEngine {
                    let f = v.convert(v.bounds, to: root)
                    let frame = root.isFlipped ? f : CGRect(x: f.minX, y: root.bounds.height - f.maxY,
                                                            width: f.width, height: f.height)
                    let covered = v.window != nil && !v.isHiddenOrHasHiddenAncestor
                        && rects.values.contains { $0.intersects(frame) }
                    if t.allowMouseReporting == covered { t.allowMouseReporting = !covered }
                }
                stack.append(contentsOf: v.subviews)
            }
        }
    }
}

extension View {
    /// Register this view's frame as covering the terminals beneath it.
    func wlOccludesTerminal() -> some View { modifier(OccluderModifier()) }
}

private struct OccluderModifier: ViewModifier {
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { TerminalOcclusion.shared.set(id, g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { _, f in TerminalOcclusion.shared.set(id, f) }
            })
            .onDisappear { TerminalOcclusion.shared.set(id, nil) }
    }
}
