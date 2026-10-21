import SwiftUI
import AppKit

// Themed form controls. The stock AppKit-backed controls (segmented picker,
// checkbox, stepper, slider, pop-up button) render in system grey and ignore
// the theme, so every form in the app uses these instead. Motion follows
// docs/design/motion-spec.md; each control keeps a native accessibility
// representation so VoiceOver / keyboard users get the real thing.

// MARK: - Surfaces

// The card / capsule language (see docs/design/motion-spec.md §4.11): content
// sits on a slightly deeper canvas (`WL.paneCanvas`) in raised cards; choices
// sit in a capsule track with one raised pill that slides to the selection.
// "Raised" always means one step above whatever it sits on: white on light
// themes, a wash of the text colour on dark ones.
extension WL {
    /// The recessed capsule track behind segments (tab bar, segmented controls).
    static var track: Color { textPrimary.opacity(isLight ? 0.06 : 0.08) }
    /// The selected segment's raised pill inside a track.
    static var raised: Color { isLight ? Color.white : textPrimary.opacity(0.12) }
    /// A card's fill: raised over both the theme background and the canvas.
    static var cardFill: Color { isLight ? Color.white.opacity(0.9) : textPrimary.opacity(0.045) }
    /// The 1pt edge of cards, pills and floating surfaces.
    static var hairline: Color { textPrimary.opacity(isLight ? 0.09 : 0.11) }
    /// The resting wash of an input field (search, text fields, the AI input).
    static var fieldFill: Color { textPrimary.opacity(isLight ? 0.05 : 0.055) }
}

extension View {
    /// A capsule track holding segments; pair each segment with
    /// `wlSegmentPill(active:hover:in:)` and animate the selection with
    /// `Motion.slide`.
    func wlCapsuleTrack(padding: CGFloat = 3) -> some View {
        self.padding(padding)
            .background(Capsule(style: .continuous).fill(WL.track))
    }

    /// One segment's background in a capsule track: the selected one is a single
    /// raised pill matched across the track (so it slides); the others get a
    /// faint wash of the *same* capsule on hover — never a different shape.
    func wlSegmentPill(active: Bool, hover: Bool, in ns: Namespace.ID, id: String = "pill") -> some View {
        background {
            let shape = Capsule(style: .continuous)
            if active {
                shape.fill(WL.raised)
                    .shadow(color: .black.opacity(WL.depth(0.18)), radius: 3, y: 1)
                    .overlay(shape.strokeBorder(WL.hairline.opacity(WL.isLight ? 0.8 : 0.6), lineWidth: 1))
                    .matchedGeometryEffect(id: id, in: ns)
            } else {
                shape.fill(WL.textPrimary.opacity(hover ? 0.05 : 0))
            }
        }
    }

    /// A floating surface (modal card, banner, find bar, the AI panel): theme
    /// background, hairline edge, and a shadow on the *shape* only — on the
    /// content it would shadow every glyph.
    func wlFloating<S: InsettableShape>(_ shape: S, fill: Color = WL.bg,
                                        shadow: Double = 0.3, radius: CGFloat = 16, y: CGFloat = 5) -> some View {
        background {
            shape.fill(fill)
                .shadow(color: .black.opacity(WL.depth(shadow)), radius: radius, y: y)
        }
        .overlay { shape.strokeBorder(WL.hairline, lineWidth: 1).allowsHitTesting(false) }
    }

    /// Inline search / filter field chrome: a capsule wash that deepens, and an
    /// accent edge that fades in, while focused. Put the icon, field and clear
    /// button inside; the caller supplies the padding.
    func wlSearchCapsule(focused: Bool) -> some View {
        background(focused ? WL.textPrimary.opacity(0.08) : WL.fieldFill,
                   in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(WL.green.opacity(focused ? 0.55 : 0), lineWidth: 1))
            .animation(Motion.hover, value: focused)
    }
}

/// One choice in a segmented control or menu picker.
struct WLOption<T: Hashable>: Identifiable {
    let value: T
    let title: String
    var symbol: String? = nil
    var id: T { value }

    init(_ value: T, _ title: String, symbol: String? = nil) {
        self.value = value; self.title = title; self.symbol = symbol
    }
}

// MARK: - Segmented

