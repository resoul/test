/// One positioned element emitted by a layout pass, in the layout root's coordinate space.
///
/// Ownership: the placement owns its immutable frame. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutPlacement: Sendable, Hashable {
    /// The node this placement was computed for.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let identity: NodeID

    /// The node's frame, absolute in the layout root's coordinate space.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutFrame

    /// Creates a placement for a node identity.
    ///
    /// Ownership: the returned placement is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(identity: NodeID, frame: LayoutFrame) {
        self.identity = identity
        self.frame = frame
    }
}

/// Immutable output of a top-down layout pass.
///
/// Every `frame` is absolute in the layout root's coordinate space, not parent-local: the
/// solver never has to know where an ancestor sits in order to place a descendant, and the
/// renderer (C16) converts to parent-local geometry exactly once, when it applies the result
/// to native layers. A `LayoutResult` holds no `Node`, no native layer, and no callback into
/// live UI — it is a plain value produced by background solver work (D09) and read on
/// `MainActor` at commit.
///
/// `placements` is a plain, deterministic array; a private identity index (C11) is built once
/// at construction time directly from this same array, so it can never diverge from it — there
/// is no separate mutation path that could let the two disagree.
///
/// Ownership: the result owns its placements. Isolation: none — Sendable so it crosses from
/// background solver work to a `MainActor` commit. Errors: none — a malformed result (a
/// duplicated identity) is not thrown, it is surfaced as data via `duplicateIdentities`, so a
/// future coordinator can reject it *before* applying any placement, not partway through
/// (C14). Cancellation: a cancelled pass never produces a `LayoutResult` (D09); this type
/// never itself represents cancellation.
public struct LayoutResult: Sendable {
    /// Every placement emitted by the pass, in solver traversal order.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let placements: [LayoutPlacement]

    /// Identity of the root the pass was run against, for staleness checks at commit.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let treeIdentity: NodeID

    /// Identities that appear more than once in `placements`. Empty for an ordinary,
    /// well-formed pass — a non-empty set means the solver that produced this result has a
    /// bug, and a coordinator should reject the whole result via `isWellFormed` rather than
    /// commit any of it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let duplicateIdentities: Set<NodeID>

    /// The input snapshot's environment scope revision this pass was computed from (C10), for
    /// staleness checks at commit — a future coordinator (C14) compares this against the live
    /// tree's current revision before trusting this result.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let environmentRevision: UInt64

    /// The input snapshot's structure/geometry revision this pass was computed from (C09), for
    /// the same staleness check as `environmentRevision`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let contentRevision: UInt64

    /// A private index built once, directly from `placements`, at construction time — the only
    /// place this type's shape allows an index to be built, so it cannot fall out of sync with
    /// the array it indexes.
    private let index: [NodeID: Int]

    /// Creates a layout result, detecting (not rejecting) duplicate identities.
    ///
    /// A duplicate is not a thrown error: the first occurrence of a duplicated identity wins
    /// in the lookup index — never silently the last, which would hide which placement a
    /// caller actually sees — and every duplicated identity is recorded in
    /// `duplicateIdentities` for a caller to check before treating this result as usable.
    ///
    /// Ownership: the returned result is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        placements: [LayoutPlacement],
        treeIdentity: NodeID,
        environmentRevision: UInt64 = 0,
        contentRevision: UInt64 = 0
    ) {
        self.placements = placements
        self.treeIdentity = treeIdentity
        self.environmentRevision = environmentRevision
        self.contentRevision = contentRevision
        var index: [NodeID: Int] = [:]
        index.reserveCapacity(placements.count)
        var duplicates: Set<NodeID> = []
        for (offset, placement) in placements.enumerated() {
            if index[placement.identity] != nil {
                duplicates.insert(placement.identity)
                continue
            }
            index[placement.identity] = offset
        }
        self.index = index
        self.duplicateIdentities = duplicates
    }

    /// Whether this result is safe to commit: no identity was emitted more than once.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isWellFormed: Bool { duplicateIdentities.isEmpty }

    /// Returns the placement for an identity, if the pass emitted one — an indexed lookup,
    /// not a scan of `placements`. For a duplicated identity (see `duplicateIdentities`) this
    /// deterministically returns the first occurrence; a caller that cares about correctness,
    /// not just a return value, checks `isWellFormed` before trusting any lookup at all.
    ///
    /// Ownership: the returned placement is borrowed from this immutable result. Isolation:
    /// none. Errors: none; an identity absent from this result returns `nil`. Cancellation:
    /// not applicable.
    public func placement(for identity: NodeID) -> LayoutPlacement? {
        index[identity].map { placements[$0] }
    }
}

extension LayoutResult: Equatable {
    /// Compares results by their observable content — `index` is always fully derived from
    /// `placements`, so two results with equal placements always have equal indexes too.
    ///
    /// Ownership: no state is retained. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static func == (lhs: LayoutResult, rhs: LayoutResult) -> Bool {
        lhs.placements == rhs.placements && lhs.treeIdentity == rhs.treeIdentity
            && lhs.environmentRevision == rhs.environmentRevision
            && lhs.contentRevision == rhs.contentRevision
    }
}

extension LayoutResult: Hashable {
    /// Hashes the same observable content `==` compares.
    ///
    /// Ownership: no state is retained. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(placements)
        hasher.combine(treeIdentity)
        hasher.combine(environmentRevision)
        hasher.combine(contentRevision)
    }
}
