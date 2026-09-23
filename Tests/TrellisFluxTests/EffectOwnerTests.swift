import Testing

@testable import TrellisFlux

/// Deterministic per-request completion, no sleep/polling: each `start()` hands back an id
/// and an awaitable that only resumes when the test explicitly `resolve(_:with:)`s that id —
/// the same discipline R01's audit used for interleavings, applied here to a fake network.
@MainActor
private final class ControllableRequests<Value: Sendable> {
    private let interruptedValue: Value
    private var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
    private var nextID = 0

    /// `interruptedValue` stands in for a request `EffectOwner` cancelled before it was ever
    /// `resolve`d: `AsyncStream.Iterator.next()` observes the *consuming* Task's own
    /// cancellation and returns `nil` right away in that case (not only when the producer
    /// calls `finish()`) — expected and harmless here, since `EffectOwner` discards a
    /// cancelled run's result regardless of what it is, but something has to be returned.
    init(interruptedValue: Value) {
        self.interruptedValue = interruptedValue
    }

    func start() -> (id: Int, wait: @Sendable () async -> Value) {
        nextID += 1
        let id = nextID
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        continuations[id] = continuation
        return (
            id,
            { [interruptedValue] in
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() ?? interruptedValue
            }
        )
    }

    func resolve(_ id: Int, with value: Value) {
        continuations[id]?.yield(value)
        continuations[id]?.finish()
        continuations[id] = nil
    }
}

private enum LoadKey: Hashable, Sendable {
    case primary
    case pagination
}

private enum LoadOutcome: Sendable, Equatable {
    case success([Int])
    case failure(String)
}

/// Polls for a condition instead of blindly yielding a fixed number of times — the parallel
/// test suite easily needs more than a few hundred turns to schedule a given `Task` under
/// full-suite contention, matching `NodeHostBridgeTests.swift`'s own `waitForBridgeCommits`.
@MainActor
private func waitUntil(
    timeout: Int = 100_000,
    _ condition: @autoclosure () -> Bool
) async {
    for _ in 0..<timeout where !condition() { await Task.yield() }
}

@Test @MainActor
func test_effectOwner_appliesTheResultOnceTheOperationCompletes() async {
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var applied: LoadOutcome?

    let (id, wait) = requests.start()
    let started = owner.run(.primary, operation: wait) { applied = $0 }
    #expect(started)
    #expect(owner.isRunning(.primary))
    #expect(applied == nil)

    requests.resolve(id, with: .success([1, 2, 3]))
    await waitUntil(applied != nil)

    #expect(applied == .success([1, 2, 3]))
    #expect(!owner.isRunning(.primary))
}

@Test @MainActor
func test_effectOwner_ignoreIfRunningRefusesADuplicateAndObservesIt() async {
    // P6.2/P6.7: "для lifetime одной модели допускается один initial request in-flight" —
    // and the refusal is observable (the return value), not a silently dropped second call.
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var applyCount = 0

    let (firstID, firstWait) = requests.start()
    #expect(
        owner.run(.primary, onConflict: .ignoreIfRunning, operation: firstWait) { _ in
            applyCount += 1
        }
    )

    let (secondID, secondWait) = requests.start()
    let duplicateStarted = owner.run(.primary, onConflict: .ignoreIfRunning, operation: secondWait)
    { _ in
        applyCount += 1
    }
    #expect(!duplicateStarted)

    // The refused call's own request is simply never awaited by anything; resolving it (if
    // some other code path still holds the id) must not somehow surface a second apply.
    requests.resolve(secondID, with: .success([]))
    requests.resolve(firstID, with: .success([1]))
    await waitUntil(applyCount > 0)

    #expect(applyCount == 1)
    #expect(!owner.isRunning(.primary))
}

