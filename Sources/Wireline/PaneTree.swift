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

    var body: some View {
        switch node {
        case .leaf(let paneID, let session):
            PaneLeafView(paneID: paneID, sessionID: session, aiOpen: aiOpen)
        case .branch(let id, let axis, let first, let second):
            SplitBranchView(branchID: id, axis: axis, first: first, second: second, aiOpen: aiOpen)
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
    /// The branch's size, read from a background reader (never in the layout
    /// path) so a drag can turn points into a ratio.
    @State private var size: CGSize = .zero

    var body: some View {
        SplitLayout(axis: axis, ratio: sessions.ratio(for: branchID)) {
            PaneTreeView(node: first, aiOpen: aiOpen)
            SplitDivider(axis: axis,
                         length: axis == .horizontal ? size.width : size.height,
                         ratio: sessions.ratio(for: branchID),
                         onDrag: { sessions.setRatio($0, for: branchID) },
                         onReset: { wlAnimateTerminalLayout { sessions.setRatio(0.5, for: branchID) } })
            PaneTreeView(node: second, aiOpen: aiOpen)
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

    var animatableData: CGFloat {
        get { ratio }
        set { ratio = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let divider: CGFloat = 1
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

/// The 1pt line between panes, with a 7pt grab zone: drag to resize, double-
/// click to even out. Shows the resize cursor and brightens on hover.
private struct SplitDivider: View {
    let axis: SplitAxis
    let length: CGFloat
    let ratio: CGFloat
    let onDrag: (CGFloat) -> Void
    let onReset: () -> Void
    @State private var hover = false
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(hover || dragStart != nil ? WL.green.opacity(0.6) : WL.border)
            .overlay {
                Color.clear
                    .frame(width: axis == .horizontal ? 7 : nil, height: axis == .vertical ? 7 : nil)
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
                Rectangle().fill(WL.border.opacity(0.6)).frame(height: 1)
                TerminalHostView(session: session, autoFocus: focused && !aiOpen).id(session.id)
                    .wlTerminalPadding(store)
                    .overlay(alignment: .top) {
                        if session.connectionState == .disconnected {
                            DisconnectedBanner(session: session)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if session.activeEditor == "vim" { VimHintView() }
                    }
                    .overlay { InlineAICommandView(session: session, isActive: focused) }
                    .animation(Motion.banner, value: session.connectionState)
                    // Clicking anywhere in the pane focuses it (runs alongside the
                    // terminal's own click handling, so cursor placement / text
                    // selection still work).
                    .simultaneousGesture(TapGesture().onEnded { sessions.activeID = session.id })
            }
            // Fill the allotted cell so panes divide the space evenly (without
            // this each pane shrinks to its content and leaves gaps).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Unfocused panes recede (Ghostty's unfocused-split-opacity) instead
            // of the focused one wearing a border.
            .overlay {
                WL.bg.opacity(focused || zoomed ? 0 : 1 - store.unfocusedSplitOpacity)
                    .allowsHitTesting(false)
                    .animation(Motion.state, value: focused)
            }
            .overlay(targeted ? WL.teal.opacity(0.15) : .clear)
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
                guard let str = items.first, let draggedTab = UUID(uuidString: str) else { return false }
                wlAnimateTerminalLayout {
                    sessions.mergeTab(draggedTab, ontoLeaf: paneID, edge: paneEdge(for: location, in: paneSize))
                }
                return true
            } isTargeted: { targeted = $0 }
        } else {
            Color.clear
        }
    }

    private func header(_ session: TerminalSession) -> some View {
        HStack(spacing: 6) {
            Circle().fill(focused ? WL.green : WL.textDim.opacity(0.5)).frame(width: 6, height: 6)
            Text(session.title).font(WL.small)
                .foregroundStyle(focused ? WL.textPrimary : WL.textDim).lineLimit(1)
            if zoomed {
                Text(loc("已放大", "Zoomed")).font(WL.caption).foregroundStyle(WL.green)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(WL.green.opacity(0.12), in: Capsule())
            }
            Spacer()
            HStack(spacing: 0) {
                Button { wlAnimateTerminalLayout { sessions.activeID = session.id; sessions.toggleZoom() } } label: {
                    Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.wlIcon(size: 20)).help(loc(zoomed ? "还原分屏" : "放大此分屏", zoomed ? "Restore splits" : "Zoom this pane"))
                if !zoomed {
                    Button { sessions.detachPaneToTab(session.id) } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 10, weight: .medium))
                    }.buttonStyle(.wlIcon(size: 20)).help(loc("拆为独立标签", "Detach to a tab"))
                }
                Button { wlAnimateTerminalLayout { sessions.close(session.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.wlIcon(size: 20)).help(loc("关闭分屏", "Close pane"))
            }
            .opacity(hover || focused ? 1 : 0)
            .animation(Motion.hover, value: hover)
        }
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 26)
        .background(focused ? WL.surface.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { sessions.activeID = session.id }
    }
}
