import SwiftUI

/// Where a tab was dropped within a pane — determines how the pane splits.
enum PaneEdge { case leading, trailing, top, bottom, center }

/// A binary tree of terminal panes. A leaf shows one session; a branch splits
/// two child nodes along an axis. Supports arbitrary nesting → any number of
/// panes. A session appears in at most one leaf (its terminal view is a single
/// NSView and can't be embedded twice).
indirect enum PaneNode: Identifiable, Equatable {
    case leaf(id: UUID, session: UUID)
    case branch(id: UUID, axis: SplitAxis, first: PaneNode, second: PaneNode)

    var id: UUID {
        switch self {
        case .leaf(let id, _): return id
        case .branch(let id, _, _, _): return id
        }
    }

    static func makeLeaf(_ session: UUID) -> PaneNode { .leaf(id: UUID(), session: session) }

    /// Every session shown, in visual order.
    var sessionIDs: [UUID] {
        switch self {
        case .leaf(_, let s): return [s]
        case .branch(_, _, let a, let b): return a.sessionIDs + b.sessionIDs
        }
    }

    /// The pane id of the leaf currently showing `session`, if any.
    func leafID(for session: UUID) -> UUID? {
        switch self {
        case .leaf(let id, let s): return s == session ? id : nil
        case .branch(_, _, let a, let b): return a.leafID(for: session) ?? b.leafID(for: session)
        }
    }

    func contains(leaf id: UUID) -> Bool {
        switch self {
        case .leaf(let lid, _): return lid == id
        case .branch(let bid, _, let a, let b): return bid == id || a.contains(leaf: id) || b.contains(leaf: id)
        }
    }

    /// Ids of every branch (split) in the tree.
    var branchIDs: [UUID] {
        switch self {
        case .leaf: return []
        case .branch(let id, _, let a, let b): return [id] + a.branchIDs + b.branchIDs
        }
    }

    var anyLeafID: UUID? {
        switch self {
        case .leaf(let id, _): return id
        case .branch(_, _, let a, _): return a.anyLeafID
        }
    }

    /// Remove the leaf holding `session`; collapse the parent branch to its
    /// surviving child. Returns nil if nothing remains.
    func removingSession(_ session: UUID) -> PaneNode? {
        switch self {
        case .leaf(_, let s): return s == session ? nil : self
        case .branch(let id, let axis, let first, let second):
            switch (first.removingSession(session), second.removingSession(session)) {
            case (nil, nil):            return nil
            case (let x?, nil):         return x
            case (nil, let y?):         return y
            case (let x?, let y?):      return .branch(id: id, axis: axis, first: x, second: y)
            }
        }
    }

    /// Split the leaf `targetID`, inserting a new leaf for `session` on `edge`
    /// (center = replace the leaf's session).
    func splitting(leaf targetID: UUID, insert session: UUID, edge: PaneEdge) -> PaneNode {
        switch self {
        case .leaf(let id, let existing):
            guard id == targetID else { return self }
            if edge == .center { return .leaf(id: id, session: session) }
            let axis: SplitAxis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
            let newLeaf = PaneNode.makeLeaf(session)
            let keep = PaneNode.leaf(id: id, session: existing)
            let newFirst = (edge == .leading || edge == .top)
            return .branch(id: UUID(), axis: axis,
                           first: newFirst ? newLeaf : keep,
                           second: newFirst ? keep : newLeaf)
        case .branch(let id, let axis, let first, let second):
            return .branch(id: id, axis: axis,
                           first: first.splitting(leaf: targetID, insert: session, edge: edge),
                           second: second.splitting(leaf: targetID, insert: session, edge: edge))
        }
    }

    /// Split the leaf `targetID`, inserting an existing `node` (which may itself
    /// be a whole subtree — e.g. a merged tab) on the given edge.
    func splitting(leaf targetID: UUID, insertNode node: PaneNode, edge: PaneEdge) -> PaneNode {
        switch self {
        case .leaf(let id, _):
            guard id == targetID, edge != .center else { return self }
            let axis: SplitAxis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
            let newFirst = (edge == .leading || edge == .top)
            return .branch(id: UUID(), axis: axis,
                           first: newFirst ? node : self,
                           second: newFirst ? self : node)
        case .branch(let id, let axis, let first, let second):
            return .branch(id: id, axis: axis,
                           first: first.splitting(leaf: targetID, insertNode: node, edge: edge),
                           second: second.splitting(leaf: targetID, insertNode: node, edge: edge))
        }
    }

    /// The branches from the root down to the leaf `id` (root first; the leaf
    /// itself excluded). Empty if the leaf isn't in this tree.
    func ancestors(ofLeaf id: UUID) -> [PaneNode] {
        switch self {
        case .leaf: return []
        case .branch(_, _, let a, let b):
            if a.contains(leaf: id) { return [self] + a.ancestors(ofLeaf: id) }
            if b.contains(leaf: id) { return [self] + b.ancestors(ofLeaf: id) }
            return []
        }
    }

    var axis: SplitAxis? {
        if case .branch(_, let axis, _, _) = self { return axis }
        return nil
    }

    /// How many rows this node stacks: a side-by-side split or a single pane is
    /// one row; a top/bottom split adds its halves.
    var rowCount: Int {
        switch self {
        case .leaf: return 1
        case .branch(_, let axis, let a, let b):
            return axis == .vertical ? a.rowCount + b.rowCount : 1
        }
    }

    /// Replace the node `targetID` (leaf or branch) with a top/bottom split:
    /// the node on top, `node` below, under a branch with id `branchID`.
    func stacking(_ node: PaneNode, below targetID: UUID, branchID: UUID) -> PaneNode {
        if id == targetID { return .branch(id: branchID, axis: .vertical, first: self, second: node) }
        switch self {
        case .leaf: return self
        case .branch(let id, let axis, let first, let second):
            return .branch(id: id, axis: axis,
                           first: first.stacking(node, below: targetID, branchID: branchID),
                           second: second.stacking(node, below: targetID, branchID: branchID))
        }
    }

    /// Change which session a leaf shows.
    func replacing(leaf targetID: UUID, session: UUID) -> PaneNode {
        switch self {
        case .leaf(let id, _):
            return id == targetID ? .leaf(id: id, session: session) : self
        case .branch(let id, let axis, let first, let second):
            return .branch(id: id, axis: axis,
                           first: first.replacing(leaf: targetID, session: session),
                           second: second.replacing(leaf: targetID, session: session))
        }
    }
}

