/// A kind of work a layout pass can trace.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LayoutTraceArea: Sendable, Hashable, CaseIterable {
    /// Size requests: a node measured under some space, computed or from the cache.
    case measure
    /// Final frames.
    case place
}

/// Which work of a pass to record, and for which nodes. The events come back in the result
/// rather than going to a shared recorder: the pass runs on any thread, and a value it
/// returns needs no synchronization.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LayoutTraceRequest: Sendable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var areas: Set<LayoutTraceArea>

    /// The nodes to trace; `nil` traces every node.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var ids: Set<LayoutID>?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        areas: Set<LayoutTraceArea> = Set(LayoutTraceArea.allCases),
        ids: Set<LayoutID>? = nil
    ) {
        self.areas = areas
        self.ids = ids
    }

    func includes(_ area: LayoutTraceArea, _ id: LayoutID) -> Bool {
        areas.contains(area) && ids.map { $0.contains(id) } != false
    }
}

/// One thing a pass did for a node.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LayoutTraceEvent: Sendable, Hashable {
    /// The node was measured: `width` and `height` are the space it was measured under — a
    /// size already fixed by its parent shows as definite. `cached` answers came from an
    /// earlier request of the same pass.
    case measured(
        LayoutID,
        width: AvailableSpace,
        height: AvailableSpace,
        size: LayoutSize,
        cached: Bool
    )
    /// The node's final frame, in the root's coordinate space.
    case placed(LayoutID, frame: LayoutRect)

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var id: LayoutID {
        switch self {
        case let .measured(id, _, _, _, _), let .placed(id, _): id
        }
    }
}
