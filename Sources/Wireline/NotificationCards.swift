import AppKit
import Observation
import SwiftUI
import WirelineCore

/// Settings for Wireline's own notification cards.
@Observable
@MainActor
final class CardSettings {
    static let shared = CardSettings()

    var linger: CardLinger {
        didSet { d.set(linger.rawValue, forKey: "notifyCardLinger") }
    }
    /// Also show a card (next to the system notification) while Wireline is in the background.
    var cardsInBackground: Bool {
        didSet { d.set(cardsInBackground, forKey: "notifyCardsInBackground") }
    }

    @ObservationIgnored private let d = UserDefaults.standard

    private init() {
        linger = CardLinger(stored: d.string(forKey: "notifyCardLinger"))
        cardsInBackground = d.bool(forKey: "notifyCardsInBackground")
    }
}

/// Shows notification cards under the notch island (or, with the island off,
/// at the main window's top-right). Closing a card only hides it: it never
/// answers a request or touches agent state.
@Observable
@MainActor
final class CardCenter {
    static let shared = CardCenter()

    private(set) var queue = CardQueue(maxVisible: 3)
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private lazy var window = CardWindow()

    /// Single entry for every `Notifier.post`.
    func route(title: String, body: String, session: UUID?) {
        let foreground = NSApp.isActive
        if !foreground { Notifier.postSystem(title: title, body: body, session: session) }
        if foreground || CardSettings.shared.cardsInBackground { show(title: title, body: body, session: session) }
    }

    func show(title: String, body: String, session: UUID?) {
        advance()
        queue.push(NotificationCard(title: title, body: body, session: session, linger: CardSettings.shared.linger))
        changed()
    }

    func close(_ id: UUID) {
        advance()
        queue.close(id)
        changed()
    }

    func open(_ card: NotificationCard) {
        close(card.id)
        NotificationRouter.open(card.session)
    }

    func setHovering(_ on: Bool) {
        advance()
        queue.paused = on
        changed()
    }

    private func advance() {
        let now = Date()
        queue.tick(now.timeIntervalSince(lastTick))
        lastTick = now
    }

    private func changed() {
        timer?.cancel()
        if let wait = queue.nextExpiry {
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.advance(); self?.changed() }
            }
            timer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05, execute: w)
        }
        window.update(empty: queue.visible.isEmpty)
    }
}

private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
private final class CardWindow {
    static let width: CGFloat = 340
    private var panel: CardPanel?

    func update(empty: Bool) {
        guard !empty else { panel?.orderOut(nil); return }
        let p = panel ?? make()
        panel = p
        guard let host = p.contentView else { return }
        let size = host.fittingSize
        p.setFrame(frame(for: CGSize(width: Self.width, height: max(1, size.height))), display: true)
        p.orderFrontRegardless()
    }

    private func make() -> CardPanel {
        let p = CardPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 10),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: CardStack().frame(width: Self.width))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && $0.level == .normal && $0.title == "Wireline" && $0.isVisible }
    }

    private func frame(for size: CGSize) -> CGRect {
        let main = mainWindow
        if !IslandSettings.shared.enabled, let w = main, !w.isMiniaturized {
            let f = w.frame
            return CGRect(x: f.maxX - size.width - 12, y: f.maxY - 40 - size.height,
                          width: size.width, height: size.height)
        }
        let screen = main?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let g = NotchGeometry.resolve(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                      safeAreaTop: screen.safeAreaInsets.top,
                                      auxiliaryLeft: screen.auxiliaryTopLeftArea,
                                      auxiliaryRight: screen.auxiliaryTopRightArea)
        let x = min(max(g.anchor.midX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        return CGRect(x: x.rounded(), y: g.anchor.minY - 6 - size.height, width: size.width, height: size.height)
    }
}

private struct CardStack: View {
    @State private var center = CardCenter.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(center.queue.visible) { CardRow(card: $0) }
            if !center.queue.pending.isEmpty {
                Text(Localizer.shared.t("还有 \(center.queue.pending.count) 条", "\(center.queue.pending.count) more"))
                    .font(WL.caption).foregroundStyle(WL.textDim)
            }
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { center.setHovering($0) }
        .environment(\.colorScheme, WL.colorScheme)
    }
}

private struct CardRow: View {
    let card: NotificationCard
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title).font(WL.body.bold()).foregroundStyle(WL.textPrimary).lineLimit(2)
                if !card.body.isEmpty {
                    Text(card.body).font(WL.small).foregroundStyle(WL.textDim).lineLimit(4)
                }
                if let place = source {
                    Text(place).font(WL.caption).foregroundStyle(WL.green).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { CardCenter.shared.close(card.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WL.textDim).frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Localizer.shared.t("关闭", "Close"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(WL.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? WL.green : WL.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { CardCenter.shared.open(card) }
        .onHover { hover = $0 }
    }

    private var source: String? {
        guard let id = card.session, let s = IslandCenter.shared.sessions?.session(id) else { return nil }
        return s.title
    }
}
