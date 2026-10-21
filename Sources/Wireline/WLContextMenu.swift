import SwiftUI
import AppKit
import Observation

/// One entry in a themed context menu.
struct WLMenuItem: Identifiable {
    let id = UUID()
    var title: String = ""
    var systemImage: String?
    var destructive = false
    var isDivider = false
    var action: () -> Void = {}

    static var divider: WLMenuItem { WLMenuItem(isDivider: true) }
    static func item(_ title: String, systemImage: String? = nil, destructive: Bool = false,
                     _ action: @escaping () -> Void) -> WLMenuItem {
        WLMenuItem(title: title, systemImage: systemImage, destructive: destructive, action: action)
    }
}

/// Shared state for the in-window themed context menu. Behaves like NSMenu:
/// instant highlight, ↑/↓/Return/Esc, the chosen row blinks before the menu
/// fades, and the action runs once the fade starts.
@Observable
@MainActor
final class WLMenuState {
    static let shared = WLMenuState()
    private(set) var items: [WLMenuItem] = []
    private(set) var anchor: CGPoint = .zero
    private(set) var visible = false
    /// The highlighted row (mouse or keyboard — one highlight, like NSMenu).
    var highlighted: UUID?
    /// Where the menu actually sits after clamping to the window.
    var frame: CGRect = .zero
    var menuSize: CGSize = .zero
    private var selecting = false
    private var monitor: Any?

    private var selectable: [WLMenuItem] { items.filter { !$0.isDivider } }

    func show(_ items: [WLMenuItem], at point: CGPoint) {
        self.items = items
        self.anchor = point
        self.highlighted = nil
        self.selecting = false
        wlAnimate(Motion.popIn) { self.visible = true }
        installMonitor()
    }

    func hide() {
        wlAnimate(Motion.popOut) { visible = false }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Blink the chosen row twice, then fade the menu and run the action.
    func select(_ item: WLMenuItem) {
        guard !selecting, !item.isDivider else { return }
        selecting = true
        Task { @MainActor in
            for _ in 0..<2 {
                highlighted = nil
                try? await Task.sleep(for: .milliseconds(55))
                highlighted = item.id
                try? await Task.sleep(for: .milliseconds(55))
            }
            hide()
            item.action()
        }
    }

    private func move(_ delta: Int) {
        let rows = selectable
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == highlighted }
        let next: Int
        if let i { next = (i + delta + rows.count) % rows.count }
        else { next = delta > 0 ? 0 : rows.count - 1 }
        highlighted = rows[next].id
    }

    /// Dismiss on any click outside the menu (the event still passes through so
    /// an outside right-click opens a fresh menu); drive it from the keyboard.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.visible else { return event }
            if event.type == .keyDown {
                switch event.keyCode {
                case 125: self.move(1)                                   // ↓
                case 126: self.move(-1)                                  // ↑
                case 36, 76:                                             // Return / Enter
                    if let id = self.highlighted, let item = self.items.first(where: { $0.id == id }) {
                        self.select(item)
                    }
                case 53: self.hide()                                     // Esc
                default: return event
                }
                return nil
            }
            guard let content = event.window?.contentView else { return event }
            let p = content.convert(event.locationInWindow, from: nil)
            let y = content.isFlipped ? p.y : content.bounds.height - p.y
            if !self.frame.contains(CGPoint(x: p.x, y: y)) { self.hide() }
            return event
        }
    }
}

extension View {
    /// A dark, monospace, green-accent right-click menu matching the app theme.
    func wlContextMenu(_ items: [WLMenuItem]) -> some View {
        overlay(RightClickCatcher { point in
            WLMenuState.shared.show(items, at: point)
        })
    }

    @ViewBuilder
    func applyWLMenu(_ items: [WLMenuItem]) -> some View {
        if items.isEmpty { self } else { wlContextMenu(items) }
    }

    /// Container-level menu placed *behind* content, so right-clicks on child
    /// rows (which use `wlContextMenu`) take priority; only clicks on empty
    /// space fall through to this one.
    func wlContextMenuBackground(_ items: [WLMenuItem]) -> some View {
        background(RightClickCatcher { point in
            WLMenuState.shared.show(items, at: point)
        })
    }

