import SwiftUI
import AppKit

// The in-window modal presenter. Every dialog in the app (host editor, theme
// editor, backup, the Settings sub-dialogs, ⌘K / ⌘P …) goes through here
// instead of `.sheet`: a system sheet always slides down out of the title bar
// and can't be animated, while these flip in as a card over a dim scrim
// (docs/design/motion-spec.md §4.10).
//
//   .wlModal(isPresented: $show) { SomeSheet() }
//   .wlModal(item: $editing) { item in SomeSheet(item) }
//
// A `.wlModal` only *announces* its dialog (a preference); the window root's
// `.wlModalHost()` draws it, so a dialog opened from a small sub-view (a tool
// page, the AI panel) still covers the whole window. Without a host above it,
// the presenter hosts the dialog itself over its own bounds.
//
// Inside the dialog, close it with `@Environment(\.wlDismiss)` — the system
// `dismiss` would close the *window*.

/// How a modal behaves around its card.
struct WLModalStyle: Sendable, Equatable {
    /// Esc closes it (forms, editors). Off for surfaces that use Esc
    /// themselves — the palettes step back out of a sub-page first.
    var escapeCloses = true
    /// A click on the scrim closes it. Off for forms, so a stray click
    /// can't throw away what was typed.
    var scrimCloses = false

    static let sheet = WLModalStyle()
    /// Keyboard launchers (⌘K, ⌘P): click outside to close, Esc handled inside.
    static let palette = WLModalStyle(escapeCloses: false, scrimCloses: true)
}

/// Closes the modal the view is in (`@Environment(\.wlDismiss)`).
struct WLDismissAction {
    fileprivate var action: (@MainActor () -> Void)?
    @MainActor func callAsFunction() { action?() }
}

private struct WLDismissKey: EnvironmentKey {
    static var defaultValue: WLDismissAction { WLDismissAction(action: nil) }
}

private struct WLModalHostedKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var wlDismiss: WLDismissAction {
        get { self[WLDismissKey.self] }
        set { self[WLDismissKey.self] = newValue }
    }
    /// True under a `.wlModalHost()`: presenters announce, the host draws.
    fileprivate var wlModalHosted: Bool {
        get { self[WLModalHostedKey.self] }
        set { self[WLModalHostedKey.self] = newValue }
    }
}

extension View {
    /// Present `content` as an in-window modal card while `isPresented`.
    func wlModal<Content: View>(isPresented: Binding<Bool>, style: WLModalStyle = .sheet,
                                @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(WLModalPresenter(item: isPresented.wrappedValue ? true : nil,
                                  key: { _ in AnyHashable(0) },
                                  style: style,
                                  dismiss: { wlAnimate(Motion.flipOut) { isPresented.wrappedValue = false } },
                                  modal: { _ in content() }))
    }

    /// Present `content` for `item` while it's non-nil. A different item
    /// flips the old card out and the new one in.
    func wlModal<Item: Identifiable, Content: View>(item: Binding<Item?>, style: WLModalStyle = .sheet,
                                                    @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        modifier(WLModalPresenter(item: item.wrappedValue,
                                  key: { AnyHashable($0.id) },
                                  style: style,
                                  dismiss: { wlAnimate(Motion.flipOut) { item.wrappedValue = nil } },
                                  modal: content))
    }

    /// Draw the modals presented anywhere below this view, covering it. Put it
    /// on every window's root view.
    func wlModalHost() -> some View { modifier(WLModalHost(depth: 0)) }

    /// Focus a dialog's first field once it's on screen. Deferred a turn so it
    /// lands after the presenter has taken focus away from the window beneath.
    func wlAutofocus(_ focus: FocusState<Bool>.Binding) -> some View {
        onAppear { DispatchQueue.main.async { focus.wrappedValue = true } }
    }
}

// MARK: - Plumbing

struct WLModalEntry: Identifiable {
    let id: AnyHashable
    let style: WLModalStyle
    let content: AnyView
    let dismiss: @MainActor () -> Void
    /// The dialog is on its way out: the card folds shut, then it's removed.
    var closing = false
}

struct WLModalKey: PreferenceKey {
    static var defaultValue: [WLModalEntry] { [] }
    static func reduce(value: inout [WLModalEntry], nextValue: () -> [WLModalEntry]) {
        value.append(contentsOf: nextValue())
    }
}