/// A segmented control: a capsule track whose raised pill glides between
/// segments (same look as the tab bar and the drawer's section switcher).
struct WLSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [WLOption<T>]
    /// Stretch segments to fill the available width.
    var fill = true
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                SegmentCell(title: opt.title, symbol: opt.symbol,
                            selected: opt.value == selection, fill: fill, ns: ns) {
                    guard opt.value != selection else { return }
                    wlAnimate(Motion.slide) { selection = opt.value }
                }
            }
        }
        .wlCapsuleTrack(padding: 2)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.value) }
            }.pickerStyle(.segmented)
        }
    }
}

private struct SegmentCell: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let fill: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(title).font(WL.small.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected || hover ? WL.textPrimary : WL.textDim)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: fill ? .infinity : nil)
            .wlSegmentPill(active: selected, hover: hover, in: ns, id: "thumb")
            .contentShape(Capsule())
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
    }
}

// MARK: - Toggles

/// System-Settings-style switch: label on the left, switch on the right; the
/// whole row is the hit target.
struct WLSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SwitchBody(configuration: configuration) }

    private struct SwitchBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                Capsule()
                    .fill(on ? WL.green : WL.textDim.opacity(hover ? 0.34 : 0.24))
                    .frame(width: 30, height: 17)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(on ? WL.bg : WL.textPrimary.opacity(0.9))
                            .padding(2)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
                    .overlay(Capsule().stroke(WL.border.opacity(on ? 0 : 1), lineWidth: WL.borderWidth))
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onTapGesture {
                guard enabled else { return }
                wlAnimate(Motion.release) { configuration.isOn.toggle() }
            }
            .wlHover($hover)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

/// A themed checkbox for inline / list use (to-do items, per-row enable).
struct WLCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { CheckBody(configuration: configuration) }

    private struct CheckBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: WL.radius(3.5))
                    .fill(on ? WL.green : WL.bg.opacity(0.4))
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: WL.radius(3.5))
                        .stroke(on ? Color.clear : (hover ? WL.green.opacity(0.7) : WL.border), lineWidth: 1))
                    .overlay {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8.5, weight: .heavy))
                                .foregroundStyle(WL.bg)
                                .transition(.wlBadge)
                        }
                    }
                configuration.label
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onTapGesture {
                guard enabled else { return }
                wlAnimate(Motion.release) { configuration.isOn.toggle() }
            }
            .wlHover($hover)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

extension ToggleStyle where Self == WLSwitchToggleStyle {
    static var wlSwitch: WLSwitchToggleStyle { WLSwitchToggleStyle() }
}
extension ToggleStyle where Self == WLCheckboxToggleStyle {
    static var wlCheckbox: WLCheckboxToggleStyle { WLCheckboxToggleStyle() }
}

// MARK: - Stepper

/// `− value +` capsule. Hold a button to repeat; the number rolls as it changes.
struct WLStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0)) }

    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            Text(format(value))
                .font(WL.small).monospacedDigit()
                .foregroundStyle(WL.textPrimary)
                .contentTransition(.numericText(value: value))
                .animation(Motion.state, value: value)
                .frame(minWidth: 38)
            button("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .wlCapsuleTrack(padding: 2)
        .fixedSize()
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { Text(format(value)) }
        }
    }

    private func button(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.wlIcon(size: 20))
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
    }
}

extension WLStepper {
    /// Integer-valued stepper.
    init(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1,
         format: @escaping (Int) -> String = { String($0) }) {
        self._value = Binding(get: { Double(value.wrappedValue) },
                              set: { value.wrappedValue = Int($0.rounded()) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = Double(step)
        self.format = { format(Int($0.rounded())) }
    }
}

// MARK: - Slider

/// Accent-filled track with a knob that swells slightly while dragged. Pass a
/// `width`, or nil to fill the available space.
struct WLSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat? = 160
    @State private var dragging = false
    @State private var hover = false
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geo in track(width: geo.size.width) }
            .frame(width: width, height: 18)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .wlHover($hover)
            .accessibilityRepresentation { Slider(value: $value, in: range) }
    }

    private func track(width w: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let f = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
        let travel = max(1, w - knob)
        return ZStack(alignment: .leading) {
            Capsule().fill(WL.textDim.opacity(0.22)).frame(height: 4)
            Capsule().fill(WL.green).frame(width: max(4, knob / 2 + f * travel), height: 4)
            // White on light themes (a dark knob reads as a hole), like the pills.
            Circle()
                .fill(WL.isLight ? Color.white : WL.textPrimary)
                .overlay(Circle().strokeBorder(WL.hairline, lineWidth: WL.isLight ? 1 : 0))
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.35), radius: dragging ? 3 : 1.5, y: 1)
                .scaleEffect(dragging && !Motion.reduce ? 1.12 : hover ? 1.05 : 1)
                .offset(x: f * travel)
                .animation(Motion.release, value: dragging)
        }
        .frame(width: w, height: 18)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    let x = min(max(0, g.location.x - knob / 2), travel)
                    value = range.lowerBound + Double(x / travel) * span
                }
                .onEnded { _ in dragging = false }
        )
    }
}

