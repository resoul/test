import Foundation

/// When a list asks for its next page. The distance is measured after the last item that
/// shows, never from the first, so that it holds for rows of different heights and for grids.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PaginationTrigger: Sendable, Hashable {
    /// Ask when what is left of the list after the window is at most this many windows long.
    /// The default; it does not depend on how tall the rows are.
    case remainingViewportLengths(Double)
    /// Ask when at most this many items are left after the last one that shows.
    case remainingItems(Int)
}

/// How a list pages: when it asks, how much, and how far it goes on its own.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PaginationPolicy: Sendable, Hashable {
    /// How many items to ask for, passed on in ``PageRequest/pageSize``; the list does not
    /// look at it. `nil` leaves the choice to whoever loads.
    public var pageSize: Int?

    /// The distance that makes the list ask for the next page.
    public var trigger: PaginationTrigger

    /// How many pages the list asks for one after another without the person scrolling. It
    /// bounds what a list that is shorter than its window would do: ask, get a page, still be
    /// short, ask again. Scrolling starts the count over. At least 1.
    public var maximumAutomaticPages: Int

    /// - Parameters:
    ///   - trigger: Two window lengths before the end of the list by default.
    ///   - maximumAutomaticPages: Three by default.
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

/// What a list asks its loader for.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PageRequest: Sendable, Hashable {
    /// ``PaginationPolicy/pageSize``.
    public var pageSize: Int?
    /// How many items the list has now: where the page continues from.
    public var loadedCount: Int
    /// Whether the person asked again after a failure, and not the list on its own.
    public var isRetry: Bool

    public init(pageSize: Int?, loadedCount: Int, isRetry: Bool = false) {
        self.pageSize = pageSize
        self.loadedCount = loadedCount
        self.isRetry = isRetry
    }
}

/// What a list's paging is doing, for a footer that shows it.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PageLoadState: Sendable, Hashable {
    /// Nothing is being loaded: before the first page, and between pages.
    case idle
    case loading
    /// The last page failed. The list does not try again by itself; the reason is the list's
    /// `pageLoadError`, and `retryLoadingPage()` asks again.
    case failed
    /// There are no more pages.
    case endReached
}

/// Why a list did or did not ask for a page; a record for a log.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PaginationDecision: Sendable, Hashable {
    /// Ask for the next page.
    case request
    /// A page is being loaded, or one was already asked for since the items last changed.
    case duplicate
    /// The end of the list is not near enough.
    case notNeeded
    /// There are no more pages.
    case endReached
    /// The last page failed; only an explicit retry asks again.
    case awaitingRetry
    /// The last page added nothing; only scrolling or a retry asks again.
    case noProgress
    /// The list has asked for as many pages as it does without scrolling.
    case automaticLimit
}

/// Where a list's window is, as far as paging cares.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PaginationMetrics: Sendable, Hashable {
    /// How many items the list has.
    public var count: Int
    /// The index of the last item that shows; `nil` when none does.
    public var lastVisible: Int?
    /// The length of the list after the end of the window, along its axis; 0 when the window
    /// reaches the end.
    public var remainingLength: Double
    /// The length of the window along the axis.
    public var viewportLength: Double

    public init(count: Int, lastVisible: Int?, remainingLength: Double, viewportLength: Double) {
        self.count = count
        self.lastVisible = lastVisible
        self.remainingLength = remainingLength
        self.viewportLength = viewportLength
    }
}

/// The rules for when a list asks for a page, as a value that does no loading: it is told where
/// the window is, and says whether to ask; it is told how the asking ended.
///
/// It asks at most once for each version of the items — the list counts a version for every
/// assignment of its items — so a list laid out again and again at the end does not ask again
/// while a page is on its way, nor after a page that brought nothing.
///
/// Ownership: value, kept by the list. Isolation: none; used on the list's actor. Errors: none.
/// Cancellation: ``cancelInFlight()``.
public struct PaginationGate: Sendable, Hashable {
    public let policy: PaginationPolicy

    private var requestedVersion: Int?
    private var requestedCount = 0
    private var inFlight = false
    private var failed = false
    private var stalled = false
    private var automaticPages = 0

    public init(policy: PaginationPolicy = PaginationPolicy()) {
        self.policy = policy
    }

    /// Whether a page is being loaded.
    public var isRequestInFlight: Bool { inFlight }

    /// Decides whether to ask for a page now. On ``PaginationDecision/request`` the page counts
    /// as in flight, and the caller starts exactly one load for it.
    ///
    /// - Parameters:
    ///   - metrics: Where the window is.
    ///   - version: The version of the items; changes whenever they are assigned.
    ///   - reachedEnd: Whether the loader said there are no more pages.
    public mutating func evaluate(
        _ metrics: PaginationMetrics,
        version: Int,
        reachedEnd: Bool
    ) -> PaginationDecision {
        if reachedEnd { return .endReached }
        if inFlight { return .duplicate }
        if failed { return .awaitingRetry }
        if requestedVersion == version { return .duplicate }
        if stalled { return .noProgress }
        if automaticPages >= policy.maximumAutomaticPages { return .automaticLimit }
        guard triggerReached(metrics) else { return .notNeeded }

        inFlight = true
        requestedVersion = version
        requestedCount = metrics.count
        automaticPages += 1
        return .request
    }

    /// A page ended without an error. A page that left the list no longer than it was stops the
    /// list from asking again until it is scrolled or retried — unless items arrive later, which
    /// ``itemsChanged(count:)`` notices.
    public mutating func complete(count: Int) {
        guard inFlight else { return }

        inFlight = false
        failed = false
        stalled = count <= requestedCount
        if !stalled { requestedVersion = nil }
    }

    /// The items were assigned. Items that come after a page that ended without adding any end
    /// its stall: the page was late, not empty.
    public mutating func itemsChanged(count: Int) {
        if stalled, count > requestedCount { stalled = false }
    }

    /// A page failed. Nothing is asked again until ``retry()``.
    public mutating func fail() {
        inFlight = false
        failed = true
    }

    /// The load was cancelled, as when the list left the screen: the same page may be asked for
    /// again.
    public mutating func cancelInFlight() {
        guard inFlight else { return }

        inFlight = false
        requestedVersion = nil
        automaticPages = max(0, automaticPages - 1)
    }

    /// Clears a failure or a stall and counts the retry as a page in flight at once, without
    /// looking at the trigger: the person asked for it.
    public mutating func retry(count: Int, version: Int) {
        failed = false
        stalled = false
        inFlight = true
        requestedVersion = version
        requestedCount = count
    }

    /// The window was moved by the person. Starts the count of automatic pages over, and lets a
    /// list that stopped because a page brought nothing ask again.
    public mutating func userDidScroll() {
        automaticPages = 0
        if stalled {
            stalled = false
            requestedVersion = nil
        }
    }

    private func triggerReached(_ metrics: PaginationMetrics) -> Bool {
        switch policy.trigger {
        case .remainingItems(let remaining):
            let last = metrics.lastVisible ?? -1
            return metrics.count - 1 - last <= max(0, remaining)
        case .remainingViewportLengths(let lengths):
            return metrics.remainingLength <= max(0, lengths) * max(0, metrics.viewportLength)
        }
    }
}