private struct WLModalPresenter<Item, Modal: View>: ViewModifier {
    let item: Item?
    let key: (Item) -> AnyHashable
    let style: WLModalStyle
    let dismiss: @MainActor () -> Void
    let modal: (Item) -> Modal
    @State private var token = UUID()
    @Environment(\.wlModalHosted) private var hosted
    /// The last item shown, kept on screen while its card folds shut — the
    /// close animates the same however the binding was cleared (Esc, a
    /// button, the scrim, code), because the card plays it itself rather than
    /// relying on a removal transition through the preference.
    @State private var lingering: Item?
    @State private var closing = false
    @State private var closeWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        let shown = item ?? (closing ? lingering : nil)
        let entry = shown.map { item in
            WLModalEntry(id: AnyHashable([AnyHashable(token), key(item)]), style: style,
                         content: AnyView(modal(item)), dismiss: dismiss, closing: self.item == nil)
        }
        // Append, never overwrite: dialogs presented further down the tree
        // travel up through this same key.
        let announced = content.transformPreference(WLModalKey.self) { value in
            if let entry { value.append(entry) }
        }
        let tracked = announced
            .onAppear { if let item { lingering = item } }
            .onChange(of: item != nil) { _, present in
                closeWork?.cancel(); closeWork = nil
                if present {
                    lingering = item
                    closing = false
                } else if lingering != nil {
                    closing = true
                    let work = DispatchWorkItem {
                        MainActor.assumeIsolated { closing = false; lingering = nil }
                    }
                    closeWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + WLModalMotion.closeDuration + 0.03, execute: work)
                }
            }
        if hosted {
            tracked
        } else {
            tracked.modifier(WLModalHost(depth: 0))
        }
    }
}

/// The open / close motion of a dialog card, played by the card itself.
enum WLModalMotion {
    static let closeDuration = 0.26
}

/// Reads the modals announced below it and draws them in an overlay. The
/// stack it draws carries a host of its own, so a dialog opened from inside a
/// dialog (MCP list → server editor) stacks over the whole window too.
private struct WLModalHost: ViewModifier {
    let depth: Int

    func body(content: Content) -> some View {
        content
            .environment(\.wlModalHosted, true)
            .overlayPreferenceValue(WLModalKey.self) { entries in
                WLModalStack(entries: entries, depth: depth)
            }
            // Handled here; don't let them reach a host further up.
            .transformPreference(WLModalKey.self) { $0.removeAll() }
    }
}

private struct WLModalStack: View {
    /// Dialogs inside dialogs, at most this deep.
    static let maxDepth = 3
    let entries: [WLModalEntry]
    let depth: Int