// MARK: - Menu picker

/// A themed pop-up button. The trigger matches the theme; the menu itself is a
/// real NSMenu positioned with the current item over the control, exactly like
/// NSPopUpButton.
struct WLMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [WLOption<T>]
    var minWidth: CGFloat = 120
    @State private var anchor = MenuAnchor()
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    private var current: WLOption<T>? { options.first { $0.value == selection } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(current?.title ?? "—").lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WL.textDim)
            }
            .font(WL.small)
            .foregroundStyle(WL.textPrimary)
            .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 5)
            .frame(minWidth: minWidth)
            .background(hover && enabled ? WL.textPrimary.opacity(0.09) : WL.fieldFill,
                        in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(WL.green.opacity(hover && enabled ? 0.35 : 0), lineWidth: 1))
            .background(MenuAnchorView(anchor: anchor))
        }
        .buttonStyle(.wlPlain)
        .wlHover($hover)
        .fixedSize()
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.value) }
            }
        }
    }

    private func open() {
        let index = options.firstIndex { $0.value == selection }
        anchor.popUp(titles: options.map(\.title), selected: index) { i in
            selection = options[i].value
        }
    }
}

/// Holds the NSView a pop-up menu positions itself against.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
    private var target: MenuTarget?

    func popUp(titles: [String], selected: Int?, onPick: @escaping (Int) -> Void) {
        guard let view else { return }
        let menu = NSMenu()
        let target = MenuTarget(onPick: onPick)
        self.target = target
        for (i, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = i
            item.state = i == selected ? .on : .off
            menu.addItem(item)
        }
        let item = selected.flatMap { menu.item(at: $0) }
        // Native pop-up placement: the checked item sits right over the control.
        menu.popUp(positioning: item, at: NSPoint(x: 0, y: item == nil ? 0 : view.bounds.height - 3), in: view)
    }
}

private final class MenuTarget: NSObject {
    let onPick: (Int) -> Void
    init(onPick: @escaping (Int) -> Void) { self.onPick = onPick }
    @objc func pick(_ sender: NSMenuItem) { onPick(sender.tag) }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let v = PassthroughView(); anchor.view = v; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }

    final class PassthroughView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Text field

extension View {
    /// Themed text-field chrome: a capsule wash with an accent edge that fades
    /// in on focus. Pass `multiline: true` for a text editor or a field that
    /// grows (`axis: .vertical`) — it keeps the capsule's ends while one line
    /// tall and settles into a rounded rectangle as it grows.
    func wlField(font: Font = WL.mono(12), multiline: Bool = false) -> some View {
        modifier(WLFieldModifier(font: font, multiline: multiline, external: nil))
    }

    /// Same, for a field whose focus the caller also drives (auto-focus on
    /// appear, etc.). Pass the caller's binding instead of adding `.focused`
    /// separately, so the field has exactly one focus source.
    func wlField(font: Font = WL.mono(12), multiline: Bool = false, focus: FocusState<Bool>.Binding) -> some View {
        modifier(WLFieldModifier(font: font, multiline: multiline, external: focus))
    }
}

/// A capsule that stops rounding at `maxRadius`: a pill while short, a rounded
/// rectangle once taller — one shape, so a growing field never swaps outlines.
struct WLFieldShape: InsettableShape {
    var maxRadius: CGFloat = .infinity
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: min(r.height / 2, maxRadius), style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> WLFieldShape {
        WLFieldShape(maxRadius: maxRadius, inset: inset + amount)
    }
}

private struct WLFieldModifier: ViewModifier {
    let font: Font
    let multiline: Bool
    let external: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    func body(content: Content) -> some View {
        let focused = external?.wrappedValue ?? internalFocus
        let shape = WLFieldShape(maxRadius: multiline ? WL.radius(10) : .infinity)
        content
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(WL.textPrimary)
            .focused(external ?? $internalFocus)
            .padding(.horizontal, multiline ? 10 : 12).padding(.vertical, 7)
            .background(focused ? WL.textPrimary.opacity(0.075) : WL.fieldFill, in: shape)
            .overlay(shape.strokeBorder(WL.green.opacity(focused ? 0.6 : 0), lineWidth: 1))
            .animation(Motion.hover, value: focused)
    }
}

