import Foundation

/// Immutable picture of one committed tree for point-based hit-testing (H02a, D25).
///
/// Built at the commit point — the same instant `LayerRenderer` reads frames, `subnodes` and
/// `style.visual` to position layers — so what hit-testing sees is exactly what is on screen.
/// The live tree keeps mutating between commits (a style write, a reparent, a dispose are
/// visible in `Node` immediately, while the screen still shows the previous commit); hit-testing
/// therefore never reads live nodes, only this snapshot, and resolves the resulting `NodeID`
/// against the live tree afterwards (T01).
///
/// Children are stored in `subnodes` order — the paint order for equal `zIndex` (D32). A node
/// without a committed frame is skipped with its subtree, as the renderer skips it.
///
/// Ownership: a plain value; holds no `Node`, no layer, no closure. Isolation: none — Sendable,
/// built on the MainActor and readable anywhere. Errors: none. Cancellation: not applicable.
public struct HitTestSnapshot: Sendable {
    /// One committed node: its place in the tree, its geometry and the presentation values that
    /// affect hit-testing (`zIndex`, `overflow`, `opacity`, `transform`).
    ///
    /// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct Record: Sendable, Hashable {
        /// The node this record was taken from.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let id: NodeID

        /// Parent at commit time; `nil` for the root.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let parent: NodeID?

        /// Committed children in `subnodes` order — last is painted in front for equal `zIndex`.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let children: [NodeID]

        /// Committed frame, absolute in the root's coordinate space (as `LayoutPlacement.frame`).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let frame: LayoutFrame

        /// Committed presentation values — the ones `LayerRenderer` applied for this frame.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let visual: LayoutVisualProperties

        /// Whether the node is an implicit `Arrangement` wrapper — transparent to hit-testing
        /// (D19): never a target itself, its children still are.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let isArrangementWrapper: Bool

