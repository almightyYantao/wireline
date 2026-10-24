import SwiftUI
import AppKit

/// Ghostty's quick terminal: a local shell in a panel that slides down from the
/// top of the screen on a global hotkey (⌃` by default) and slides back up on
/// the same key — or when it loses focus. It keeps its own session (not a tab),
/// so whatever you were doing in it is still there next time.
@MainActor
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    private var panel: QuickTerminalPanel?
    private var session: TerminalSession?
    private weak var store: HostStore?
    private var shown = false
    private var resignObserver: Any?

    func attach(_ store: HostStore) { self.store = store }

    func toggle() { shown ? hide() : show() }

    func show() {
        guard let store, let screen = screenUnderMouse() else { return }
        // A shell you `exit`ed is replaced by a fresh one.
        if session == nil || session?.connectionState == .disconnected {
            session?.terminate()
            let s = TerminalSession(kind: .localShell, title: "Quick Terminal", allowsAgent: false)
            s.terminalView.onCloseRequested = { [weak self] in self?.hide() }
            s.start()
            session = s
            panel?.orderOut(nil)
            panel = nil
        }
        guard let session else { return }
        let panel = self.panel ?? makePanel(session: session, store: store)
        self.panel = panel

        let vf = screen.visibleFrame
        let h = (vf.height * min(max(store.quickTerminalHeight, 0.15), 1)).rounded()
        let target = NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
        // Start just above the visible area, same size: only the position
        // animates, so the terminal never reflows mid-slide.
        let start = target.offsetBy(dx: 0, dy: Motion.reduce ? 0 : h * 0.35)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(session.terminalView)
        shown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduce ? 0.15 : 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard shown, let panel else { return }
        shown = false
        let end = panel.frame.offsetBy(dx: 0, dy: Motion.reduce ? 0 : panel.frame.height * 0.35)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.shown == false else { return }   // re-shown meanwhile
                panel.orderOut(nil)
            }
        }
    }

    private func makePanel(session: TerminalSession, store: HostStore) -> QuickTerminalPanel {
        let p = QuickTerminalPanel(contentRect: .zero,
                                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.contentView = NSHostingView(rootView:
            QuickTerminalView(session: session)
                .environment(store)
                .environment(Localizer.shared))
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store?.quickTerminalAutohide ?? true else { return }
                self.hide()
            }
        }
        return p
    }

    private func screenUnderMouse() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }
}

/// Borderless panels can't become key by default; the quick terminal must.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickTerminalView: View {
    @Environment(HostStore.self) private var store
    let session: TerminalSession

    var body: some View {
        let _ = Palette.shared.version
        TerminalHostView(session: session)
            .wlTerminalPadding(store)
            .background(WL.bg.opacity(max(0.88, store.terminalOpacity)))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: WL.radius(14),
                                              bottomTrailingRadius: WL.radius(14), style: .continuous))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: WL.radius(14),
                                            bottomTrailingRadius: WL.radius(14), style: .continuous)
                .strokeBorder(WL.hairline, lineWidth: 1))
            .preferredColorScheme(WL.colorScheme)
    }
}