// MARK: - Form card

/// A titled group of settings drawn as a quiet card (System Settings style):
/// dim caption title above, hairline-bordered card, optional footer note below.
/// Separate rows inside with `WLFormDivider()`.
struct WLFormSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty {
                Text(title).font(WL.caption.weight(.semibold)).foregroundStyle(WL.textDim)
                    .textCase(.uppercase).tracking(0.6)
                    .padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wlCard()
            if let footer {
                Text(footer).font(WL.caption).foregroundStyle(WL.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6).padding(.top, 1)
            }
        }
    }
}

/// One line inside a form card: label (+ optional detail) on the left, control
/// on the right, a comfortable 38pt row.
struct WLFormRow<Trailing: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    init(_ label: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label; self.detail = detail; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(WL.body).foregroundStyle(WL.textPrimary)
                if let detail {
                    Text(detail).font(WL.caption).foregroundStyle(WL.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 38)
        .padding(.vertical, 4)
    }
}

/// Highlight for a clickable row inside a list card: an inset rounded fill,
/// never a full-bleed slab (which collides with the card's rounded corners and
/// sits awkwardly between dividers). Put the rows in a `WLListCard`.
extension View {
    func wlRowHighlight(hover: Bool, selected: Bool = false) -> some View {
        padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: WL.radius(8), style: .continuous)
                    .fill(selected ? WL.green.opacity(0.13) : WL.textPrimary.opacity(hover ? 0.055 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: WL.radius(8), style: .continuous))
            .animation(Motion.hover, value: hover)
            .animation(Motion.state, value: selected)
    }
}

/// Selection for keyboard-driven result lists (⌘P, ⌘K): Spotlight-style — a
/// whole inset rounded block in a soft accent, no edge bar, text keeps its
/// colour. Instant (keyboard navigation never waits on animation).
extension View {
    func wlResultHighlight(_ selected: Bool) -> some View {
        padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous)
                    .fill(WL.green.opacity(selected ? (WL.isLight ? 0.12 : 0.16) : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous))
    }
}

/// A card holding a list of clickable rows: 4pt inset, 2pt gaps, no dividers.
struct WLListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wlCard()
    }
}

/// Hairline between rows of a form card.
struct WLFormDivider: View {
    var body: some View { Rectangle().fill(WL.hairline.opacity(0.8)).frame(height: 1) }
}

extension View {
    /// The shared card surface (forms, lists, overview tiles): a raised fill,
    /// hairline edge, and a soft shadow on the shape only — the small sibling
    /// of the pane cards. Reads best on `WL.paneCanvas`.
    func wlCard(radius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: WL.radius(radius), style: .continuous)
        return background {
            shape.fill(WL.cardFill)
                .shadow(color: .black.opacity(WL.depth(0.1)), radius: 3, y: 1)
        }
        .overlay(shape.strokeBorder(WL.hairline, lineWidth: 1).allowsHitTesting(false))
    }
}

// MARK: - Sheets

/// The frame every sheet / dialog uses: header (title, subtitle, close),
/// scrolling body, and a footer bar for actions. Esc closes via the cancel
/// button the footer provides (`.keyboardShortcut(.cancelAction)`).
struct WLSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var width: CGFloat = 480
    var height: CGFloat? = nil
    var scrolls = true
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil,
         width: CGFloat = 480, height: CGFloat? = nil, scrolls: Bool = true,
         onClose: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.width = width; self.height = height; self.scrolls = scrolls; self.onClose = onClose
        self.content = content(); self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WLFormDivider()
            // The body is the canvas its cards sit on; header and footer stay
            // on the plain background, like a window's chrome.
            Group {
                if scrolls {
                    ScrollView { body_.frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    body_
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(WL.paneCanvas)
            WLFormDivider()
            HStack(spacing: 10) { footer }
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        // `height` is the *ideal* height, never a hard one: a sheet can't be
        // taller than its parent window, and a fixed frame would get centred and
        // clipped (header and footer cut off). The body scrolls to absorb it.
        .frame(width: width)
        .frame(minHeight: 220, idealHeight: height, maxHeight: height ?? .infinity)
        .background(WL.bg)
        .preferredColorScheme(WL.colorScheme)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 18) { content }.padding(20)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WL.green)
                    .frame(width: 30, height: 30)
                    .background(WL.green.opacity(0.12), in: RoundedRectangle(cornerRadius: WL.radius(9), style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(WL.mono(14, .semibold)).foregroundStyle(WL.textPrimary)
                if let subtitle {
                    Text(subtitle).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(2)
                }
            }
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.wlIcon(size: 24))
                    .help(Localizer.shared.t("关闭", "Close"))
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }
}

