import Foundation

/// Immutable picture of one committed tree for focus and assistive technology (A03, D35/D36):
/// the geometry and topology of a `HitTestSnapshot` — the last commit, exactly what is on
/// screen — joined with each committed node's focus/accessibility metadata, enabled state and
/// the host-space box of its visible area (D46).
///
/// Two ways to get one: at a geometry commit, from the fresh `HitTestSnapshot` and the live
/// tree; and metadata-only, from the *same* `HitTestSnapshot` again when only `Node.focus`,
/// `Node.accessibility` or `ControlNode.isEnabled` changed since (D41) — no layout pass, no
/// new frames. In both cases only committed identities are published: a node added to the
/// live tree after the commit has no frame and stays out until the next commit; a node
/// removed live but still committed keeps the metadata it had when last published, since the
/// screen still shows it. Live guards (mount, disposed, enabled) run before any action, not
/// here.
///
/// `traversalIndex` is the committed pre-order position — the tie-break every focus search
/// uses (D38), so the order candidates are examined in never depends on dictionary order or
/// on when a `NodeID` was allocated (defect #33).
///
/// Ownership: a plain value; holds no `Node`, layer or closure. Isolation: none — Sendable.
/// Errors: none. Cancellation: not applicable.
public struct SemanticSnapshot: Sendable {
    /// One committed node with everything focus and accessibility need to know about it.
    ///
    /// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct Record: Sendable, Hashable {
        /// The node this record was taken from.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let id: NodeID

        /// Parent at commit time; `nil` for the root.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let parent: NodeID?

        /// Committed children in `subnodes` order.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let children: [NodeID]

        /// Position in the committed pre-order — 0 for the root.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let traversalIndex: Int

        /// Committed frame, as `HitTestSnapshot.Record.frame`.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let frame: LayoutFrame

        /// Host-space box of the visible area (`HitTestSnapshot.visibleBounds(of:)`), or `nil`
        /// when nothing of this node is on screen — then it is neither a focus candidate nor
        /// an accessibility element with a frame (D37/D46).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let visibleBounds: LayoutFrame?

        /// `Node.focus` as published.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let focus: FocusProperties

        /// `Node.accessibility` as published.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let accessibility: AccessibilityProperties

        /// `ControlNode.isEnabled` as published; `true` for a plain node (D41).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let isEnabled: Bool

        /// Whether the node has a default activation — it is a `ControlNode` (D43).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let isActivatable: Bool

        /// Implicit `Arrangement` wrapper — transparent to both trees (D19/D42).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let isArrangementWrapper: Bool

