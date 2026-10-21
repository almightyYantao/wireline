import SwiftUI
import AppKit

/// One entry in a context menu.
struct WLMenuItem: Identifiable {
    let id = UUID()
    var title: String = ""
    var systemImage: String?
    var destructive = false
    var isDivider = false
    /// Shows a checkmark (e.g. the current colour label).
    var checked = false
    /// Non-empty = a submenu.
    var children: [WLMenuItem] = []
    var action: () -> Void = {}

    static var divider: WLMenuItem { WLMenuItem(isDivider: true) }
    static func item(_ title: String, systemImage: String? = nil, destructive: Bool = false,
                     checked: Bool = false, _ action: @escaping () -> Void) -> WLMenuItem {
        WLMenuItem(title: title, systemImage: systemImage, destructive: destructive, checked: checked, action: action)
    }
    static func submenu(_ title: String, systemImage: String? = nil, _ children: [WLMenuItem]) -> WLMenuItem {
        WLMenuItem(title: title, systemImage: systemImage, children: children)
    }
}

extension View {
    /// A right-click menu. It's a real NSMenu: native material, light/dark,
    /// placement at the pointer (flipping at screen edges), keyboard navigation,
    /// the selection blink and submenus — everything a hand-drawn overlay menu
    /// only imitated.
    func wlContextMenu(_ items: [WLMenuItem]) -> some View {
        overlay(RightClickCatcher(items: items))
    }

    @ViewBuilder
    func applyWLMenu(_ items: [WLMenuItem]) -> some View {
        if items.isEmpty { self } else { wlContextMenu(items) }
    }

    /// Container-level menu placed *behind* content, so right-clicks on child
    /// rows (which use `wlContextMenu`) take priority; only clicks on empty
    /// space fall through to this one.
    func wlContextMenuBackground(_ items: [WLMenuItem]) -> some View {
        background(RightClickCatcher(items: items))
    }

    /// Formerly hosted the drawn menu overlay; native menus need no host.
    func wlMenuHost() -> some View { self }
}

/// Catches right-clicks (and ctrl-clicks) over its area and pops the menu.
private struct RightClickCatcher: NSViewRepresentable {
    let items: [WLMenuItem]

    func makeNSView(context: Context) -> NSView { CatcherView(items: items) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.items = items
    }

    final class CatcherView: NSView {
        var items: [WLMenuItem]
        private var targets: [MenuActionTarget] = []

        init(items: [WLMenuItem]) {
            self.items = items
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        // Only claim the hit for right-clicks; pass everything else through so
        // normal left-click / hover on the underlying view keeps working.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            switch e.type {
            case .rightMouseDown, .rightMouseUp: return super.hitTest(point)
            case .leftMouseDown where e.modifierFlags.contains(.control): return super.hitTest(point)
            default: return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            targets = []
            return build(items)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {   // ctrl-click
            rightMouseDown(with: event)
        }

        private func build(_ items: [WLMenuItem]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                if item.isDivider { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                if let s = item.systemImage {
                    mi.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
                }
                if item.checked { mi.state = .on }
                if item.destructive {
                    mi.attributedTitle = NSAttributedString(string: item.title,
                                                            attributes: [.foregroundColor: NSColor.systemRed])
                }
                if !item.children.isEmpty {
                    mi.submenu = build(item.children)
                } else {
                    let t = MenuActionTarget(item.action)
                    targets.append(t)
                    mi.target = t
                    mi.action = #selector(MenuActionTarget.fire)
                }
                menu.addItem(mi)
            }
            return menu
        }
    }
}

private final class MenuActionTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
