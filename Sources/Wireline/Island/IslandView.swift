import SwiftUI
import AppKit
import WirelineCore

// The island is an extension of the hardware notch, so it's always black with
// light text, whatever the app theme — the one place Wireline draws fixed
// colours. Everything else follows docs/design/motion-spec.md: one shape that
// morphs (Motion.expand in, Motion.popIn out), content that fades, a fade
// instead of the morph under Reduce Motion.

private enum IslandInk {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)
    static let well = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.1)
    // System colours resolved for a dark surface.
    static let green = Color(nsColor: NSColor(srgbRed: 0.20, green: 0.84, blue: 0.29, alpha: 1))
    static let orange = Color(nsColor: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1))
    static let red = Color(nsColor: NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1))
    static let purple = Color(nsColor: NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1))
}

/// The notch's outline: concave shoulders where it meets the screen's top
/// edge (`flare`), rounded bottom corners. Without a notch, `top` rounds the
/// upper corners instead. All three animate, so one shape morphs between
/// collapsed, pulse and expanded.
struct IslandShape: Shape {
    var flare: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(top, bottom)) }
        set { flare = newValue.first; top = newValue.second.first; bottom = newValue.second.second }
    }

    func path(in r: CGRect) -> Path {
        let f = min(flare, r.width / 4)
        let inner = r.width - 2 * f
        let b = min(bottom, inner / 2, r.height / 2)
        var p = Path()
        if f > 0 {
            // Shoulders curve in from the screen edge, then straight down.
            let left = r.minX + f, right = r.maxX - f
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: left, y: r.minY + f), control: CGPoint(x: left, y: r.minY))
            p.addLine(to: CGPoint(x: left, y: r.maxY - b))
            p.addQuadCurve(to: CGPoint(x: left + b, y: r.maxY), control: CGPoint(x: left, y: r.maxY))
            p.addLine(to: CGPoint(x: right - b, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: right, y: r.maxY - b), control: CGPoint(x: right, y: r.maxY))
            p.addLine(to: CGPoint(x: right, y: r.minY + f))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: right, y: r.minY))
        } else {
            let t = min(top, r.width / 2, r.height / 2)
            p.move(to: CGPoint(x: r.minX, y: r.minY + t))
            p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + t), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
            p.addQuadCurve(to: CGPoint(x: r.maxX - b, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - b), control: CGPoint(x: r.minX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// The panel's whole content: the island shape, pinned to the top at the
/// notch's centre.
struct IslandRootView: View {
    private var center: IslandCenter { IslandCenter.shared }
    private var controller: IslandController { IslandController.shared }

    /// What's drawn — follows `center.mode` with an animation chosen by direction.
    @State private var shown: IslandMode
    /// The pointer is down on the closed island (press feedback).
    @State private var pressed = false

    init() { _shown = State(initialValue: IslandCenter.shared.mode) }

    var body: some View {
        let layout = controller.layout
        ZStack(alignment: .topLeading) {
            if Motion.reduce {
                // Reduce Motion: no morph — the old shape fades out, the new one in.
                island(shown, layout)
                    .id(Self.rank(shown))
                    .transition(.opacity)
            } else {
                island(shown, layout)
            }
        }
        .frame(width: layout.panel.width, height: layout.panel.height, alignment: .topLeading)
        // The list's natural height, measured off-screen so the card knows
        // its size before it grows.
        .background(alignment: .topLeading) {
            IslandList(items: center.board.ordered, scrolls: false)
                .frame(width: IslandLayout.cardWidth)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    if abs(h - controller.listHeight) > 0.5 { controller.listHeight = h }
                }
                .hidden()
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: center.mode) { old, new in
            let grows = Self.rank(new) > Self.rank(old)
            withAnimation(Motion.resolved(grows ? Motion.expand : Motion.popIn)) { shown = new }
        }
    }

    static func rank(_ m: IslandMode) -> Int {
        switch m {
        case .hidden: 0
        case .dormant: 1
        case .collapsed: 2
        case .pulse: 3
        case .expanded: 4
        }
    }

    private func island(_ mode: IslandMode, _ layout: IslandLayout) -> some View {
        let size = layout.size(mode, list: controller.listHeight)
        let r = layout.radii(mode)
        let shape = IslandShape(flare: r.flare, top: r.top, bottom: r.bottom)
        let visible = mode != .hidden && (mode != .dormant || layout.hasNotch)
        return ZStack(alignment: .top) {
            IslandContent(mode: mode, layout: layout)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .background {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(mode == .expanded ? 0.45 : 0), radius: 18, y: 8)
        }
        .contentShape(shape)
        // Closed: a click anywhere on it opens the card. Open: only the top
        // strip folds it (rows and buttons below have their own taps).
        .onTapGesture { if mode != .expanded { center.toggleOpen() } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if mode != .expanded, !pressed { pressed = true } }
            .onEnded { _ in pressed = false })
        // Pressed: dip like the island's buttons, from the top edge so it stays on the notch.
        .scaleEffect(pressed && mode != .expanded && !Motion.reduce ? 0.97 : 1, anchor: .top)
        .animation(Motion.resolved(Motion.state), value: pressed)
        .opacity(visible ? 1 : 0)
        .offset(x: layout.centerX - size.width / 2)
        .animation(Motion.resolved(Motion.state), value: controller.listHeight)
    }
}