/// Which edge zone a drop location falls in (nearest edge if within 25%, else
/// center).
func paneEdge(for point: CGPoint, in size: CGSize) -> PaneEdge {
    guard size.width > 0, size.height > 0 else { return .center }
    let fx = point.x / size.width, fy = point.y / size.height
    let dists: [(PaneEdge, CGFloat)] = [
        (.leading, fx), (.trailing, 1 - fx), (.top, fy), (.bottom, 1 - fy)
    ]
    if let nearest = dists.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 { return nearest.0 }
    return .center
}

// MARK: - Cards

/// Gap between pane cards, and between the cards and the window edge.
let wlPaneGap: CGFloat = 8

extension WL {
    /// The canvas the pane cards sit on: a touch deeper than the theme
    /// background, so the cards (which carry the terminal's own background)
    /// read as raised.
    static var paneCanvas: Color { Color.black.opacity(isLight ? 0.045 : 0.26) }
}

extension View {
    /// A terminal pane as a raised card: theme background, hairline edge and a
    /// soft shadow. The shadow sits on the card *shape* only — on the content it
    /// would shadow the (transparent) terminal's glyphs.
    func wlPaneCard(focused: Bool = true, opacity: Double = 1) -> some View {
        let shape = RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous)
        return self
            .background {
                shape.fill(WL.bg.opacity(opacity))
                    .shadow(color: .black.opacity(WL.depth(focused ? 0.22 : 0.1)),
                            radius: focused ? 10 : 5, y: focused ? 3 : 1)
            }
            .overlay {
                shape.strokeBorder(WL.textPrimary.opacity(focused ? (WL.isLight ? 0.12 : 0.14) : 0.06),
                                   lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .animation(Motion.state, value: focused)
    }
}

// MARK: - Session glyph

/// The icon for what a session is showing: the foreground program of a local
/// shell (claude, node, vim …), else the session kind (SSH host, SFTP, shell).
struct SessionGlyph: View {
    @Environment(HostStore.self) private var store
    let session: TerminalSession
    var size: CGFloat = 11