    var body: some View {
        let layers = ZStack {
            ForEach(entries) { entry in
                WLModalScrim(entry: entry)
                WLModalCard(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if depth < Self.maxDepth {
            layers.modifier(WLModalHost(depth: depth + 1))
        } else {
            layers
        }
    }
}

private struct WLModalScrim: View {
    let entry: WLModalEntry
    @State private var shown = false

    var body: some View {
        Color.black.opacity(WL.depth(0.38))
            .opacity(shown && !entry.closing ? 1 : 0)
            .onAppear { withAnimation(Motion.resolved(Motion.state)) { shown = true } }
            .animation(Motion.resolved(Motion.flipOut), value: entry.closing)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { if entry.style.scrimCloses { entry.dismiss() } }
            // The scrim covers the window: terminals under it stop reporting
            // the pointer to htop / vim while the dialog is up.
            .wlOccludesTerminal()
            .accessibilityHidden(true)
    }
}

private struct WLModalCard: View {
    let entry: WLModalEntry
    /// 0 → 1 as the card turns in.
    @State private var open = 0.0

    var body: some View {
        WLModalFit {
            entry.content
                .environment(\.wlDismiss, WLDismissAction(action: entry.dismiss))
                .background(WLModalHook(style: entry.style, dismiss: entry.dismiss))
        }
        // Turns in to the right, and closes by turning back the way it came.
        .modifier(WLFlipEffect(progress: Motion.reduce ? 1 : open))
        .opacity(Motion.reduce ? open : 1)
        .onAppear { withAnimation(Motion.reduce ? Motion.fade : Motion.flipIn) { open = 1 } }
        .onChange(of: entry.closing) { _, closing in
            guard closing else { return }
            withAnimation(Motion.reduce ? Motion.fade : Motion.flipOut) { open = 0 }
        }
        .allowsHitTesting(!entry.closing)
        // Clear the traffic lights; the card never touches the window edge.
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityAddTraits(.isModal)
    }
}

/// Gives the card its ideal size, shrunk to what the window has room for —
/// a sheet's `height` is a wish, the body scrolls to absorb the rest.
struct WLModalFit: Layout {
    static func fit(ideal: CGSize, available: ProposedViewSize) -> CGSize {
        CGSize(width: min(ideal.width, available.width ?? ideal.width),
               height: min(ideal.height, available.height ?? ideal.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let card = subviews.first else { return .zero }
        let ideal = card.sizeThatFits(.unspecified)
        let width = Self.fit(ideal: ideal, available: proposal).width
        // The height it wants at the width it actually gets.
        let tall = card.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return Self.fit(ideal: CGSize(width: width, height: tall.height), available: proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - Keyboard focus and Esc

/// Lives in the card's background. On arrival it takes keyboard focus away
/// from the window beneath (a terminal would otherwise swallow Esc and every
/// keystroke) and registers for Esc; on removal it hands focus back.
private struct WLModalHook: NSViewRepresentable {
    let style: WLModalStyle
    let dismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> WLModalHookView {
        let view = WLModalHookView()
        view.escapeCloses = style.escapeCloses
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: WLModalHookView, context: Context) {
        view.escapeCloses = style.escapeCloses
        view.dismiss = dismiss
    }
}

final class WLModalHookView: NSView {
    var escapeCloses = true
    var dismiss: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether `view` sits on this card (the hook spans the card).
    func covers(_ view: NSView) -> Bool {
        guard view.window === window else { return false }
        let frame = view.convert(view.bounds, to: nil)
        return convert(bounds, to: nil).contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { WLModalRegistry.shared.present(self, in: window) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window { WLModalRegistry.shared.remove(self, from: window) }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// The modals on screen, per window, in the order they opened. Owns the one
/// key-down monitor that turns Esc into "close the top modal".
@MainActor
final class WLModalRegistry {
    static let shared = WLModalRegistry()

    private struct Record {
        weak var hook: WLModalHookView?
        weak var window: NSWindow?
        /// Focus before this modal opened, handed back when it closes.
        weak var previous: NSResponder?
    }
    private var records: [Record] = []
    private var monitor: Any?

    func present(_ hook: WLModalHookView, in window: NSWindow) {
        guard !records.contains(where: { $0.hook === hook }) else { return }
        let current = window.firstResponder
        records.append(Record(hook: hook, window: window, previous: Self.restorable(current)))
        if current is NSTextView {
            // A text field has focus — the window's, or already the dialog's
            // own (a palette focuses its query as it appears). Look again
            // once laid out: if it's still that field and it isn't on the card,
            // it's the window's.
            DispatchQueue.main.async { [weak hook] in
                guard let hook, hook.window === window, window.firstResponder === current else { return }
                if let field = Self.restorable(current) as? NSView, hook.covers(field) {
                    self.forgetPrevious(of: hook)
                } else {
                    window.makeFirstResponder(nil)
                }
            }
        } else {
            window.makeFirstResponder(nil)
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let consumed = MainActor.assumeIsolated { WLModalRegistry.shared.handleKey(event) }
                return consumed ? nil : event
            }
        }
    }

    func remove(_ hook: WLModalHookView, from window: NSWindow) {
        guard let i = records.firstIndex(where: { $0.hook === hook }) else { return }
        let previous = records.remove(at: i).previous
        records.removeAll { $0.hook == nil }
        if records.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        // Next turn: the card's own fields have left the window by then.
        guard let view = previous as? NSView else { return }
        DispatchQueue.main.async {
            guard view.window === window else { return }
            let current = window.firstResponder
            let stranded = current == nil || current === window || (current as? NSView)?.window !== window
            if stranded { window.makeFirstResponder(view) }
        }
    }

    private func forgetPrevious(of hook: WLModalHookView) {
        if let i = records.firstIndex(where: { $0.hook === hook }) { records[i].previous = nil }
    }

    func hasModal(in window: NSWindow) -> Bool {
        records.contains { $0.window === window && $0.hook != nil }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let hook = records.last(where: { $0.window === window && $0.hook != nil })?.hook
        else { return false }
        let composing = (window.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
        // A modal that handles Esc itself (the palettes) can only hear it while
        // focus is on the card; otherwise Esc closes it from here.
        let focusOnCard = (Self.restorable(window.firstResponder) as? NSView).map(hook.covers) ?? false
        guard Self.closesOnEscape(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                  composing: composing, escapeCloses: hook.escapeCloses || !focusOnCard)
        else { return false }
        hook.dismiss?()
        return true
    }

    /// Esc (no modifiers) closes the top modal — unless an input method is
    /// mid-composition (Esc cancels the marked text there), or the modal
    /// handles Esc itself.
    nonisolated static func closesOnEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                           composing: Bool, escapeCloses: Bool) -> Bool {
        keyCode == 53 && escapeCloses && !composing
            && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// A text field's focus lives in the window's shared field editor; hand
    /// focus back to the field itself.
    private static func restorable(_ responder: NSResponder?) -> NSResponder? {
        if responder is NSWindow { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return responder
    }
}
