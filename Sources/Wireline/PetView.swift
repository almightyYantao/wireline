import SwiftUI
import AppKit
import WirelineCore

/// The floating "desktop pet": a draggable, always-on-top little sprite that
/// embodies the AI assistant. Clicking it unfolds the full AI chat (reusing
/// `AIPanelView`), which drives whichever terminal tab is currently active — so
/// the pet can run commands and summarize their output for you. The window is
/// borderless & transparent, sized to hug its content so it never blocks the
/// desktop behind the empty corners.
struct PetView: View {
    @Environment(Localizer.self) private var loc
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var expanded = false
    @State private var hovering = false
    @State private var chrome = PetWindowChrome()

    var body: some View {
        // Read the palette version so the sprite recolors with the theme.
        let _ = Palette.shared.version
        VStack(alignment: .trailing, spacing: 8) {
            if expanded {
                PetChatView {
                    withAnimation(spring) { expanded = false }
                }
                .clipShape(RoundedRectangle(cornerRadius: WL.radius(10)))
                .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: 0)
                // The hint always occupies its slot (invisible until hover), so the
                // sprite's position never shifts — only the bubble's opacity changes.
                hintBubble
                    .opacity(hovering && !expanded ? 1 : 0)
                    .allowsHitTesting(false)
                PetSprite(active: expanded)
                    .contentShape(Circle())
                    .onTapGesture { withAnimation(spring) { expanded.toggle() } }
                    .onHover { hovering = $0 }
                    .help(loc("点我聊天 · 拖我移动", "Click to chat · drag to move"))
                    .contextMenu {
                        Button(loc(expanded ? "收起对话" : "开始对话", expanded ? "Collapse" : "Chat")) {
                            withAnimation(spring) { expanded.toggle() }
                        }
                        Divider()
                        Button(loc("隐藏宠物", "Hide pet")) { dismissWindow(id: "pet") }
                    }
            }
        }
        .padding(12)
        .fixedSize()
        .background(WindowAccessor { chrome.configure($0) })
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .focusPet)) { _ in
            let willExpand = !expanded
            withAnimation(spring) { expanded.toggle() }
            if willExpand { chrome.focus() }   // bring forward & make key only when opening
        }
    }

    private var spring: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    private var hintBubble: some View {
        Text(loc("有事找我～", "Need me?"))
            .font(WL.small)
            .foregroundStyle(WL.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(WL.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: WL.radius(8)))
            .overlay(RoundedRectangle(cornerRadius: WL.radius(8)).stroke(WL.border, lineWidth: WL.borderWidth))
            .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Sprite

/// A tiny vector "wireline sprite": a console-green creature with cat ears, a
/// blinking pair of eyes, a terminal-cursor mouth and a wagging cable tail.
/// Purely drawn (no image assets), so it recolors with the active theme.
private struct PetSprite: View {
    var active: Bool
    @State private var breathe = false
    @State private var eyeOpen = true
    @State private var tailWag = false

    var body: some View {
        ZStack {
            // Soft glow halo.
            Circle()
                .fill(WL.green.opacity(active ? 0.30 : 0.16))
                .frame(width: 90, height: 90)
                .blur(radius: 18)

            // Cable tail (the Wireline motif), poking out behind the body.
            CableTail()
                .stroke(WL.green.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 46, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(WL.greenBright).frame(width: 7, height: 7)   // the plug
                }
                .rotationEffect(.degrees(tailWag ? 9 : -6), anchor: .topLeading)
                .offset(x: 30, y: 28)

            // Ears (drawn before the head so the head overlaps their base).
            HStack(spacing: 26) {
                Ear(); Ear()
            }
            .offset(y: -32)

            // Head / body.
            Circle()
                .fill(LinearGradient(colors: [WL.surface, WL.bg], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(WL.green.opacity(0.9), lineWidth: 2))
                .frame(width: 66, height: 66)

            // Face.
            VStack(spacing: 5) {
                HStack(spacing: 13) {
                    Eye(open: eyeOpen); Eye(open: eyeOpen)
                }
                Text(active ? "‿" : "▁")
                    .font(WL.mono(11, .bold))
                    .foregroundStyle(WL.greenBright)
            }
            .offset(y: 3)

            // A ring "awake" indicator while the chat is open.
            if active {
                Circle().stroke(WL.green.opacity(0.5), lineWidth: 1).frame(width: 82, height: 82)
            }
        }
        .frame(width: 96, height: 104)
        .scaleEffect(breathe ? 1.03 : 0.98)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { tailWag = true }
        }
        .task { await blinkLoop() }
    }

    /// Blink at irregular, lifelike intervals.
    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5.5)))
            withAnimation(.easeInOut(duration: 0.09)) { eyeOpen = false }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.09)) { eyeOpen = true }
        }
    }
}

private struct Ear: View {
    var body: some View {
        Triangle()
            .fill(WL.surface)
            .overlay(Triangle().stroke(WL.green.opacity(0.9), lineWidth: 2))
            .frame(width: 22, height: 20)
    }
}

private struct Eye: View {
    var open: Bool
    var body: some View {
        Capsule()
            .fill(WL.greenBright)
            .frame(width: 9, height: open ? 11 : 2)
            .shadow(color: WL.green.opacity(0.8), radius: 3)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// An S-curved cable that reads as a tail.
private struct CableTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.minY),
                   control2: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

// MARK: - Window chrome

/// Turns the pet's hosting window into a borderless, transparent, always-on-top,
/// drag-anywhere panel — and anchors its bottom-right corner, so unfolding the
/// chat grows the window *upward* while the sprite stays put under the cursor
/// (instead of the default content-size behavior that pushes it down).
@MainActor
final class PetWindowChrome {
    private weak var window: NSWindow?
    /// The bottom-right corner (screen coords) we keep pinned across resizes.
    private var anchor: CGPoint = .zero
    private var lastSize: CGSize = .zero
    private var observers: [NSObjectProtocol] = []

    func configure(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.level = .floating                       // stay above normal windows
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false                       // content draws its own shadows
        window.isMovableByWindowBackground = true      // drag the sprite to move it
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none          // kill the thin light strip up top
        window.styleMask.insert(.fullSizeContentView)  // let content run under the titlebar
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        anchor = CGPoint(x: window.frame.maxX, y: window.frame.minY)
        lastSize = window.frame.size

        let nc = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameChanged() }
            })
        }
    }

    /// Bring the pet window forward and make it key so its input can accept text.
    func focus() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Keep the bottom-right corner fixed on a content resize (grow upward); on a
    /// user drag (size unchanged), adopt the new corner as the anchor.
    private func frameChanged() {
        guard let window else { return }
        let f = window.frame
        let resized = abs(f.width - lastSize.width) > 0.5 || abs(f.height - lastSize.height) > 0.5
        if resized {
            lastSize = f.size
            let origin = CGPoint(x: anchor.x - f.width, y: anchor.y)  // pin bottom-right
            if abs(origin.x - f.origin.x) > 0.5 || abs(origin.y - f.origin.y) > 0.5 {
                window.setFrameOrigin(origin)
            }
        } else {
            anchor = CGPoint(x: f.maxX, y: f.minY)   // user moved it
        }
    }
}