/// Dialog buttons: `.wlPrimary` (filled accent), `.wlSecondary` (quiet), and
/// `.wlDestructive`. Pair the primary with `.keyboardShortcut(.defaultAction)`
/// and cancel with `.keyboardShortcut(.cancelAction)`.
struct WLDialogButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        DialogBody(configuration: configuration, kind: kind)
    }

    private struct DialogBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(WL.small.weight(kind == .secondary ? .regular : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 15).padding(.vertical, 6)
                .frame(minWidth: 72)
                .background(fill(pressed: pressed), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(WL.hairline.opacity(kind == .secondary ? 1 : 0), lineWidth: 1))
                .contentShape(Capsule())
                .scaleEffect(pressed && !Motion.reduce ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(pressed ? Motion.press : Motion.release, value: pressed)
                .wlHover($hover)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return WL.bg
            case .secondary: return hover ? WL.textPrimary : WL.textPrimary.opacity(0.85)
            case .destructive: return hover ? WL.bg : WL.red
            }
        }

        private func fill(pressed: Bool) -> Color {
            let lift = enabled && hover
            switch kind {
            case .primary: return WL.green.opacity(pressed ? 0.78 : lift ? 1 : 0.9)
            case .secondary: return WL.textPrimary.opacity(pressed ? 0.13 : lift ? 0.09 : 0.05)
            case .destructive: return WL.red.opacity(pressed ? 0.8 : lift ? 0.9 : 0.14)
            }
        }
    }
}

extension ButtonStyle where Self == WLDialogButtonStyle {
    static var wlPrimary: WLDialogButtonStyle { WLDialogButtonStyle(kind: .primary) }
    static var wlSecondary: WLDialogButtonStyle { WLDialogButtonStyle(kind: .secondary) }
    static var wlDestructive: WLDialogButtonStyle { WLDialogButtonStyle(kind: .destructive) }
}

// MARK: - Config-file lock

/// Small tag shown next to a control whose value comes from the config file.
struct ConfigLockTag: View {
    let key: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.text").font(.system(size: 8, weight: .semibold))
            Text(key).font(WL.caption)
        }
        .foregroundStyle(WL.amber)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(WL.amber.opacity(0.12), in: Capsule())
        .help(Localizer.shared.t("由配置文件设置：\(key)，在配置文件里删掉这一行即可在此修改",
                                 "Set by the config file (\(key)); remove that line to edit it here"))
    }
}

extension View {
    /// Lock a settings control when the config file sets `key`: disable it and
    /// show the key underneath.
    func wlConfigLocked(_ key: String) -> some View { modifier(ConfigLockModifier(key: key)) }
}

private struct ConfigLockModifier: ViewModifier {
    let key: String
    @State private var config = ConfigStore.shared
    func body(content: Content) -> some View {
        let locked = config.isLocked(key)
        VStack(alignment: .trailing, spacing: 5) {
            content.disabled(locked)
            if locked { ConfigLockTag(key: key).transition(.opacity) }
        }
        .animation(Motion.state, value: locked)
    }
}

// MARK: - Page header

/// The header every full-width page uses (tools, host details, overview):
/// clears the 28pt title-bar band (traffic lights), then a row level with the
/// tab bar that starts right of the drawer's corner button.
struct WLPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, onBack: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.onBack = onBack; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.wlIcon)
                    .help(Localizer.shared.t("返回", "Back"))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(WL.mono(14, .semibold)).foregroundStyle(WL.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(WL.caption).foregroundStyle(WL.textDim).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.leading, 24).padding(.trailing, 20)
        .padding(.top, 28)
        .frame(minHeight: 64, alignment: .center)
        // This row sits in the window's title-bar band, where a mouse-down
        // starts a window drag unless the view says otherwise — without this
        // the buttons here never get the click.
        .blocksWindowDrag()
    }
}
