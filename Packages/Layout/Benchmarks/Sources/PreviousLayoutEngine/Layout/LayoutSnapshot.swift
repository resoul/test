/// Fixed content-measurement facts a node reports independent of layout, or a `measurer`
/// (D49) the solver calls back into at the actual constraints it resolves during measurement.
///
/// Without a `measurer`, `intrinsic`/`firstBaseline` are exactly what they were before T03:
/// a fixed value from `Node.layoutContentMetrics`, not recomputed per constraint. `TextNode`
/// (T04) is the first real `measurer` user — CoreText wrapping depends on the width the
/// solver actually resolved, not the width available when the snapshot was captured.
///
/// Ownership: the value is immutable and owned by its caller; `measurer`, when present, is
/// borrowed for the duration of one solve, never retained past it. Isolation: none. Errors:
/// invalid `firstBaseline` values normalize; `nil` means "no baseline", not zero. Cancellation:
/// not applicable — `measurer.measure(_:context:)` carries its own cancellation contract.
public struct LayoutContentMetrics: Sendable {
    /// Fixed intrinsic size, independent of any constraint. Ignored by the solver for a leaf
    /// that carries a `measurer` — that leaf's size instead comes from calling it (D49).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let intrinsic: MeasuredSize

    /// Distance from the top of `intrinsic` to the first baseline, or `nil` when this node has
    /// no baseline to align to. Ignored by the solver for a leaf that carries a `measurer`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let firstBaseline: Double?

    /// A Sendable measurer the solver calls at each constraint it actually measures this leaf
    /// under (D49), or `nil` for a node whose content is a fixed size regardless of width —
    /// every node before T03, and every node after it that has no live content to measure.
    ///
    /// Ownership: borrowed by the solver for one call at a time; not retained past the solve
    /// that reads this snapshot. Isolation: none. Errors: none. Cancellation: not applicable.
    public let measurer: (any ContentMeasurer)?

    /// Creates content metrics, normalizing a supplied baseline.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: a
    /// non-finite or negative `firstBaseline` becomes zero; omitting it stays `nil`.
    /// Cancellation: not applicable.
    public init(
        intrinsic: MeasuredSize = MeasuredSize(width: 0, height: 0),
        firstBaseline: Double? = nil,
        measurer: (any ContentMeasurer)? = nil
    ) {
        self.intrinsic = intrinsic
        self.firstBaseline = firstBaseline.map { $0.isFinite ? max(0, $0) : 0 }
        self.measurer = measurer
    }
}

extension LayoutContentMetrics: Hashable {
    /// Equal `intrinsic`/`firstBaseline` and, for `measurer`, equal `(identity, revision)` —
    /// not structural equality of the measurer itself, which is neither `Equatable` nor
    /// meaningfully comparable that way (ADR 0014). Two measurers with equal `(identity,
    /// revision)` are contractually required (D49) to produce equal measurements, which is
    /// the property this cache key — and this equality — actually depends on.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.intrinsic == rhs.intrinsic
            && lhs.firstBaseline == rhs.firstBaseline
            && lhs.measurer?.identity == rhs.measurer?.identity
            && lhs.measurer?.revision == rhs.measurer?.revision
    }

    /// Hashes the same fields `==` compares — `measurer`'s `identity`/`revision`, not the
    /// measurer value itself.
    ///
    /// Ownership: not applicable. Isolation: none. Errors: none. Cancellation: not applicable.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(intrinsic)
        hasher.combine(firstBaseline)
        hasher.combine(measurer?.identity)
        hasher.combine(measurer?.revision)
    }
}

/// Immutable, Sendable capture of one node's subtree for a layout pass, retaining no live
/// `Node` or platform object (C06).
///
/// Every descendant's `style`/`content` here reflects that descendant's *own* resolved
/// constraint, not the ancestor's original one — the recursive builder narrows the constraint
/// at each level from that level's own explicit width/height before recursing (fixing a Weave
/// bug, §3.3, where every level forwarded the same root-level constraint straight through).
/// This narrowing is still not a promise of final size: grow/shrink/wrap and sibling
/// distribution are the solver's job (C12), not the snapshot's (F03).
///
/// Ownership: the snapshot owns its copied style and child snapshots. Isolation: none —
/// Sendable so it can be handed to background solver work. Errors: none. Cancellation: the
/// caller owns whatever background work consumes this snapshot.
public struct LayoutInputSnapshot: Sendable, Hashable {
    /// The node this snapshot was captured from.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let identity: NodeID

    /// This node's style as it will be measured — includes safe-area insets folded into
    /// `padding` when this node is a boundary (or the root), on top of (not replacing) its own
    /// stored padding.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let style: LayoutStyle

    /// Fixed content-measurement facts for this node under its own narrowed constraint.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let content: LayoutContentMetrics

    /// Snapshots of this node's own children, each narrowed from this node's resolved
    /// constraint rather than the constraint this node itself received.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let children: [LayoutInputSnapshot]

    /// Resolved layout direction from this node's environment at capture time.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let direction: LayoutDirection

    /// This node's environment scope revision at capture time (D02/C10) — not yet a distinct
    /// type from `contentRevision`; see docs/decisions.md for the open follow-up.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let environmentRevision: UInt64

    /// This node's own structure/geometry revision at capture time.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let contentRevision: UInt64

    /// Creates a snapshot node without retaining any live `Node` or platform object.
    ///
    /// Ownership: all values are copied into the returned snapshot. Isolation: none. Errors:
    /// none. Cancellation: not applicable.
    public init(
        identity: NodeID,
        style: LayoutStyle = LayoutStyle(),
        content: LayoutContentMetrics = LayoutContentMetrics(),
        children: [LayoutInputSnapshot] = [],
        direction: LayoutDirection = .leftToRight,
        environmentRevision: UInt64 = 0,
        contentRevision: UInt64 = 0
    ) {
        self.identity = identity
        self.style = style
        self.content = content
        self.children = children
        self.direction = direction
        self.environmentRevision = environmentRevision
        self.contentRevision = contentRevision
    }
}