        /// Axis-aligned box, in the same space as `frame`, around everything this node can hit:
        /// its own frame and — unless it clips — every descendant's box, all carried through
        /// this node's transform. Computed bottom-up at capture, so a hit-test can skip a whole
        /// subtree with one containment check without ever reading the untransformed `frame`
        /// of a parent as a bound for its children (D17 (6), T03).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let hittableBounds: LayoutFrame
    }

    /// Identity of the committed root.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let root: NodeID

    /// The bridge mount this snapshot belongs to (D21): a later `attach` produces a new epoch,
    /// so a snapshot — and any pointer session started on it — can be told apart from the tree
    /// mounted now.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let mountEpoch: UInt64

    /// Host bounds the commit was laid out for, in the same coordinate space as every `frame`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bounds: LayoutFrame

    /// Per-`ScrollNode` scroll offset, in content space, needed by the point-transform step
    /// (R07, D18): populated at commit time from `NativeScrollBacking.contentOffset` — native
    /// is the source of truth (`r06-scroll-api-sketch.md` §8), Trellis never re-derives it.
    /// Empty for a snapshot with no committed `.scroll` node, or before R07's renderer wiring
    /// runs. `withScrollOffsets(_:)` refreshes this cheaply (no re-walk of the tree) on every
    /// native-driven offset tick between geometry commits.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scrollOffsets: [NodeID: LayoutPoint]

    private let records: [NodeID: Record]

    /// Number of committed nodes in the snapshot.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var count: Int { records.count }

    /// The record for one committed node, or `nil` if the node was not part of this commit.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func record(for identity: NodeID) -> Record? { records[identity] }

    /// Captures `root` and every committed descendant. Returns `nil` when the root itself has no
    /// committed frame — nothing is on screen, so there is nothing to hit.
    ///
    /// Ownership: borrows `root` for the duration of the call and retains nothing. Isolation:
    /// MainActor — reads the live tree, which is why it must run at the commit point. Errors: a
    /// descendant without a frame is skipped with its subtree, mirroring the renderer.
    /// Cancellation: not applicable.
    @MainActor
    public init?(
        root: Node,
        mountEpoch: UInt64,
        bounds: LayoutFrame,
        scrollOffsets: [NodeID: LayoutPoint] = [:]
    ) {
        guard root.calculatedFrame != nil else { return nil }

        var records: [NodeID: Record] = [:]
        Self.capture(root, parent: nil, into: &records)
        self.root = root.id
        self.mountEpoch = mountEpoch
        self.bounds = bounds
        self.records = records
        self.scrollOffsets = scrollOffsets
    }

    private init(
        root: NodeID,
        mountEpoch: UInt64,
        bounds: LayoutFrame,
        records: [NodeID: Record],
        scrollOffsets: [NodeID: LayoutPoint]
    ) {
        self.root = root
        self.mountEpoch = mountEpoch
        self.bounds = bounds
        self.records = records
        self.scrollOffsets = scrollOffsets
    }

    /// Returns a copy of this snapshot with `scrollOffsets` replaced — the offset-only commit
    /// path (R07's plan): a native-driven offset tick refreshes hit-test's view of a
    /// `ScrollNode`'s offset without re-walking the tree (`capture(_:parent:into:)` is not
    /// called again), which is the concrete meaning of "offset-only путь" for hit-testing.
    ///
    /// Ownership: returns a new value sharing this snapshot's records. Isolation: none. Errors:
    /// none. Cancellation: not applicable.
    public func withScrollOffsets(_ scrollOffsets: [NodeID: LayoutPoint]) -> HitTestSnapshot {
        HitTestSnapshot(
            root: root,
            mountEpoch: mountEpoch,
            bounds: bounds,
            records: records,
            scrollOffsets: scrollOffsets
        )
    }

    /// The live node for a committed identity, if its committed route still describes the tree
    /// under `root` and the node is not disposed — the same D36-style live guard
    /// `SemanticSnapshot.liveNode(for:under:)` already uses, needed here so a host bridge can
    /// resolve a `ScrollNode`'s identity back to the live node it publishes `ScrollState` to
    /// (R07) without a second, module-private tree walk.
    ///
    /// Ownership: returns a borrowed reference; do not retain it past the call. Isolation:
    /// MainActor. Errors: `nil` for a stale identity, another root, a broken route, or a
    /// disposed node. Cancellation: not applicable.
    @MainActor
    public func liveNode(for identity: NodeID, under root: Node) -> Node? {
        guard root.id == self.root, let route = route(to: identity) else { return nil }

        var current = root
        for step in route.dropFirst() {
            guard let next = current.subnodes.first(where: { $0.id == step }) else { return nil }

            current = next
        }
        return current.isDisposed ? nil : current
    }

    /// Records `node` and its committed subtree; returns the subtree's hittable box in the
    /// parent's space, or `nil` when the node has no committed frame.
    @MainActor
    @discardableResult
    private static func capture(
        _ node: Node,
        parent: NodeID?,
        into records: inout [NodeID: Record]
    ) -> LayoutFrame? {
        guard let frame = node.calculatedFrame else { return nil }

        let visual = node.style.visual
        var children: [NodeID] = []
        var union = frame
        for child in node.subnodes {
            guard let childBounds = capture(child, parent: node.id, into: &records) else {
                continue
            }

            children.append(child.id)
            if visual.overflow == .visible { union = Self.union(union, childBounds) }
        }
        let bounds = Self.boundingBox(of: union, transformedBy: visual.transform, in: frame)
        records[node.id] = Record(
            id: node.id,
            parent: parent,
            children: children,
            frame: frame,
            visual: visual,
            isArrangementWrapper: node.isArrangementWrapper,
            hittableBounds: bounds
        )
        return bounds
    }

    private static func union(_ lhs: LayoutFrame, _ rhs: LayoutFrame) -> LayoutFrame {
        let minX = min(lhs.origin.x, rhs.origin.x)
        let minY = min(lhs.origin.y, rhs.origin.y)
        let maxX = max(lhs.origin.x + lhs.width, rhs.origin.x + rhs.width)
        let maxY = max(lhs.origin.y + lhs.height, rhs.origin.y + rhs.height)
        return LayoutFrame(
            origin: LayoutPoint(x: minX, y: minY),
            width: maxX - minX,
            height: maxY - minY
        )
    }

    /// The axis-aligned box around `rect` after `transform` (pivot — the center of `frame`,
    /// ADR 0010). Identity is the common case and returns `rect` untouched. Shared with the
    /// visible-area computation of A03 (D46) — one transform math, not two.
    static func boundingBox(
        of rect: LayoutFrame,
        transformedBy transform: LayoutTransform,
        in frame: LayoutFrame
    ) -> LayoutFrame {
        guard transform != .identity else { return rect }

        let corners = [
            LayoutPoint(x: rect.origin.x, y: rect.origin.y),
            LayoutPoint(x: rect.origin.x + rect.width, y: rect.origin.y),
            LayoutPoint(x: rect.origin.x, y: rect.origin.y + rect.height),
            LayoutPoint(x: rect.origin.x + rect.width, y: rect.origin.y + rect.height),
        ].map { transform.applying($0, in: frame) }
        var minX = corners[0].x
        var maxX = corners[0].x
        var minY = corners[0].y
        var maxY = corners[0].y
        for corner in corners.dropFirst() {
            minX = min(minX, corner.x)
            maxX = max(maxX, corner.x)
            minY = min(minY, corner.y)
            maxY = max(maxY, corner.y)
        }

        return LayoutFrame(
            origin: LayoutPoint(x: minX, y: minY),
            width: maxX - minX,
            height: maxY - minY
        )
    }
}