    var body: some View {
        let look = Self.look(session, store: store)
        Group {
            switch look.icon {
            case .brand(let b):
                if let img = b.image {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .frame(width: size + 1, height: size + 1)
                } else {
                    Image(systemName: "terminal").font(.system(size: size, weight: .medium))
                }
            case .symbol(let name):
                Image(systemName: name).font(.system(size: size, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .foregroundStyle(look.tint)
        .frame(width: size + 5)
        .animation(Motion.state, value: look.key)
    }

    enum Icon { case brand(BrandIcon), symbol(String) }
    struct Look { var icon: Icon; var tint: Color; var key: String }

    private static func brand(_ b: BrandIcon) -> Look {
        Look(icon: .brand(b), tint: b.hex.map { Color(hex: $0) } ?? WL.textPrimary, key: b.rawValue)
    }
    private static func symbol(_ s: String, _ tint: Color) -> Look { Look(icon: .symbol(s), tint: tint, key: s) }

    /// What's running in the pane (local shells: the PTY's foreground program),
    /// else what kind of session it is.
    @MainActor
    static func look(_ s: TerminalSession, store: HostStore) -> Look {
        if let prog = (s.shownEditor ?? s.foregroundName)?.lowercased() {
            switch prog {
            case "claude":                                   return brand(.claude)
            case "codex":                                    return brand(.openai)
            case "gemini":                                   return brand(.gemini)
            case "node", "npm", "npx", "pnpm", "yarn":       return brand(.node)
            case "bun", "bunx":                              return brand(.bun)
            case "deno":                                     return brand(.deno)
            case "python", "ipython", "uv", "pip":           return brand(.python)
            case "git", "lazygit", "tig", "gitui":           return brand(.git)
            case "docker", "lazydocker", "colima":           return brand(.docker)
            case "kubectl", "k9s", "helm":                   return brand(.kubernetes)
            case "vim", "vi", "view", "vimdiff":             return brand(.vim)
            case "nvim":                                     return brand(.neovim)
            case "cargo", "rustc":                           return brand(.rust)
            case "go":                                       return brand(.go)
            case "psql", "pgcli":                            return brand(.postgres)
            case "mysql", "mycli":                           return brand(.mysql)
            case "redis-cli", "redis-server":                return brand(.redis)
            case "aider", "cursor-agent", "opencode", "amp": return symbol("sparkles", WL.purple)
            case "hx", "nano", "emacs", "micro":             return symbol("pencil.line", WL.green)
            case "htop", "btop", "top", "glances":           return symbol("chart.bar.xaxis", WL.teal)
            case "ssh", "mosh":                              return symbol("network", WL.teal)
            case "make", "swift", "xcodebuild", "gradle":    return symbol("hammer", WL.amber)
            case "less", "more", "man", "bat":               return symbol("doc.text", WL.textDim)
            default:                                          return symbol("gearshape.2", WL.textDim)
            }
        }
        switch s.kind {
        case .ssh(let alias, _, _, _, _):
            return symbol("server.rack", store.groupColor(forAlias: alias)?.color ?? WL.teal)
        case .sftp(let alias, _, _):
            return symbol("folder", store.groupColor(forAlias: alias)?.color ?? WL.teal)
        case .localShell:
            return symbol("terminal", WL.textDim)
        case .rdp:
            return brand(.windows)
        }
    }
}

// MARK: - Recursive rendering

/// Renders a `PaneNode` recursively: branches lay their two children out with
/// `SplitLayout` (ratio from the store) around a draggable divider; leaves
/// render a terminal pane.
struct PaneTreeView: View {
    @Environment(SessionStore.self) private var sessions
    let node: PaneNode
    /// When the AI panel is open, panes don't auto-grab first responder so focus
    /// can stay in the AI input across pane switches.
    var aiOpen: Bool = false
    /// The zoomed pane's session, if any. Zoom happens *in* this layout — every
    /// split on its path gives it the whole space — so it animates as the card
    /// growing, not as a swap to another view.
    var zoomed: UUID? = nil

    var body: some View {
        switch node {
        case .leaf(let paneID, let session):
            PaneLeafView(paneID: paneID, sessionID: session, aiOpen: aiOpen,
                         zoomed: zoomed == session, hiddenByZoom: zoomed != nil && zoomed != session)
        case .branch(let id, let axis, let first, let second):
            SplitBranchView(branchID: id, axis: axis, first: first, second: second, aiOpen: aiOpen, zoomed: zoomed)
        }
    }
}

/// One split: first child, divider, second child.
private struct SplitBranchView: View {
    @Environment(SessionStore.self) private var sessions
    let branchID: UUID
    let axis: SplitAxis
    let first: PaneNode
    let second: PaneNode
    let aiOpen: Bool
    let zoomed: UUID?
    /// The branch's size, read from a background reader (never in the layout
    /// path) so a drag can turn points into a ratio.
    @State private var size: CGSize = .zero

    /// Zoom on this path: the side holding the zoomed pane takes everything.
    private var layoutRatio: CGFloat {
        guard let z = zoomed else { return sessions.ratio(for: branchID) }
        if first.sessionIDs.contains(z) { return 1 }
        if second.sessionIDs.contains(z) { return 0 }
        return sessions.ratio(for: branchID)
    }

    var body: some View {
        let zoomedHere = zoomed.map { (first.sessionIDs + second.sessionIDs).contains($0) } ?? false
        SplitLayout(axis: axis, ratio: layoutRatio, gap: zoomedHere ? 0 : wlPaneGap) {
            PaneTreeView(node: first, aiOpen: aiOpen, zoomed: zoomed)
            SplitDivider(axis: axis,
                         length: axis == .horizontal ? size.width : size.height,
                         ratio: sessions.ratio(for: branchID),
                         onDrag: { sessions.setRatio($0, for: branchID) },
                         onReset: { wlAnimateTerminalLayout { sessions.setRatio(0.5, for: branchID) } })
                .allowsHitTesting(!zoomedHere)
            PaneTreeView(node: second, aiOpen: aiOpen, zoomed: zoomed)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { size = geo.size }
                .onChange(of: geo.size) { _, s in size = s }
        })
    }
}

/// Lays out [first, divider, second] along an axis: the divider keeps its own
/// thickness, the children share the rest by `ratio`. Animatable, so equalize
/// and double-click-reset glide instead of jumping.
struct SplitLayout: Layout {
    var axis: SplitAxis
    var ratio: CGFloat
    var gap: CGFloat = wlPaneGap

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ratio, gap) }
        set { ratio = newValue.first; gap = newValue.second }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let divider = max(0, gap)
        if axis == .horizontal {
            let avail = max(0, bounds.width - divider)
            let w1 = (avail * ratio).rounded()
            subviews[0].place(at: bounds.origin, proposal: .init(width: w1, height: bounds.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + w1, y: bounds.minY),
                              proposal: .init(width: divider, height: bounds.height))
            subviews[2].place(at: CGPoint(x: bounds.minX + w1 + divider, y: bounds.minY),
                              proposal: .init(width: avail - w1, height: bounds.height))
        } else {
            let avail = max(0, bounds.height - divider)
            let h1 = (avail * ratio).rounded()
            subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: h1))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h1),
                              proposal: .init(width: bounds.width, height: divider))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h1 + divider),
                              proposal: .init(width: bounds.width, height: avail - h1))
        }
    }
}