        /// Whether this node can hold focus in this commit, before scope membership (D37):
        /// focusable, visible, enabled, not a wrapper.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var isFocusCandidate: Bool {
            focus.isFocusable && visibleBounds != nil && isEnabled && !isArrangementWrapper
        }
    }

    /// The metadata read from one live node — the part of a record that a metadata-only
    /// publish refreshes.
    struct Metadata: Sendable, Hashable {
        let focus: FocusProperties
        let accessibility: AccessibilityProperties
        let isEnabled: Bool
        let isActivatable: Bool
    }

    /// Identity of the committed root.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let root: NodeID

    /// The bridge mount this snapshot belongs to (D21/D36).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let mountEpoch: UInt64

    /// The coordinator generation of the commit the geometry comes from (D36) — unchanged by
    /// a metadata-only publish.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let geometryGeneration: UInt64

    /// The host's semantic publish counter this snapshot was published under (D36) — advances
    /// on every publish, geometry or metadata-only.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let revision: UInt64

    /// Host bounds of the commit, the space of every frame and visible box.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bounds: LayoutFrame

    /// Every committed identity in pre-order.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let order: [NodeID]

    private let records: [NodeID: Record]

    /// Number of committed nodes.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var count: Int { records.count }

    /// The record for one committed node, or `nil` if it was not part of this commit.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func record(for identity: NodeID) -> Record? { records[identity] }

    /// Whether `identity` is `ancestor` or sits under it in the committed tree — scope
    /// membership (D40).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func isDescendantOrSelf(_ identity: NodeID, of ancestor: NodeID) -> Bool {
        var current: NodeID? = identity
        while let step = current {
            if step == ancestor { return true }
            current = records[step]?.parent
        }
        return false
    }

    /// The focus candidates of `scope` (the whole tree when `nil`), in committed pre-order —
    /// the sequence Tab walks (D38).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: an unknown scope yields no
    /// candidates. Cancellation: not applicable.
    public func focusCandidates(scope: NodeID?) -> [NodeID] {
        let base = scope ?? root
        guard let scopeRecord = records[base] else { return [] }

        var result: [NodeID] = []
        var stack: [NodeID] = [scopeRecord.id]
        while let next = stack.popLast() {
            guard let record = records[next] else { continue }

            if record.isFocusCandidate { result.append(next) }
            stack.append(contentsOf: record.children.reversed())
        }
        return result
    }

    /// Captures the metadata of every committed node from the live tree under `root` and
    /// joins it with `geometry` (A03). `previous`, when given and of the same mount, supplies
    /// the metadata of a committed node that is no longer reachable live — a node removed
    /// between commits — so the published tree keeps describing what is on screen.
    ///
    /// Ownership: borrows `root` for the call; retains nothing. Isolation: MainActor — reads
    /// live metadata, which is why it runs at the commit/publish point. Errors: a live node
    /// with no committed record is skipped; a committed record with no live node and no
    /// previous record gets default metadata. Cancellation: not applicable.
    @MainActor
    public init(
        geometry: HitTestSnapshot,
        root: Node,
        geometryGeneration: UInt64,
        revision: UInt64,
        previous: SemanticSnapshot? = nil
    ) {
        var live: [NodeID: Metadata] = [:]
        Self.collectMetadata(root, into: &live)
        let fallback = previous?.mountEpoch == geometry.mountEpoch ? previous : nil
        self.init(
            geometry: geometry,
            geometryGeneration: geometryGeneration,
            revision: revision,
            metadata: { id in
                if let found = live[id] { return found }
                guard let old = fallback?.record(for: id) else { return nil }

                return Metadata(
                    focus: old.focus,
                    accessibility: old.accessibility,
                    isEnabled: old.isEnabled,
                    isActivatable: old.isActivatable
                )
            }
        )
    }

    init(
        geometry: HitTestSnapshot,
        geometryGeneration: UInt64,
        revision: UInt64,
        metadata: (NodeID) -> Metadata?
    ) {
        root = geometry.root
        mountEpoch = geometry.mountEpoch
        self.geometryGeneration = geometryGeneration
        self.revision = revision
        bounds = geometry.bounds

        var order: [NodeID] = []
        var records: [NodeID: Record] = [:]
        var stack: [NodeID] = [geometry.root]
        while let next = stack.popLast() {
            guard let record = geometry.record(for: next) else { continue }

            let meta =
                metadata(next)
                ?? Metadata(
                    focus: FocusProperties(),
                    accessibility: AccessibilityProperties(),
                    isEnabled: true,
                    isActivatable: false
                )
            records[next] = Record(
                id: next,
                parent: record.parent,
                children: record.children,
                traversalIndex: order.count,
                frame: record.frame,
                visibleBounds: geometry.visibleBounds(of: next),
                focus: meta.focus,
                accessibility: meta.accessibility,
                isEnabled: meta.isEnabled,
                isActivatable: meta.isActivatable,
                isArrangementWrapper: record.isArrangementWrapper
            )
            order.append(next)
            stack.append(contentsOf: record.children.reversed())
        }
        self.order = order
        self.records = records
    }

    /// The live node for a committed identity, if its committed route still describes the
    /// tree under `root` and the node is not disposed (D36 live guard) — what an action must
    /// resolve through before touching a `Node`.
    ///
    /// Ownership: returns a borrowed reference; do not retain it past the call. Isolation:
    /// MainActor. Errors: `nil` for a stale identity, another root, a broken route or a
    /// disposed node. Cancellation: not applicable.
    @MainActor
    package func liveNode(for identity: NodeID, under root: Node) -> Node? {
        guard root.id == self.root, let route = route(to: identity),
            let live = EventDispatcher.resolve(route, under: root), let node = live.last,
            !node.isDisposed
        else { return nil }

        return node
    }

    /// Whether every record of `other` equals the corresponding one here — the no-op test of
    /// a metadata-only publish (D47): equal snapshots are not republished.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func hasSameContent(as other: SemanticSnapshot) -> Bool {
        root == other.root && mountEpoch == other.mountEpoch && bounds == other.bounds
            && order == other.order && records == other.records
    }

    /// Iterative on purpose: a deep tree must not turn a publish into unbounded MainActor
    /// recursion (A12).
    @MainActor
    private static func collectMetadata(_ root: Node, into live: inout [NodeID: Metadata]) {
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            live[node.id] = Metadata(
                focus: node.focus,
                accessibility: node.accessibility,
                isEnabled: node.isEnabledForSemantics,
                isActivatable: node.isActivatable
            )
            stack.append(contentsOf: node.subnodes.reversed())
        }
    }
}
