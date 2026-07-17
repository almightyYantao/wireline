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

/// Shared state for the in-window themed context menu.
@Observable
@MainActor
final class WLMenuState {
    static let shared = WLMenuState()
    private(set) var items: [WLMenuItem] = []
    private(set) var anchor: CGPoint = .zero
    private(set) var visible = false
    var menuSize: CGSize = .zero
    private var monitor: Any?

    func show(_ items: [WLMenuItem], at point: CGPoint) {
        self.items = items
        self.anchor = point
        self.visible = true
        installMonitor()
    }

    func hide() {
        visible = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Dismiss on any click outside the menu. Returns the event so an outside
    /// right-click still reaches the row catcher and opens a fresh menu.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.visible, let content = event.window?.contentView else { return event }
            let p = content.convert(event.locationInWindow, from: nil)
            let y = content.isFlipped ? p.y : content.bounds.height - p.y
            let size = self.menuSize == .zero ? CGSize(width: 200, height: 360) : self.menuSize
            if !CGRect(origin: self.anchor, size: size).contains(CGPoint(x: p.x, y: y)) {
                self.hide()
            }
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

/// The overlay that renders the active menu inside the window.
private struct WLMenuOverlay: View {
    @State private var state = WLMenuState.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.visible {
                WLMenuList(items: state.items, onSelect: { state.hide() })
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { state.menuSize = g.size }
                            .onChange(of: g.size) { state.menuSize = $0 }
                    })
                    .offset(x: max(0, state.anchor.x - 3), y: max(0, state.anchor.y - 3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Only the menu itself captures clicks; empty space passes through so a
        // right-click elsewhere can open a new menu (dismissal is via monitor).
        .allowsHitTesting(state.visible)
    }
}

/// The themed menu content.
private struct WLMenuList: View {
    let items: [WLMenuItem]
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.isDivider {
                    Rectangle().fill(WL.border).frame(height: 1).padding(.vertical, 4)
                } else {
                    WLMenuRow(item: item, onSelect: onSelect)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 176, alignment: .leading)
        .background(WL.surface)
        .clipShape(RoundedRectangle(cornerRadius: WL.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: WL.radius(8)).stroke(WL.border, lineWidth: WL.borderWidth))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

private struct WLMenuRow: View {
    let item: WLMenuItem
    let onSelect: () -> Void
    @State private var hover = false

    private var fg: Color {
        if item.destructive { return hover ? WL.red : WL.red.opacity(0.85) }
        return hover ? WL.greenBright : WL.textPrimary
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
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? WL.green.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { item.action(); onSelect() }
    }
}