/// The gap between two pane cards. The whole gap is the grab zone: drag to
/// resize, double-click to even out. A short handle appears on hover.
private struct SplitDivider: View {
    let axis: SplitAxis
    let length: CGFloat
    let ratio: CGFloat
    let onDrag: (CGFloat) -> Void
    let onReset: () -> Void
    @State private var hover = false
    @State private var dragStart: CGFloat?

    var body: some View {
        Color.clear
            .overlay {
                Capsule()
                    .fill(dragStart != nil ? WL.green.opacity(0.8) : WL.textDim.opacity(0.45))
                    .frame(width: axis == .horizontal ? 3 : 32, height: axis == .vertical ? 3 : 32)
                    .opacity(hover || dragStart != nil ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(Motion.hover) { hover = inside }
                        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
                        if inside { cursor.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                guard length > 0 else { return }
                                let start = dragStart ?? ratio
                                if dragStart == nil { dragStart = start }
                                let delta = axis == .horizontal ? g.translation.width : g.translation.height
                                onDrag(start + delta / length)
                            }
                            .onEnded { _ in withAnimation(Motion.hover) { dragStart = nil } }
                    )
                    .onTapGesture(count: 2, perform: onReset)
            }
            .help(Localizer.shared.t("拖动调整大小 · 双击均分", "Drag to resize · double-click to even out"))
    }
}