@Test @MainActor
func test_effectOwner_restartAppliesOnlyTheNewerEvenWhenTheOlderCompletesLater() async {
    // R04 acceptance, verbatim: "Запрос A завершается после B; применяется B, A освобождается."
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var appliedInOrder: [LoadOutcome] = []

    let (idA, waitA) = requests.start()
    #expect(owner.run(.primary, operation: waitA) { appliedInOrder.append($0) })

    let (idB, waitB) = requests.start()
    #expect(
        owner.run(.primary, onConflict: .restart, operation: waitB) { appliedInOrder.append($0) }
    )

    // B finishes first; A (already cancelled by the restart above) finishes after — or, since
    // a cancelled consumer's `AsyncStream.next()` can itself return early, A may already have
    // finished (with the interrupted sentinel) before this call; either way `resolve` on an
    // already-ended request is a harmless no-op, and either way A's result must not appear.
    requests.resolve(idB, with: .success([2]))
    await waitUntil(!appliedInOrder.isEmpty)
    requests.resolve(idA, with: .success([1]))
    for _ in 0..<1_000 { await Task.yield() }  // let a real, non-cancelled A drain harmlessly

    #expect(appliedInOrder == [.success([2])])
    #expect(!owner.isRunning(.primary))
}

@Test @MainActor
func test_effectOwner_differentKeysDoNotContend() async {
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var appliedByKey: [LoadKey: LoadOutcome] = [:]

    let (primaryID, primaryWait) = requests.start()
    #expect(owner.run(.primary, operation: primaryWait) { appliedByKey[.primary] = $0 })
    let (pageID, pageWait) = requests.start()
    #expect(
        owner.run(.pagination, onConflict: .ignoreIfRunning, operation: pageWait) {
            appliedByKey[.pagination] = $0
        }
    )

    #expect(owner.isRunning(.primary))
    #expect(owner.isRunning(.pagination))

    requests.resolve(pageID, with: .success([10, 11]))
    requests.resolve(primaryID, with: .success([1, 2]))
    await waitUntil(appliedByKey[.primary] != nil && appliedByKey[.pagination] != nil)

    #expect(appliedByKey[.primary] == .success([1, 2]))
    #expect(appliedByKey[.pagination] == .success([10, 11]))
}

@Test @MainActor
func test_effectOwner_loadMoreDeduplicatesRepeatedDemandForTheSameCursor() async {
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var pageApplyCount = 0

    let (id, wait) = requests.start()
    #expect(
        owner.run(.pagination, onConflict: .ignoreIfRunning, operation: wait) { _ in
            pageApplyCount += 1
        }
    )
    // Scroll-driven demand can fire repeatedly near the same boundary before the first page
    // request resolves — each repeat must be refused, not queue a second in-flight request.
    #expect(
        !owner.run(
            .pagination,
            onConflict: .ignoreIfRunning,
            operation: { LoadOutcome.success([]) }
        ) { _ in
            pageApplyCount += 1
        }
    )
    #expect(
        !owner.run(
            .pagination,
            onConflict: .ignoreIfRunning,
            operation: { LoadOutcome.success([]) }
        ) { _ in
            pageApplyCount += 1
        }
    )

    requests.resolve(id, with: .success([20, 21]))
    await waitUntil(pageApplyCount > 0)

    #expect(pageApplyCount == 1)
}