    /// Hosts the context-menu overlay. Apply once at the window root.
    func wlMenuHost() -> some View { overlay(WLMenuOverlay()) }
}

/// Reports a right-click's position in window (top-left origin) coordinates and
/// suppresses the native menu.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onRightClick: onRightClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: (CGPoint) -> Void
        init(onRightClick: @escaping (CGPoint) -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        // Only claim the hit for right-clicks; pass everything else through so
        // normal left-click / hover on the underlying row keeps working.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp: return self
            default: return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let content = window?.contentView else { return }
            let p = content.convert(event.locationInWindow, from: nil)
            // SwiftUI's hosting view is flipped (top-left origin); only flip when
            // the content view is not, to avoid double-flipping the Y axis.
            let y = content.isFlipped ? p.y : content.bounds.height - p.y
            onRightClick(CGPoint(x: p.x, y: y))
        }
    }
}

/// The overlay that renders the active menu inside the window, kept fully on
/// screen: it flips left / up when the pointer is near the right / bottom edge.
private struct WLMenuOverlay: View {
    @State private var state = WLMenuState.shared
    private let margin: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let placed = placement(in: geo.size)
            ZStack(alignment: .topLeading) {
                if state.visible {
                    WLMenuList(items: state.items, state: state)
                        .fixedSize()
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { state.menuSize = g.size }
                                .onChange(of: g.size) { _, s in state.menuSize = s }
                        })
                        .transition(.wlPop(anchor: placed.anchor))
                        .offset(x: placed.origin.x, y: placed.origin.y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: CGRect(origin: placed.origin, size: state.menuSize), initial: true) { _, r in
                state.frame = r
            }
        }
        // Only the menu itself captures clicks; empty space passes through so a
        // right-click elsewhere can open a new menu (dismissal is via monitor).
        .allowsHitTesting(state.visible)
    }

    private func placement(in bounds: CGSize) -> (origin: CGPoint, anchor: UnitPoint) {
        let size = state.menuSize == .zero ? CGSize(width: 200, height: 240) : state.menuSize
        var x = state.anchor.x - 3, y = state.anchor.y - 3
        var flipX = false, flipY = false
        if x + size.width > bounds.width - margin { x = state.anchor.x - size.width + 3; flipX = true }
        if y + size.height > bounds.height - margin { y = state.anchor.y - size.height + 3; flipY = true }
        x = min(max(margin, x), max(margin, bounds.width - size.width - margin))
        y = min(max(margin, y), max(margin, bounds.height - size.height - margin))
        let anchor: UnitPoint = switch (flipX, flipY) {
        case (false, false): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (true, true): .bottomTrailing
        }
        return (CGPoint(x: x, y: y), anchor)
    }
}

/// The themed menu content.
private struct WLMenuList: View {
    let items: [WLMenuItem]
    let state: WLMenuState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.isDivider {
                    Rectangle().fill(WL.border).frame(height: 1)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                } else {
                    WLMenuRow(item: item, highlighted: state.highlighted == item.id,
                              onHover: { inside in
                                  if inside { state.highlighted = item.id }
                                  else if state.highlighted == item.id { state.highlighted = nil }
                              },
                              onSelect: { state.select(item) })
                }
            }
        }
        .padding(5)
        .frame(minWidth: 186, alignment: .leading)
        .background(WL.surface)
        .clipShape(RoundedRectangle(cornerRadius: WL.radius(9)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(9)).stroke(WL.border, lineWidth: WL.borderWidth))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .shadow(color: .black.opacity(WL.depth(0.35)), radius: 16, y: 8)
    }
}

/// One row. Highlight is instant — no fade — exactly like a native menu.
private struct WLMenuRow: View {
    let item: WLMenuItem
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    private var fg: Color {
        if item.destructive { return highlighted ? WL.red : WL.red.opacity(0.85) }
        return highlighted ? WL.greenBright : WL.textPrimary
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = item.systemImage {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
            }
            Text(item.title).font(WL.body)
            Spacer(minLength: 12)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? (item.destructive ? WL.red : WL.green).opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: WL.radius(5)))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onSelect)
    }
}