/// One leaf pane: a focus header, the terminal, and a drop target that splits on
/// a tab drop.
struct PaneLeafView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(HostStore.self) private var store
    @Environment(Localizer.self) private var loc
    let paneID: UUID
    let sessionID: UUID
    var aiOpen: Bool = false
    /// Shown alone (zoomed): no dimming, header marks the zoom.
    var zoomed = false
    /// Squeezed away because another pane is zoomed.
    var hiddenByZoom = false
    @State private var targeted = false
    @State private var hover = false
    // Measured via a background reader so it never distorts the pane's layout.
    // A GeometryReader in the layout path gives the terminal an unstable size,
    // which garbles reflow when the window resizes.
    @State private var paneSize: CGSize = .zero

    private var focused: Bool { sessions.activeID == sessionID }

    var body: some View {
        if let session = sessions.session(sessionID) {
            VStack(spacing: 0) {
                header(session)
                GroupColorRule(alias: session.alias)
                if let rdp = session.rdp {
                    // A remote desktop fills the card edge to edge (no terminal padding).
                    RDPPaneContent(session: session, rdp: rdp, autoFocus: focused && !aiOpen).id(session.id)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: WL.radius(10),
                                                          bottomTrailingRadius: WL.radius(10), style: .continuous))
                } else {
                TerminalHostView(session: session, autoFocus: focused && !aiOpen).id(session.id)
                    .wlTerminalPadding(store)
                    .overlay(alignment: .top) {
                        if session.connectionState == .disconnected, !session.connect.isShowingFailure {
                            DisconnectedBanner(session: session)
                        }
                    }
                    .overlay { ConnectPanelOverlay(session: session) }
                    .overlay(alignment: .topTrailing) {
                        if session.shownEditor == "vim" { VimHintView() }
                    }
                    .overlay { InlineAICommandView(session: session, isActive: focused) }
                    .animation(Motion.banner, value: session.connectionState)
                    // Clicks inside the terminal focus the pane from the terminal
                    // view itself (see WirelineTerminalView.mouseDown).
                }
            }
            // Fill the allotted cell so panes divide the space evenly (without
            // this each pane shrinks to its content and leaves gaps).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Unfocused panes recede (Ghostty's unfocused-split-opacity); the
            // card's edge and shadow carry the focus too.
            .overlay {
                cardShape.fill(WL.bg.opacity(focused || zoomed ? 0 : (1 - store.unfocusedSplitOpacity) * 0.6))
                    .allowsHitTesting(false)
                    .animation(Motion.state, value: focused)
            }
            .overlay(cardShape.fill(WL.teal.opacity(targeted ? 0.15 : 0)).allowsHitTesting(false))
            .wlPaneCard(focused: focused || zoomed, opacity: store.terminalOpacity * WL.chromeOpacity)
            .overlay(alignment: .topTrailing) { SnippetPanelHost(session: session, top: 32) }
            .opacity(hiddenByZoom ? 0 : 1)
            .allowsHitTesting(!hiddenByZoom)
            .wlHover($hover)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { paneSize = geo.size; sessions.paneFrames[sessionID] = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        paneSize = f.size; sessions.paneFrames[sessionID] = f
                    }
            })
            // Drop another tab here to merge it into this group (splitting this
            // pane along the nearest edge).
            .dropDestination(for: String.self) { items, location in
                guard let str = items.first else { return false }
                return dropOntoPane(str, leaf: paneID, edge: paneEdge(for: location, in: paneSize),
                                    store: store, sessions: sessions)
            } isTargeted: { targeted = $0 }
            // An open snippet panel may hang past this pane: draw it over the neighbours.
            .zIndex(SnippetPanel.shared.isOpen(for: sessionID) ? 1 : 0)
        } else {
            Color.clear
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WL.radius(10), style: .continuous)
    }

    private func header(_ session: TerminalSession) -> some View {
        PaneHeader(session: session, focused: focused, zoomed: zoomed, showActions: hover || focused || SnippetPanel.shared.isOpen(for: session.id),
                   onActivate: { sessions.activeID = session.id }) {
            if session.rdp == nil { SnippetToolbarButton(session: session, size: 22) }
            paneButton("rectangle.split.2x1", loc("向右分屏", "Split right")) {
                sessions.activeID = session.id
                wlAnimateTerminalLayout { sessions.splitActive(.trailing) }
            }
            paneButton("rectangle.split.1x2", loc("向下分屏", "Split down")) {
                sessions.activeID = session.id
                wlAnimateTerminalLayout { sessions.splitActive(.bottom) }
            }
            paneButton(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       loc(zoomed ? "还原分屏" : "放大此分屏", zoomed ? "Restore splits" : "Zoom this pane")) {
                wlAnimateTerminalLayout { sessions.activeID = session.id; sessions.toggleZoom() }
            }
            paneButton("xmark", loc("关闭分屏", "Close pane")) {
                wlAnimateTerminalLayout { sessions.close(session.id) }
            }
        }
        .wlContextMenu(zoomed ? [] : [
            .item(loc("拆为独立标签", "Detach to a Tab"), systemImage: "rectangle.portrait.and.arrow.right") {
                sessions.detachPaneToTab(session.id)
            },
            .divider,
            .item(loc("关闭分屏", "Close Pane"), systemImage: "xmark", destructive: true) {
                wlAnimateTerminalLayout { sessions.close(session.id) }
            },
        ])
    }

    private func paneButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.wlIcon(size: 22))
        .help(help)
    }
}