/// Ears, the pulse line, and the list — each fading in for the modes that use it.
private struct IslandContent: View {
    let mode: IslandMode
    let layout: IslandLayout
    private var center: IslandCenter { IslandCenter.shared }

    var body: some View {
        let ears = mode == .collapsed || mode == .expanded || { if case .pulse = mode { true } else { false } }()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IslandSourceIcon(source: center.board.leadSource, size: 15)
                    .frame(width: IslandLayout.ear)
                centerStrip
                    .frame(width: layout.core.width)
                IslandStatusView(status: center.board.status(at: center.now))
                    .frame(width: IslandLayout.ear)
            }
            .frame(height: layout.core.height)
            .opacity(ears ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { if mode == .expanded { center.toggleOpen() } }

            if case .pulse(let p) = mode {
                IslandPulseLine(pulse: p)
                    .frame(height: IslandLayout.pulseStrip - 4)
                    .transition(.opacity.animation(Motion.resolved(Motion.popIn)))
            }
            if mode == .expanded {
                Group {
                    // Only a list too tall for the card scrolls.
                    if IslandController.shared.listHeight > IslandLayout.maxListHeight {
                        ScrollView(.vertical) { IslandList(items: center.board.ordered, scrolls: true) }
                            .scrollIndicators(.never)
                    } else {
                        IslandList(items: center.board.ordered, scrolls: true)
                    }
                }
                .frame(width: IslandLayout.cardWidth)
                .transition(.asymmetric(insertion: .opacity.animation(Motion.resolved(Motion.popIn).delay(0.06)),
                                        removal: .opacity.animation(Motion.popOut)))
            }
        }
    }

    /// Under a real notch this strip is hidden behind the hardware. The pill
    /// shows a word there instead.
    @ViewBuilder private var centerStrip: some View {
        if !layout.hasNotch {
            Text(mode == .expanded ? "Wireline" : (center.board.ordered.first { $0.tone != .idle }?.detail ?? "Wireline"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandInk.secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        } else {
            Color.clear
        }
    }
}

private struct IslandPulseLine: View {
    let pulse: IslandPulse
    var body: some View {
        HStack(spacing: 6) {
            IslandSourceIcon(source: pulse.source, size: 12)
            Text(pulse.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pulse.tone == .failure ? IslandInk.red
                                 : pulse.tone == .attention ? IslandInk.orange : IslandInk.green)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - List

struct IslandList: View {
    let items: [IslandItem]
    /// The live copy (true) vs. the hidden measuring copy.
    let scrolls: Bool
    private var center: IslandCenter { IslandCenter.shared }

    var body: some View {
        VStack(spacing: 6) {
            if items.isEmpty {
                Text(Localizer.shared.t("没有正在进行的活动", "Nothing going on"))
                    .font(.system(size: 12))
                    .foregroundStyle(IslandInk.faint)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            ForEach(items) { item in
                IslandRow(item: item, interactive: scrolls)
            }
            if items.contains(where: \.needsUser) {
                Button {
                    wlAnimate(Motion.popIn) { center.dismissAttention() }
                } label: {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 44, height: 16)
                }
                .buttonStyle(IslandButtonStyle(kind: .bare))
                .help(Localizer.shared.t("收起", "Fold away"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

private struct IslandRow: View {
    let item: IslandItem
    let interactive: Bool
    @State private var hover = false
    private var center: IslandCenter { IslandCenter.shared }
    private var loc: Localizer { Localizer.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IslandSourceIcon(source: item.source, size: 17)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(IslandInk.well))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandInk.primary)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(item.tone == .failure ? IslandInk.red
                                         : item.tone == .attention ? IslandInk.orange : IslandInk.secondary)
                        .lineLimit(item.tone == .attention ? 2 : 1)
                }
                Spacer(minLength: 6)
                trailing
            }
            if let p = item.progress, item.tone == .working || p.failed > 0 {
                IslandProgressBar(progress: p)
            }
            if let c = item.confirmation { confirmation(c) }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hover && item.confirmation == nil ? 0.1 : 0.055))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { if interactive, item.confirmation == nil { center.jump(item) } }
        .wlHover($hover)
        .help(item.sessionID != nil ? loc.t("跳到这个终端", "Jump to this terminal") : "")
    }

    @ViewBuilder private var trailing: some View {
        if let p = item.progress, item.tone == .working {
            Text("\(p.done)/\(p.total)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(IslandInk.secondary)
                .contentTransition(.numericText())
        } else if item.confirmation == nil {
            // The hidden measuring copy doesn't need a spinning spinner.
            IslandStatusView(status: Self.status(item.tone), animated: interactive)
        }
    }

    static func status(_ tone: IslandTone) -> IslandStatus {
        switch tone {
        case .working: .working(1)
        case .attention: .attention(1)
        case .success: .success
        case .failure: .failure
        case .idle: .none
        }
    }

    private func confirmation(_ c: IslandConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.subject)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(IslandInk.primary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(IslandInk.well))
            if let note = c.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandInk.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(loc.t("拒绝", "Deny")) { decide(.deny) }
                    .buttonStyle(IslandButtonStyle(kind: .quiet))
                if c.canAlwaysAllow {
                    Button(loc.t("始终允许", "Always allow")) { decide(.allowAlways) }
                        .buttonStyle(IslandButtonStyle(kind: .quiet))
                }
                Button(c.kind == .dangerousCommand ? loc.t("仍然执行", "Run anyway") : loc.t("允许", "Allow")) {
                    decide(.allow)
                }
                .buttonStyle(IslandButtonStyle(kind: .prominent(c.kind == .dangerousCommand ? IslandInk.orange : IslandInk.green)))
            }
        }
    }

    private func decide(_ d: IslandDecision) {
        guard interactive else { return }
        wlAnimate(Motion.state) { center.decide(item.id, d) }
    }
}

private struct IslandProgressBar: View {
    let progress: IslandProgress
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let total = CGFloat(max(progress.total, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(IslandInk.well)
                Capsule().fill(IslandInk.green)
                    .frame(width: w * CGFloat(progress.done - progress.failed) / total)
                Capsule().fill(IslandInk.red)
                    .frame(width: w * CGFloat(progress.failed) / total)
                    .offset(x: w * CGFloat(progress.done - progress.failed) / total)
            }
        }
        .frame(height: 4)
        .animation(Motion.resolved(Motion.state), value: progress)
    }
}

// MARK: - Icons and status

/// A row's (or the left ear's) icon: the coding agent's brand mark, or a
/// symbol for Wireline's own sources; nil = the Wireline mark.
struct IslandSourceIcon: View {
    let source: IslandSource?
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch source {
            case .codingAgent(let name)?:
                if let brand = Self.brand(name), let img = brand.image {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .frame(width: size, height: size)
                        .foregroundStyle(brand.hex.map { Color(hex: $0) } ?? IslandInk.primary)
                } else {
                    symbol("sparkles", IslandInk.purple)
                }
            case .ai?: symbol("sparkles", IslandInk.green)
            case .fleet?: symbol("square.stack.3d.up.fill", IslandInk.green)
            case .inlineAI?: symbol("text.cursor", IslandInk.green)
            case .command?: symbol("terminal.fill", IslandInk.secondary)
            case nil:
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: size + 2, height: size + 2)
            }
        }
        .animation(Motion.state, value: source)
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.82, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }

    static func brand(_ name: String) -> BrandIcon? {
        switch name {
        case "claude": .claude
        case "codex": .openai
        case "gemini": .gemini
        default: nil
        }
    }
}

