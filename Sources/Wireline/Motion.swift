import SwiftUI
import AppKit

// The motion & interaction layer. Every animation, transition, hover and press
// response in the app goes through here, so timing stays consistent and the
// whole UI honours System Settings → Accessibility → Reduce Motion.
// The rules behind these numbers live in docs/design/motion-spec.md.

/// Motion tokens. Pick by *intent*, never by duration — if no token fits,
/// the design is probably wrong, not the token list.
enum Motion {
    /// The system "Reduce Motion" setting. When on, movement and scale are
    /// replaced by short cross-fades and ambient loops stop.
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Pointer enters / leaves a control: background tint, text colour.
    static let hover: Animation = .easeOut(duration: 0.12)
    /// Mouse down on a control. Fast enough to feel instant.
    static let press: Animation = .easeOut(duration: 0.08)
    /// Mouse up — the control settles back with a hint of spring.
    static let release: Animation = .spring(duration: 0.26, bounce: 0.18)
    /// A value changes in place: selection by mouse, toggle, status colour.
    static let state: Animation = .smooth(duration: 0.2)
    /// The raised selection pill gliding along a capsule track (tab bar,
    /// segmented controls, the drawer's section switcher).
    static let slide: Animation = .spring(duration: 0.32, bounce: 0.12)
    /// Disclosure: group expand / collapse, chevron, an inline row revealing actions.
    static let disclose: Animation = .spring(duration: 0.3, bounce: 0)
    /// A menu / popover / small card appearing from its anchor.
    static let popIn: Animation = .spring(duration: 0.22, bounce: 0)
    /// …and going away. Exits are always faster than entries.
    static let popOut: Animation = .easeIn(duration: 0.12)
    /// A modal surface (⌘K, ⌘P) appearing over a scrim.
    static let modalIn: Animation = .spring(duration: 0.3, bounce: 0.05)
    static let modalOut: Animation = .easeIn(duration: 0.14)
    /// A dialog card (`.wlModal`) flipping up into place over its scrim.
    static let flipIn: Animation = .spring(duration: 0.38, bounce: 0.16)
    /// …and flipping back away — the same path reversed, faster.
    static let flipOut: Animation = .easeIn(duration: 0.2)
    /// A banner / toast / floating bar sliding in from an edge.
    static let banner: Animation = .spring(duration: 0.36, bounce: 0.16)
    /// Expanding a floating surface the user deliberately summoned (pet chat).
    static let expand: Animation = .spring(duration: 0.34, bounce: 0.12)
    /// Programmatic scrolling (jump to bottom, follow output).
    static let scroll: Animation = .smooth(duration: 0.25)
    /// Cross-fade used in place of movement when Reduce Motion is on.
    static let fade: Animation = .easeInOut(duration: 0.15)

    /// A slow, autoreversing loop for ambient indicators (pulse, breathe).
    /// Returns nil under Reduce Motion — callers must leave the view static.
    static func ambient(_ period: Double) -> Animation? {
        reduce ? nil : .easeInOut(duration: period).repeatForever(autoreverses: true)
    }

    /// Resolve a token against Reduce Motion: movement tokens collapse to a fade.
    static func resolved(_ animation: Animation) -> Animation {
        reduce ? fade : animation
    }
}

/// `withAnimation` that respects Reduce Motion.
@discardableResult
func wlAnimate<R>(_ animation: Animation = Motion.state, _ body: () throws -> R) rethrows -> R {
    try withAnimation(Motion.resolved(animation), body)
}

/// Run a state change with no animation at all — for anything that resizes the
/// terminal (sidebar, AI column, broadcast bar). The terminal must reflow once,
/// not once per frame.
func wlSnap<R>(_ body: () throws -> R) rethrows -> R {
    var t = Transaction()
    t.disablesAnimations = true
    return try withTransaction(t, body)
}

// MARK: - Transitions

extension AnyTransition {
    /// Menus, popovers, small floating cards: grow from the anchor, fade out.
    static func wlPop(anchor: UnitPoint = .top) -> AnyTransition {
        if Motion.reduce { return .opacity.animation(Motion.fade) }
        return .asymmetric(
            insertion: .scale(scale: 0.96, anchor: anchor).combined(with: .opacity).animation(Motion.popIn),
            removal: .opacity.animation(Motion.popOut)
        )
    }

    /// Modal cards over a scrim: settle in from slightly above, shrink away.
    static var wlModal: AnyTransition {
        if Motion.reduce { return .opacity.animation(Motion.fade) }
        return .asymmetric(
            insertion: .scale(scale: 0.97).combined(with: .offset(y: -6)).combined(with: .opacity)
                .animation(Motion.modalIn),
            removal: .scale(scale: 0.98).combined(with: .opacity).animation(Motion.modalOut)
        )
    }

