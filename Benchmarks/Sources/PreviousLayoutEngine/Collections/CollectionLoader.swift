import Foundation

/// Why a load hook runs (P6.7).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionLoadReason: Sendable, Hashable {
    /// First data for the data key, on first activation.
    case initial
    /// Replace current data; resets pagination.
    case refresh
    /// Next page after the last accepted snapshot.
    case loadMore
    /// Repeat of a failed operation; `of` names which.
    indirect case retry(of: CollectionLoadReason)
}

/// Everything a load hook needs to issue and later validate one request (P6.7, P6.12). The
/// context carries data, not nodes: it is safe to pass into a service.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionLoadContext: Sendable, Hashable {
    /// Why the request runs.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let reason: CollectionLoadReason

    /// Data key the request belongs to.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let dataKey: String

    /// Revision of the snapshot the request continues from.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let baseRevision: UInt64

    /// Page size requested by the container's pagination policy, if any.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let pageSize: Int?

    /// Loader-unique request identity, used for `isCurrent` and diagnostics.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let requestID: UInt64

    /// Creates a context — for tests and model-owned retries.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        reason: CollectionLoadReason,
        dataKey: String,
        baseRevision: UInt64,
        pageSize: Int?,
        requestID: UInt64
    ) {
        self.reason = reason
        self.dataKey = dataKey
        self.baseRevision = baseRevision
        self.pageSize = pageSize
        self.requestID = requestID
    }
}

/// What a load hook reports after it has published its data (or failed). The data itself
/// always travels through the collection's `StateSubject`, never through this value.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionLoadResult: Sendable, Hashable {
    /// The model published the resulting snapshot before returning.
    case completed
    /// The request failed; no automatic retry follows.
    case failed(CollectionLoadError)
}

/// A load hook: an async MainActor effect whose task the loader owns and cancels.
///
/// Ownership: retained by `CollectionLoader`. Isolation: MainActor. Errors: reported through
/// `CollectionLoadResult.failed`. Cancellation: the loader cancels the task; the hook checks
/// `isCurrent` after each `await`.
public typealias CollectionLoadHook =
    @MainActor (CollectionLoadContext) async -> CollectionLoadResult

/// The single owner of a collection's view-owned load effects (R10, P6.7, ADR 0030). It turns
/// activation, pagination demand, refresh and retry into at most one task per kind, cancels
/// them on deactivation or data-key change, and ignores results of requests that are no longer
/// current. Model-owned producers may outlive it; only the hook's task is view-owned.
///
/// Rules: initial runs on activation while the snapshot is `.initial` and no initial is in
/// flight — remount of loaded data does not request again. Refresh supersedes an in-flight
/// page request. Next page runs only on a `PaginationGate` `.request`. Retry repeats the
/// failed operation's reason, using `onRetry` when set, otherwise the original hook.
///
/// Ownership: owned by the container; retains hooks, which must capture the model weakly or
/// be model-owned. Isolation: MainActor. Errors: failures are recorded, never thrown.
/// Cancellation: `deactivate()`, a data key change and `deinit` cancel every task.
@MainActor
public final class CollectionLoader<ItemID: Hashable & Sendable, Item: Sendable & Equatable> {
    /// Initial-load hook.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: its task is
    /// owned by this loader.
    public var onLoad: CollectionLoadHook?

    /// Refresh hook.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: its task is
    /// owned by this loader.
    public var onRefresh: CollectionLoadHook?

    /// Next-page hook.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: its task is
    /// owned by this loader.
    public var onLoadMore: CollectionLoadHook?

    /// Retry hook; when `nil`, retry calls the failed operation's own hook.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: its task is
    /// owned by this loader.
    public var onRetry: CollectionLoadHook?

    /// Pagination state evaluated by `evaluateDemand(in:)`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var gate: PaginationGate

    /// Diagnostic correlation (P6.12).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var correlation = CollectionCorrelation()

    /// The failed operation retry would repeat, if any.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var failedReason: CollectionLoadReason?

    private struct Running {
        let context: CollectionLoadContext
        let task: Task<Void, Never>
    }

    private enum Slot: Hashable {
        case initial
        case refresh
        case page
    }

    private var running: [Slot: Running] = [:]
    private let source: StateSubject<CollectionSnapshot<ItemID, Item>>
    private var dataKey: String
    private var nextRequestID: UInt64 = 0
    private var isActive = false

