import Foundation

/// When a container asks for the next page (P6.8, ADR 0030). The distance is measured after
/// the last visible item in the loading direction, never from the first row on screen.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PaginationTrigger: Sendable, Hashable {
    /// Request when the content left after the viewport is at most this many viewport
    /// lengths — the default, correct for variable-height rows and grids.
    case remainingViewportLengths(Double)
    /// Request when at most this many items remain after the last visible one.
    case remainingItems(Int)
}

/// Pagination settings of one container. The page size belongs to the consumer's API; the
/// container only forwards it in the load context.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PaginationPolicy: Sendable, Hashable {
    /// Items the consumer asks for per page, forwarded to the load hook; `nil` lets the model
    /// decide.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var pageSize: Int?

    /// Distance rule that raises next-page demand.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var trigger: PaginationTrigger

    /// Pages requested in a row without the user scrolling — bounds the fill loop of short
    /// content.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var maximumAutomaticPages: Int

    /// Creates a policy. The default trigger is two viewport lengths (ADR 0030).
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        pageSize: Int? = nil,
        trigger: PaginationTrigger = .remainingViewportLengths(2),
        maximumAutomaticPages: Int = 3
    ) {
        self.pageSize = pageSize
        self.trigger = trigger
        self.maximumAutomaticPages = max(1, maximumAutomaticPages)
    }
}

/// Why a next-page demand was or was not raised — the `details` of a `schedule` log line.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PaginationDecision: Sendable, Hashable {
    /// Raise one request for the snapshot revision `baseRevision`.
    case request(baseRevision: UInt64)
    /// A request for this revision is already in flight or was already raised.
    case duplicate
    /// The trigger distance is not reached.
    case notNeeded
    /// The data source reported the end.
    case endReached
    /// The last page failed; only an explicit retry requests again.
    case awaitingRetry
    /// The last page added no new item; only user scrolling or retry requests again.
    case noProgress
    /// Too many automatic pages without user scrolling.
    case automaticLimit
}

/// De-duplicating state machine for next-page demand (P6.7/P6.8). It never performs I/O: it
/// tells the container whether to start the `onLoadMore` effect and records its outcome.
/// One request per snapshot revision; a new data key resets it.
///
/// Ownership: a value owned by its container. Isolation: none — a value used on the
/// container's actor. Errors: none. Cancellation: `cancelInFlight()` forgets a request whose
/// effect was cancelled so a later demand may repeat it.
public struct PaginationGate: Sendable, Hashable {
    /// The policy this gate evaluates.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let policy: PaginationPolicy

    private var dataKey: String?
    private var requestedRevision: UInt64?
    private var requestedCount = 0
    private var inFlight = false
    private var failed = false
    private var stalled = false
    private var automaticPages = 0

    /// Creates a gate for `policy`.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(policy: PaginationPolicy = PaginationPolicy()) {
        self.policy = policy
    }

    /// Whether a request is currently in flight.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isRequestInFlight: Bool { inFlight }

    /// Evaluates demand for the current snapshot and viewport. A `.request` result marks the
    /// request in flight; the caller must start exactly one effect for it.
    ///
    /// Ownership: mutates this gate. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func evaluate<ItemID, Item>(
        snapshot: CollectionSnapshot<ItemID, Item>,
        extents: ItemExtentIndex,
        visible: Range<Int>,
        viewportOffset: Double,
        viewportLength: Double
    ) -> PaginationDecision {
        adopt(snapshot)
        // A page published after its hook returned (a Flux model, delivery deferred by D14)
        // is progress too: the stall recorded at completion ends when the items arrive (#88).
        if stalled, snapshot.count > requestedCount {
            stalled = false
        }
        if snapshot.loadState.endReached { return .endReached }
        if inFlight { return .duplicate }
        if failed || snapshot.loadState.pageError != nil { return .awaitingRetry }
        if requestedRevision == snapshot.revision { return .duplicate }
        if stalled { return .noProgress }
        if automaticPages >= policy.maximumAutomaticPages { return .automaticLimit }

        guard
            triggerReached(
                count: snapshot.count,
                extents: extents,
                visible: visible,
                viewportEnd: viewportOffset + viewportLength,
                viewportLength: viewportLength
            )
        else { return .notNeeded }

        inFlight = true
        requestedRevision = snapshot.revision
        requestedCount = snapshot.count
        automaticPages += 1
        return .request(baseRevision: snapshot.revision)
    }

    /// Records a completed page: `snapshot` is the first snapshot published after it. A page
    /// that added no item stalls automatic demand until the user scrolls or retries.
    ///
    /// Ownership: mutates this gate. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func complete<ItemID, Item>(with snapshot: CollectionSnapshot<ItemID, Item>) {
        adopt(snapshot)
        guard inFlight else { return }

        inFlight = false
        failed = false
        stalled = snapshot.count <= requestedCount && !snapshot.loadState.endReached
        if snapshot.revision == requestedRevision && !stalled {
            requestedRevision = nil
        }
    }

    /// Records a failed page. No automatic retry follows.
    ///
    /// Ownership: mutates this gate. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func fail() {
        inFlight = false
        failed = true
    }

    /// Forgets an in-flight request whose effect was cancelled; the same revision may be
    /// requested again.
    ///
    /// Ownership: mutates this gate. Isolation: none. Errors: none. Cancellation: this is the
    /// cancellation record itself.
    public mutating func cancelInFlight() {
        guard inFlight else { return }

        inFlight = false
        requestedRevision = nil
        automaticPages = max(0, automaticPages - 1)
    }

    /// Clears a failure so the next evaluation may request the failed page again.
    ///
    /// Ownership: mutates this gate. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func retry() {
        failed = false
        stalled = false
        requestedRevision = nil
    }

    /// Marks a retried page request in flight for `snapshot` without re-checking the trigger:
    /// the user asked for it explicitly.
    mutating func markRetryRequest<ItemID, Item>(for snapshot: CollectionSnapshot<ItemID, Item>) {
        adopt(snapshot)
        inFlight = true
        requestedRevision = snapshot.revision
        requestedCount = snapshot.count
    }

    /// Notes user-driven scrolling: resets the automatic-page counter and a no-progress stall.
    ///
    /// Ownership: mutates this gate. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func userDidScroll() {
        automaticPages = 0
        stalled = false
    }

    private mutating func adopt<ItemID, Item>(_ snapshot: CollectionSnapshot<ItemID, Item>) {
        guard snapshot.dataKey != dataKey else { return }

        self = PaginationGate(policy: policy)
        dataKey = snapshot.dataKey
    }

    private func triggerReached(
        count: Int,
        extents: ItemExtentIndex,
        visible: Range<Int>,
        viewportEnd: Double,
        viewportLength: Double
    ) -> Bool {
        switch policy.trigger {
        case .remainingItems(let remaining):
            let lastVisible = visible.isEmpty ? -1 : visible.upperBound - 1
            return count - 1 - lastVisible <= max(0, remaining)
        case .remainingViewportLengths(let lengths):
            let remaining = extents.totalExtent - viewportEnd
            return remaining <= max(0, lengths) * max(0, viewportLength)
        }
    }
}