/// A pane card's title row: what's running (icon), the title, where it is
/// (directory / host), and — on hover or focus — the pane actions.
struct PaneHeader<Actions: View>: View {
    @Environment(Localizer.self) private var loc
    let session: TerminalSession
    let focused: Bool
    var zoomed = false
    var showActions = true
    var onActivate: () -> Void = {}
    @ViewBuilder var actions: Actions

    /// "~/Sites/rex-snake" for a local shell; the endpoint for SSH.
    private var place: String? {
        if case .localShell = session.kind {
            guard let d = session.currentDirectory else { return nil }
            let short = (d as NSString).abbreviatingWithTildeInPath
            // The title already names it ("~", or "user@host: ~").
            return short == session.title || session.title.hasSuffix(": " + short) ? nil : short
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 7) {
            SessionGlyph(session: session, size: 11)
                .opacity(focused ? 1 : 0.7)
            Text(session.title)
                .font(WL.small.weight(.semibold))
                .foregroundStyle(focused ? WL.textPrimary : WL.textDim)
                .lineLimit(1)
            if let place {
                Text(place).font(WL.small).foregroundStyle(WL.textDim)
                    .lineLimit(1).truncationMode(.head)
            }
            if zoomed {
                Text(loc("已放大", "Zoomed")).font(WL.caption).foregroundStyle(WL.green)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(WL.green.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) { actions }
                .foregroundStyle(WL.textDim)
                .opacity(showActions ? 1 : 0)
                .animation(Motion.hover, value: showActions)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
    }
}

/// Something dropped on a terminal pane: a tab (its id) merges into a split; a
/// host (its alias, dragged from the sidebar or overview) opens a new SSH pane
/// on that edge.
@MainActor
func dropOntoPane(_ payload: String, leaf: UUID, edge: PaneEdge,
                  store: HostStore, sessions: SessionStore) -> Bool {
    if let tab = UUID(uuidString: payload) {
        wlAnimateTerminalLayout { sessions.mergeTab(tab, ontoLeaf: leaf, edge: edge) }
        return true
    }
    guard let host = store.hosts.first(where: { $0.alias == payload }) else { return false }
    store.lastConnected[host.alias] = Date()
    wlAnimateTerminalLayout {
        sessions.splitHost(host, password: store.password(for: host),
                           sudoPassword: store.sudoPassword(for: host),
                           rdp: host.isRDP ? store.rdpTarget(for: host) : nil, ontoLeaf: leaf, edge: edge)
    }
    return true
}