    /// Creates an inactive loader over `source`. The loader reads `source.current`
    /// synchronously — a hook's model publishes before returning, so completion sees the new
    /// snapshot even while the mounted delivery (D14) is still deferred.
    ///
    /// Ownership: retains `source`; the container owns the loader. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(
        source: StateSubject<CollectionSnapshot<ItemID, Item>>,
        pagination: PaginationPolicy = PaginationPolicy()
    ) {
        self.source = source
        self.dataKey = source.current.dataKey
        self.gate = PaginationGate(policy: pagination)
    }

    private var snapshot: CollectionSnapshot<ItemID, Item> { source.current }

    deinit {
        for entry in running.values {
            entry.task.cancel()
        }
    }

    /// Number of hook tasks in flight.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var runningCount: Int { running.count }

    /// Whether `context` still belongs to a running, non-superseded request. A model checks
    /// this after each `await` before merging data.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func isCurrent(_ context: CollectionLoadContext) -> Bool {
        running.values.contains { $0.context.requestID == context.requestID }
    }

    /// Starts delivering: requests initial data when the snapshot still is `.initial`.
    ///
    /// Ownership: may start one task. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func activate() {
        isActive = true
        startInitialIfNeeded()
    }

    /// Stops delivering: cancels every view-owned task. A cancelled initial may run again on
    /// the next activation.
    ///
    /// Ownership: releases all tasks. Isolation: MainActor. Errors: none. Cancellation: this
    /// is the cancellation point.
    public func deactivate() {
        isActive = false
        cancelAll(reason: "deactivate")
    }

    /// Called by the container when it applies a delivered snapshot. A new data key cancels
    /// every task of the old key and, while active, starts its initial load.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: cancels superseded
    /// tasks.
    public func sourceDidChange() {
        guard snapshot.dataKey != dataKey else { return }

        dataKey = snapshot.dataKey
        cancelAll(reason: "data-key")
        failedReason = nil
        gate = PaginationGate(policy: gate.policy)
        if isActive {
            startInitialIfNeeded()
        }
    }

    /// Evaluates pagination demand in `window` and starts `onLoadMore` on `.request`.
    ///
    /// Ownership: may start one task. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @discardableResult
    public func evaluateDemand<Provider: ItemProvider>(
        in window: MaterializationWindow<Provider>
    ) -> PaginationDecision {
        guard isActive, running[.refresh] == nil, running[.initial] == nil else {
            return .duplicate
        }
        // An empty list is always "near the end": no next page before the first data (#85).
        guard snapshot.loadState.phase == .loaded else { return .notNeeded }

        let decision = window.evaluatePagination(&gate)
        if case .request = decision {
            start(.loadMore, slot: .page, hook: onLoadMore)
        }
        return decision
    }

    /// Notes user-driven scrolling: re-allows automatic pages and clears a no-progress stall.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func userDidScroll() {
        gate.userDidScroll()
    }

    /// Starts a refresh unless one is running; an in-flight page request is cancelled and its
    /// late result ignored.
    ///
    /// Ownership: may start one task. Isolation: MainActor. Errors: none. Cancellation:
    /// cancels the page task.
    public func refresh() {
        guard isActive, running[.refresh] == nil else { return }

        cancel(.page, reason: "refresh")
        gate = PaginationGate(policy: gate.policy)
        start(.refresh, slot: .refresh, hook: onRefresh)
    }

    /// Repeats the failed operation, if any.
    ///
    /// Ownership: may start one task. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func retry() {
        guard isActive, let failed = failedReason else { return }

        failedReason = nil
        let slot = slot(for: failed)
        guard running[slot] == nil else { return }

        if failed == .loadMore {
            gate.retry()
            // Re-arm the gate for the same revision; the page task records it in flight.
            gate.markRetryRequest(for: snapshot)
        }
        start(.retry(of: failed), slot: slot, hook: onRetry ?? hook(for: failed))
    }

    private func startInitialIfNeeded() {
        guard snapshot.loadState.phase == .initial, running[.initial] == nil else { return }

        start(.initial, slot: .initial, hook: onLoad)
    }

    private func start(_ reason: CollectionLoadReason, slot: Slot, hook: CollectionLoadHook?) {
        guard let hook else {
            if slot == .page { gate.cancelInFlight() }
            return
        }

        nextRequestID &+= 1
        let context = CollectionLoadContext(
            reason: reason,
            dataKey: snapshot.dataKey,
            baseRevision: snapshot.revision,
            pageSize: gate.policy.pageSize,
            requestID: nextRequestID
        )
        let task = Task { @MainActor [weak self] in
            let result = await hook(context)
            self?.finish(context, slot: slot, result: result)
        }
        running[slot] = Running(context: context, task: task)
        log("load-start", context, "")
    }

    private func finish(_ context: CollectionLoadContext, slot: Slot, result: CollectionLoadResult)
    {
        guard running[slot]?.context.requestID == context.requestID,
            context.dataKey == snapshot.dataKey
        else {
            log("load-stale", context, "ignored=true")
            return
        }

        running[slot] = nil
        switch result {
        case .completed:
            if slot == .page {
                gate.complete(with: snapshot)
            }
            log("load-success", context, "dataRevision=\(snapshot.revision)")
        case .failed(let error):
            if slot == .page {
                gate.fail()
            }
            failedReason = baseReason(context.reason)
            log("load-error", context, "message=\(error.message)")
        }
    }

    private func cancel(_ slot: Slot, reason: String) {
        guard let entry = running.removeValue(forKey: slot) else { return }

        entry.task.cancel()
        if slot == .page {
            gate.cancelInFlight()
        }
        log("load-cancel", entry.context, "cause=\(reason)")
    }

    private func cancelAll(reason: String) {
        for slot in Array(running.keys) {
            cancel(slot, reason: reason)
        }
    }

    private func slot(for reason: CollectionLoadReason) -> Slot {
        switch baseReason(reason) {
        case .initial: return .initial
        case .refresh: return .refresh
        default: return .page
        }
    }

    private func hook(for reason: CollectionLoadReason) -> CollectionLoadHook? {
        switch baseReason(reason) {
        case .initial: return onLoad
        case .refresh: return onRefresh
        default: return onLoadMore
        }
    }

    private func baseReason(_ reason: CollectionLoadReason) -> CollectionLoadReason {
        if case .retry(let original) = reason {
            return baseReason(original)
        }
        return reason
    }

    private func log(_ event: String, _ context: CollectionLoadContext, _ details: String) {
        Log.on(
            .host,
            event,
            host: correlation.host,
            generation: correlation.generation,
            "reason=\(context.reason) requestID=\(context.requestID) dataKey=\(context.dataKey) "
                + "baseRevision=\(context.baseRevision) \(details)"
        )
    }
}
