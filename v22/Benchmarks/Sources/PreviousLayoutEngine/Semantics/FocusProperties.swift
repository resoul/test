import Foundation

/// Direction of a focus movement request (A03/A04, D38). `.next`/`.previous` are sequential
/// — Tab and Shift-Tab over the committed pre-order; the four others are physical directions
/// in host space, unaffected by layout direction (RTL changes geometry, not what "left"
/// means). Ported from Weave's `FocusDirection` (`Focus.swift`) with `forward`/`backward`
/// renamed: those were nearest-neighbour searches there (defect #33), these are tree order.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FocusDirection: Sendable, Hashable, CaseIterable {
    case up
    case down
    case left
    case right
    case next
    case previous
}

/// A node's focus participation (A03, D37/D38): whether it can hold keyboard/remote focus,
/// its priority when an initial or fallback focus is chosen, and explicit next-focus
/// overrides per direction. Stored on `Node.focus`; assigning an equal value is a no-op.
/// Ported in spirit from Weave's `FocusableSpec`.
///
/// `priority` never enters the directional score (defect #33 in the source subtracted it from
/// the distance): it only ranks candidates when there is no current focus, or when the
/// current one disappears. `preferredNext` names a committed node; an unknown, disposed,
/// self, non-eligible or out-of-scope target is ignored and the ordinary search runs.
///
/// Ownership: a plain value; holds identities only. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FocusProperties: Sendable, Hashable {
    /// Whether this node can receive focus at all. `false` for a plain `Node`; `ControlNode`
    /// sets it `true` by default.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isFocusable: Bool

    /// Ranking for initial/fallback selection — higher first, ties by committed traversal
    /// index (D38). Not used by directional or sequential moves.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var priority: Int

    /// Explicit next-focus targets by direction, consulted before the geometric search.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var preferredNext: [FocusDirection: NodeID]

    /// Creates focus properties.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        isFocusable: Bool = false,
        priority: Int = 0,
        preferredNext: [FocusDirection: NodeID] = [:]
    ) {
        self.isFocusable = isFocusable
        self.priority = priority
        self.preferredNext = preferredNext
    }
}