    /// Scrims behind modals.
    static var wlScrim: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)),
                    removal: .opacity.animation(Motion.modalOut))
    }

    /// Dialog cards (`.wlModal`): the card flips up about its horizontal axis
    /// like a card being turned over — tilted back 70° in perspective, 94%
    /// size, transparent → flat, full size, opaque — on a spring with a
    /// little settle. Closing runs the same path backwards, faster.
    static var wlFlip: AnyTransition {
        if Motion.reduce { return .opacity.animation(Motion.fade) }
        let flip = AnyTransition.modifier(active: WLFlipEffect(progress: 0), identity: WLFlipEffect(progress: 1))
        return .asymmetric(insertion: flip.animation(Motion.flipIn),
                           removal: flip.animation(Motion.flipOut))
    }

    /// The scrim behind a flipping card: in with the card, out with it.
    static var wlFlipScrim: AnyTransition {
        if Motion.reduce { return .opacity.animation(Motion.fade) }
        return .asymmetric(insertion: .opacity.animation(Motion.state),
                           removal: .opacity.animation(Motion.flipOut))
    }

    /// Banners and floating bars that belong to an edge.
    static func wlSlide(_ edge: Edge) -> AnyTransition {
        if Motion.reduce { return .opacity.animation(Motion.fade) }
        let offset: CGSize = switch edge {
        case .top: CGSize(width: 0, height: -10)
        case .bottom: CGSize(width: 0, height: 10)
        case .leading: CGSize(width: -10, height: 0)
        case .trailing: CGSize(width: 10, height: 0)
        }
        return .asymmetric(
            insertion: .offset(offset).combined(with: .opacity).animation(Motion.banner),
            removal: .offset(offset).combined(with: .opacity).animation(Motion.popOut)
        )
    }

    /// Rows revealed by a disclosure (group expand).
    static var wlDisclose: AnyTransition {
        if Motion.reduce { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)),
                           removal: .opacity)
    }

    /// Small badges and dots popping into existence.
    static var wlBadge: AnyTransition {
        if Motion.reduce { return .opacity }
        return .scale(scale: 0.5).combined(with: .opacity)
    }
}

/// The card-flip pose at `progress` (0 = put away, 1 = in place). One
/// animatable number drives all three properties so they stay in step, and
/// the spring's small overshoot tips the card a hair past flat before it settles.
struct WLFlipEffect: ViewModifier, Animatable {
    /// How far the card starts tilted back, in degrees.
    static let tilt: Double = 70
    /// How small it starts.
    static let startScale: Double = 0.94

    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// Rotation, scale and opacity at a given progress. Opacity runs ahead of
    /// the turn so the card is solid for most of it rather than ghosting in.
    static func pose(_ progress: Double) -> (angle: Double, scale: Double, opacity: Double) {
        (angle: -tilt * (1 - progress),
         scale: startScale + (1 - startScale) * progress,
         opacity: min(1, max(0, progress * 2.2)))
    }

    func body(content: Content) -> some View {
        let pose = Self.pose(progress)
        content
            .scaleEffect(pose.scale)
            .rotation3DEffect(.degrees(pose.angle), axis: (x: 1, y: 0, z: 0),
                              anchor: .center, perspective: 0.55)
            .opacity(pose.opacity)
    }
}

// MARK: - Hover

extension View {
    /// Track hover with the standard hover timing. Replaces `.wlHover($hover)`.
    func wlHover(_ hover: Binding<Bool>, perform extra: ((Bool) -> Void)? = nil) -> some View {
        onHover { h in
            withAnimation(Motion.hover) { hover.wrappedValue = h }
            extra?(h)
        }
    }

    /// Entrance for content inside a panel whose *frame* must not animate (it
    /// would resize the terminal every frame). The column snaps into place; only
    /// its contents fade and drift in. Apply it *before* the panel's background
    /// modifier — fading a translucent tint flashes the wallpaper behind it.
    func wlAppear(from edge: Edge = .trailing, distance: CGFloat = 8) -> some View {
        modifier(AppearModifier(edge: edge, distance: distance))
    }
}

private struct AppearModifier: ViewModifier {
    let edge: Edge
    let distance: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        let d = shown || Motion.reduce ? 0 : distance
        content
            .opacity(shown ? 1 : 0)
            .offset(x: edge == .leading ? -d : edge == .trailing ? d : 0,
                    y: edge == .top ? -d : edge == .bottom ? d : 0)
            .onAppear { withAnimation(Motion.resolved(Motion.popIn)) { shown = true } }
    }
}

// MARK: - Button styles