/// The right ear: spinner, attention dot, check, cross — with a count when
/// more than one thing is going on.
struct IslandStatusView: View {
    let status: IslandStatus
    var animated = true

    var body: some View {
        ZStack {
            switch status {
            case .none:
                Color.clear
            case .working(let n):
                HStack(spacing: 3) {
                    IslandSpinner(animated: animated)
                    if n > 1 { count(n) }
                }
            case .attention(let n):
                HStack(spacing: 3) {
                    Circle().fill(IslandInk.orange).frame(width: 8, height: 8)
                        .shadow(color: IslandInk.orange.opacity(0.7), radius: 3)
                        .wlPulse(period: 0.8, low: 0.45)
                    if n > 1 { count(n) }
                }
            case .success:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(IslandInk.green)
            case .failure:
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(IslandInk.red)
            }
        }
        .transition(.wlBadge)
        .animation(Motion.resolved(Motion.state), value: status)
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(IslandInk.secondary)
            .contentTransition(.numericText())
    }
}

/// A small rotating arc. Still under Reduce Motion.
private struct IslandSpinner: View {
    var animated = true
    var body: some View {
        let still = Motion.reduce || !animated
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { ctx in
            let angle = still ? 0 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            Circle()
                .trim(from: 0.1, to: 0.78)
                .stroke(IslandInk.primary.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// Capsule buttons on black (the app's `.wlChip` / `.wlPrimary` follow the
/// theme, which may be light).
struct IslandButtonStyle: ButtonStyle {
    enum Kind { case quiet, prominent(Color), bare }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration, kind: kind)
    }

    private struct IslandButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            Group {
                switch kind {
                case .bare:
                    configuration.label
                        .foregroundStyle(hover ? IslandInk.primary : IslandInk.faint)
                case .quiet:
                    configuration.label
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandInk.primary)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(pressed ? 0.2 : hover ? 0.15 : 0.1)))
                case .prominent(let tint):
                    configuration.label
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(Capsule().fill(tint.opacity(pressed ? 0.75 : hover ? 1 : 0.9)))
                }
            }
            .contentShape(Capsule())
            .scaleEffect(pressed && !Motion.reduce ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(pressed ? Motion.press : Motion.release, value: pressed)
            .wlHover($hover)
        }
    }
}