@Test @MainActor
func test_effectOwner_refreshCancelsPaginationAsAModelPolicy() async {
    // P6.7: "Refresh... сбрасывает pagination generation; старый ответ не дописывает данные
    // в новый набор." EffectOwner does not know keys are related — this is the model's own
    // policy, demonstrated here as the intended composition: refresh calls `cancel(.pagination)`
    // itself alongside restarting `.primary`.
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var appliedByKey: [LoadKey: LoadOutcome] = [:]

    let (pageID, pageWait) = requests.start()
    #expect(
        owner.run(.pagination, onConflict: .ignoreIfRunning, operation: pageWait) {
            appliedByKey[.pagination] = $0
        }
    )

    // Refresh: model-level policy cancels pagination, then restarts primary.
    owner.cancel(.pagination)
    let (refreshID, refreshWait) = requests.start()
    #expect(
        owner.run(.primary, onConflict: .restart, operation: refreshWait) {
            appliedByKey[.primary] = $0
        }
    )

    // The stale page response arrives after cancellation — must not land.
    requests.resolve(pageID, with: .success([99]))
    requests.resolve(refreshID, with: .success([1, 2, 3]))
    await waitUntil(appliedByKey[.primary] != nil)
    for _ in 0..<1_000 { await Task.yield() }  // let the discarded, cancelled page drain too

    #expect(appliedByKey[.pagination] == nil)
    #expect(appliedByKey[.primary] == .success([1, 2, 3]))
    #expect(!owner.isRunning(.pagination))

    // Pagination is immediately available again for a fresh page request, not stuck.
    let (nextPageID, nextPageWait) = requests.start()
    #expect(
        owner.run(.pagination, onConflict: .ignoreIfRunning, operation: nextPageWait) {
            appliedByKey[.pagination] = $0
        }
    )
    requests.resolve(nextPageID, with: .success([4, 5]))
    await waitUntil(appliedByKey[.pagination] != nil)
    #expect(appliedByKey[.pagination] == .success([4, 5]))
}

@Test @MainActor
func test_effectOwner_errorDoesNotPermanentlyStickAKeyRetryRecovers() async {
    let owner = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var lastApplied: LoadOutcome?

    let (id, wait) = requests.start()
    #expect(owner.run(.primary, onConflict: .ignoreIfRunning, operation: wait) { lastApplied = $0 })
    requests.resolve(id, with: .failure("network down"))
    await waitUntil(lastApplied != nil)

    #expect(lastApplied == .failure("network down"))
    #expect(!owner.isRunning(.primary))  // not stuck: a retry is not refused as "already running"

    let (retryID, retryWait) = requests.start()
    #expect(owner.run(.primary, onConflict: .restart, operation: retryWait) { lastApplied = $0 })
    requests.resolve(retryID, with: .success([7]))
    await waitUntil(lastApplied == .success([7]))

    #expect(lastApplied == .success([7]))
}

@Test @MainActor
func test_effectOwner_viewOwnedAndModelOwnedScopesAreIndependent() async {
    // P6.7: "View-owned запрос отменяется при завершении его session. Model-owned запрос
    // может продолжаться при уходе страницы." Two separate `EffectOwner` instances model
    // exactly this — a view session's own scope, and the model's own long-lived scope.
    let viewScope = EffectOwner<LoadKey>()
    let modelScope = EffectOwner<LoadKey>()
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    var viewApplied: LoadOutcome?
    var modelApplied: LoadOutcome?

    let (viewID, viewWait) = requests.start()
    #expect(viewScope.run(.primary, operation: viewWait) { viewApplied = $0 })
    let (modelID, modelWait) = requests.start()
    #expect(modelScope.run(.primary, operation: modelWait) { modelApplied = $0 })

    // The view session ends (e.g. the page was popped) — only its own scope is torn down.
    viewScope.cancelAll()
    #expect(!viewScope.isRunning(.primary))
    #expect(modelScope.isRunning(.primary))

    requests.resolve(viewID, with: .success([1]))
    requests.resolve(modelID, with: .success([2]))
    await waitUntil(modelApplied != nil)

    #expect(viewApplied == nil)  // cancelled before its response arrived
    #expect(modelApplied == .success([2]))  // kept running past the view's own lifetime
}

@Test @MainActor
func test_effectOwner_releasesEverythingAfterCancelAllNoOrphanedTasks() async {
    weak var weakOwner: EffectOwner<LoadKey>?
    let requests = ControllableRequests<LoadOutcome>(interruptedValue: .failure("interrupted"))
    do {
        let owner = EffectOwner<LoadKey>()
        weakOwner = owner
        let (_, wait) = requests.start()
        #expect(owner.run(.primary, operation: wait) { _ in })
        await Task.yield()
        owner.cancelAll()
    }
    await waitUntil(weakOwner == nil)
    #expect(weakOwner == nil)
}
