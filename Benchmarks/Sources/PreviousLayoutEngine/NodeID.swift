/// Runtime identity of a single tree node.
///
/// The value is opaque: the underlying integer is not part of the public API, preventing
/// it from being confused with revisions or used as a domain model key. For diagnostic
/// output, use `description`.
///
/// This is a **runtime** identity. It is not persisted across launches, does not match
/// across distinct runs of the same scenario, and is not a domain model key.
///
/// Ownership: the value is copied with no owner. Isolation: none — the value freely crosses
/// isolation boundaries; instances are issued by `NodeIDAllocator` on the MainActor.
/// Errors: none. Cancellation: not applicable.
public struct NodeID: Sendable, Hashable {
    private let rawValue: UInt64

    /// Creates an identity from an integer. Available only within the module and tests:
    /// externally, identities are issued exclusively by the allocator.
    ///
    /// Ownership: the value is copied. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

extension NodeID: CustomStringConvertible {
    /// Compact representation for diagnostics: `#42`.
    ///
    /// The format is stable across runs only with respect to node creation order and is
    /// intended for reading logs, not for cross-run comparison.
    ///
    /// Ownership: returns a new string. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public var description: String { "#\(rawValue)" }
}

/// Source of unique identities for live nodes within the process.
///
/// Uniqueness is guaranteed across **all live trees in the process**, including trees
/// of different hosts: the counter is singular and belongs to the MainActor.
///
/// Ownership: the allocator owns the counter. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
enum NodeIDAllocator {
    private static var lastIssued: UInt64 = 0

    /// Issues the next unused identity.
    ///
    /// Ownership: the returned value belongs to the caller. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    static func allocate() -> NodeID {
        lastIssued += 1
        return NodeID(rawValue: lastIssued)
    }
}
