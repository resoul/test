import Foundation

/// Prepares snapshots for one `MaterializationWindow` on a worker and commits them on the
/// MainActor (R11, ADR 0030). At most one preparation runs and at most one snapshot waits: a
/// newer snapshot replaces the waiting one (latest-value, D14), so pending work is bounded.
/// A result rejected at commit — another commit, a resize or an environment change happened
/// meanwhile — is prepared again from the latest committed state; nothing is applied partially.
///
/// The anchor is captured at commit time, so viewport movement during preparation (drag,
/// deceleration) is taken into account.
///
/// Ownership: owned by the container; retains the window. Isolation: MainActor; preparation
/// receives only Sendable values. Errors: none — rejections retry. Cancellation: `detach()`
/// cancels the running preparation and keeps its snapshot for `attach()`; `deinit` cancels it.
@MainActor
public final class CollectionUpdateQueue<Provider: ItemProvider> {
    /// Identity type of the items.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias ItemID = Provider.ItemID

    /// Model type of the items.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Item = Provider.Item

    /// The window commits go to.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let window: MaterializationWindow<Provider>

    /// Called after every successful commit with the adjustment it produced.
    ///
    /// Ownership: retained; capture the container weakly. Isolation: MainActor. Errors: none.
    /// Cancellation: assign `nil`.
    public var onCommit: (@MainActor (CollectionAdjustment<ItemID>) -> Void)?

    /// Snapshots replaced while waiting.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var supersededCount = 0

    /// Prepared results rejected at commit and prepared again.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var rejectedCount = 0

    /// Successful commits.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var committedCount = 0

    /// Runs between preparation and commit — a test hook for changes that race the worker.
    var beforeCommit: (@MainActor () -> Void)?

    private var pending: CollectionSnapshot<ItemID, Item>?
    private var worker: Task<Void, Never>?
    private var isAttached = true

    /// Creates a queue for `window`.
    ///
    /// Ownership: retains `window`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(window: MaterializationWindow<Provider>) {
        self.window = window
    }

    deinit {
        worker?.cancel()
    }

    /// Whether a snapshot waits or is being prepared.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var hasWork: Bool { pending != nil || worker != nil }

    /// Submits a snapshot; it replaces any snapshot still waiting.
    ///
    /// Ownership: takes ownership of `snapshot`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func submit(_ snapshot: CollectionSnapshot<ItemID, Item>) {
        if pending != nil {
            supersededCount += 1
        }
        pending = snapshot
        startIfIdle()
    }

    /// Stops preparing and committing (the container left the host). The snapshot being
    /// prepared is kept unless a newer one waits.
    ///
    /// Ownership: cancels the running preparation. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation point.
    public func detach() {
        isAttached = false
        worker?.cancel()
    }

    /// Resumes after `detach()`, preparing the waiting snapshot against the current state.
    ///
    /// Ownership: may start one preparation. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func attach() {
        isAttached = true
        startIfIdle()
    }

    /// Waits until no preparation runs — for tests.
    func drain() async {
        while let worker {
            await worker.value
        }
    }

    private func startIfIdle() {
        guard isAttached, worker == nil, let next = pending else { return }

        pending = nil
        let input = window.preparationInput(for: next)
        let correlation = window.correlation
        Log.on(
            .schedule,
            "collection-prepare",
            host: correlation.host,
            generation: correlation.generation,
            node: window.content.id,
            "dataKey=\(next.dataKey) dataRevision=\(next.revision) items=\(next.count)"
        )
        worker = Task { @MainActor [weak self] in
            let preparation = Task.detached(priority: .userInitiated) {
                PreparedCollection.prepare(input)
            }
            let prepared = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            self?.finish(prepared, for: next)
        }
    }

    private func finish(
        _ prepared: PreparedCollection<ItemID, Item>?,
        for snapshot: CollectionSnapshot<ItemID, Item>
    ) {
        worker = nil
        guard isAttached, !Task.isCancelled, let prepared else {
            keepIfNewest(snapshot)
            log("collection-prepare-cancelled", snapshot)
            return
        }

        beforeCommit?()
        guard isAttached else {
            keepIfNewest(snapshot)
            return
        }

        switch window.commit(prepared) {
        case .success(let adjustment):
            committedCount += 1
            onCommit?(adjustment)
        case .failure(.disposed):
            pending = nil
            return
        case .failure(let reason):
            rejectedCount += 1
            keepIfNewest(snapshot)
            log("collection-prepare-retry", snapshot, "reason=\(reason)")
        }
        startIfIdle()
    }

    private func keepIfNewest(_ snapshot: CollectionSnapshot<ItemID, Item>) {
        if pending == nil {
            pending = snapshot
        }
    }

    private func log(
        _ event: String,
        _ snapshot: CollectionSnapshot<ItemID, Item>,
        _ details: String = ""
    ) {
        let correlation = window.correlation
        Log.on(
            .schedule,
            event,
            host: correlation.host,
            generation: correlation.generation,
            node: window.content.id,
            "dataKey=\(snapshot.dataKey) dataRevision=\(snapshot.revision) \(details)"
        )
    }
}
