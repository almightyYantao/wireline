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

/// Renders a `PaneNode` recursively: branches lay their children out along an
/// axis with a divider; leaves render a terminal pane.
struct PaneTreeView: View {
    let node: PaneNode
    /// When the AI panel is open, panes don't auto-grab first responder so focus
    /// can stay in the AI input across pane switches.
    var aiOpen: Bool = false

    var body: some View {
        switch node {
        case .leaf(let paneID, let session):
            PaneLeafView(paneID: paneID, sessionID: session, aiOpen: aiOpen)
        case .branch(_, let axis, let first, let second):
            let layout = axis == .vertical
                ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                PaneTreeView(node: first, aiOpen: aiOpen)
                Rectangle().fill(WL.border)
                    .frame(width: axis == .horizontal ? 1 : nil,
                           height: axis == .vertical ? 1 : nil)
                PaneTreeView(node: second, aiOpen: aiOpen)
            }
        }
    }
}

/// One leaf pane: a focus header, the terminal, and a drop target that splits on
/// a tab drop.
struct PaneLeafView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(Localizer.self) private var loc
    let paneID: UUID
    let sessionID: UUID
    var aiOpen: Bool = false
    @State private var targeted = false
    // Measured via a background reader so it never distorts the pane's layout.
    // A GeometryReader in the layout path gives the terminal an unstable size,
    // which garbles reflow when the window resizes.
    @State private var paneSize: CGSize = .zero

    private var focused: Bool { sessions.activeID == sessionID }

    var body: some View {
        if let session = sessions.session(sessionID) {
            VStack(spacing: 0) {
                header(session)
                Rectangle().fill(WL.border).frame(height: 1)
                TerminalHostView(session: session, autoFocus: focused && !aiOpen).id(session.id)
                    .overlay(alignment: .topTrailing) {
                        if session.activeEditor == "vim" { VimHintView() }
                    }
                    // Clicking anywhere in the pane focuses it (runs alongside the
                    // terminal's own click handling, so cursor placement / text
                    // selection still work).
                    .simultaneousGesture(TapGesture().onEnded { sessions.activeID = session.id })
            }
            // Fill the allotted cell so panes divide the space evenly (without
            // this each pane shrinks to its content and leaves gaps).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().stroke(focused ? WL.green.opacity(0.5) : WL.border.opacity(0.4), lineWidth: WL.borderWidth))
            .overlay(targeted ? WL.teal.opacity(0.15) : .clear)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { paneSize = geo.size }
                    .onChange(of: geo.size) { _, s in paneSize = s }
            })
            // Drop another tab here to merge it into this group (splitting this
            // pane along the nearest edge).
            .dropDestination(for: String.self) { items, location in
                guard let str = items.first, let draggedTab = UUID(uuidString: str) else { return false }
                sessions.mergeTab(draggedTab, ontoLeaf: paneID, edge: paneEdge(for: location, in: paneSize))
                return true
            } isTargeted: { targeted = $0 }
        } else {
            Color.clear
        }
    }

    private func header(_ session: TerminalSession) -> some View {
        HStack(spacing: 6) {
            Circle().fill(focused ? WL.green : WL.textDim.opacity(0.6)).frame(width: 6, height: 6)
            Text(session.title).font(WL.small)
                .foregroundStyle(focused ? WL.greenBright : WL.textDim).lineLimit(1)
            Spacer()
            Button { sessions.detachPaneToTab(session.id) } label: {
                Image(systemName: "rectangle.badge.minus").font(WL.small).foregroundStyle(WL.textDim.opacity(0.7))
            }.buttonStyle(.plain).help(loc("拆为独立标签", "Detach to a tab"))
            Button { sessions.close(session.id) } label: {
                Text("[x]").font(WL.small).foregroundStyle(WL.textDim.opacity(0.7))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(focused ? WL.surface : WL.bg)
        .contentShape(Rectangle())
        .onTapGesture { sessions.activeID = session.id }
    }
}