/// The default for every text / icon-only button. Like a native borderless
/// button: dims while pressed, dims when disabled, no scale.
struct WLPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlainBody(configuration: configuration)
    }

    private struct PlainBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
                .animation(configuration.isPressed ? Motion.press : Motion.release,
                           value: configuration.isPressed)
        }
    }
}

/// Square icon button (toolbar, panel headers): 24pt hit target, a rounded
/// hover well, and a slight press-in.
struct WLIconButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var size: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, tint: tint, size: size)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(tint ?? (hover ? WL.textPrimary : WL.textDim))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: WL.radius(7), style: .continuous)
                        .fill(WL.textPrimary.opacity(pressed ? 0.14 : hover ? 0.08 : 0))
                )
                .contentShape(Rectangle())
                .scaleEffect(pressed && !Motion.reduce ? 0.94 : 1)                .opacity(enabled ? 1 : 0.4)
                .animation(pressed ? Motion.press : Motion.release, value: pressed)
                .wlHover($hover)
        }
    }
}

/// Filled / tinted pill — the app's prominent action button.
struct WLPillButtonStyle: ButtonStyle {
    var tint: Color = WL.green
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(prominent ? WL.bg : (hover ? WL.greenBright : tint))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(prominent ? tint.opacity(pressed ? 0.8 : hover ? 1 : 0.92)
                                             : tint.opacity(pressed ? 0.26 : hover ? 0.2 : 0.12))
                )
                .contentShape(Capsule())
                .scaleEffect(pressed && !Motion.reduce ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(pressed ? Motion.press : Motion.release, value: pressed)
                .wlHover($hover)
        }
    }
}

/// A small capsule chip: quick actions, suggestions, inline row actions, and —
/// with `on` — option toggles (search "Aa", AI "Agent"). Off it's a faint wash
/// of the text colour; on it takes the tint. Hover and press change only the
/// opacity of the one capsule, so nothing swaps shape.
struct WLChipButtonStyle: ButtonStyle {
    var on: Bool? = nil
    var tint: Color = WL.green

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, on: on, tint: tint)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let on: Bool?
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            let lit = on == true
            let lift = enabled && hover
            configuration.label
                .font(WL.caption)
                .foregroundStyle(lit ? tint : (lift ? WL.textPrimary : WL.textPrimary.opacity(on == nil ? 0.85 : 0.6)))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background {
                    let shape = Capsule(style: .continuous)
                    shape.fill(WL.textPrimary.opacity(lit ? 0 : pressed ? 0.13 : lift ? 0.09 : 0.055))
                        .overlay(shape.fill(tint.opacity(lit ? (pressed ? 0.24 : lift ? 0.19 : 0.14) : 0)))
                }
                .contentShape(Capsule())
                .scaleEffect(pressed && !Motion.reduce ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(pressed ? Motion.press : Motion.release, value: pressed)
                .animation(Motion.state, value: lit)
                .wlHover($hover)
        }
    }
}

extension ButtonStyle where Self == WLChipButtonStyle {
    /// A quiet capsule chip. Pass `on:` for a toggle chip that lights up in `tint`.
    static func wlChip(on: Bool? = nil, tint: Color = WL.green) -> WLChipButtonStyle {
        WLChipButtonStyle(on: on, tint: tint)
    }
}

extension ButtonStyle where Self == WLPlainButtonStyle {
    static var wlPlain: WLPlainButtonStyle { WLPlainButtonStyle() }
}
extension ButtonStyle where Self == WLIconButtonStyle {
    static var wlIcon: WLIconButtonStyle { WLIconButtonStyle() }
    static func wlIcon(tint: Color? = nil, size: CGFloat = 24) -> WLIconButtonStyle {
        WLIconButtonStyle(tint: tint, size: size)
    }
}
extension ButtonStyle where Self == WLPillButtonStyle {
    static func wlPill(_ tint: Color = WL.green, prominent: Bool = false) -> WLPillButtonStyle {
        WLPillButtonStyle(tint: tint, prominent: prominent)
    }
}

// MARK: - Ambient indicators

/// An opacity pulse for "in progress" dots. Static under Reduce Motion, and
/// stops cleanly when `active` turns false.
struct PulseModifier: ViewModifier {
    var active: Bool
    var period: Double = 0.9
    var low: Double = 0.3
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(active && on ? low : 1)
            .onAppear { restart() }
            .onChange(of: active) { _, _ in restart() }
    }

    private func restart() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { on = false }
        guard active, let a = Motion.ambient(period) else { return }
        DispatchQueue.main.async { withAnimation(a) { on = true } }
    }
}

extension View {
    func wlPulse(_ active: Bool = true, period: Double = 0.9, low: Double = 0.3) -> some View {
        modifier(PulseModifier(active: active, period: period, low: low))
    }
}
