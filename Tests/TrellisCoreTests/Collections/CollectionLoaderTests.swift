import Testing

@testable import TrellisCore

// R10 (`implementation-plan-6.md` P6.7 acceptance): a controllable fake API — every request
// suspends until the test resolves it — checks request counts, late responses, refresh during
// pagination, remount, cancel/retry, data key change and owner release.

private typealias Snapshot = CollectionSnapshot<Int, String>

@MainActor
private final class FakeFeed {
    let subject = StateSubject(Snapshot.initial(dataKey: "feed"))
    weak var loader: CollectionLoader<Int, String>?
    var calls: [CollectionLoadContext] = []
    var cancelledOnResume = 0
    private var pending: [CheckedContinuation<Bool, Never>] = []

    var inFlight: Int { pending.count }

    func hook(_ context: CollectionLoadContext) async -> CollectionLoadResult {
        calls.append(context)
        let succeeded = await withCheckedContinuation { pending.append($0) }
        if Task.isCancelled {
            cancelledOnResume += 1
        }
        // The model's side of the contract: check currency after every await.
        guard let loader, loader.isCurrent(context) else { return .completed }
        guard succeeded else { return .failed(CollectionLoadError(message: "offline")) }

        let current = subject.current
        let start = context.reason == .refresh ? 0 : current.count
        let existing = context.reason == .refresh ? [] : current.items
        let page = (start..<start + 20).map { CollectionItem(id: $0, value: "row \($0)") }
        subject.send(
            Snapshot(
                dataKey: context.dataKey,
                revision: current.revision + 1,
                items: existing + page
            )
        )
        return .completed
    }

    func resolve(_ succeeded: Bool = true) async {
        guard !pending.isEmpty else { return }

        pending.removeFirst().resume(returning: succeeded)
        await settle()
    }
}

@MainActor
private func settle() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}

@MainActor
private func makeLoader(_ feed: FakeFeed) -> CollectionLoader<Int, String> {
    let loader = CollectionLoader(source: feed.subject, pagination: PaginationPolicy(pageSize: 20))
    let hook: CollectionLoadHook = { [weak feed] context in
        await feed?.hook(context) ?? .completed
    }
    loader.onLoad = hook
    loader.onRefresh = hook
    loader.onLoadMore = hook
    feed.loader = loader
    return loader
}

private struct Row: ItemProvider {
    func makeNode(for item: String, id: Int) -> Node { Node() }
    func update(_ node: Node, with item: String, id: Int) {}
}

@MainActor
private func windowAtEnd(of feed: FakeFeed) -> MaterializationWindow<Row> {
    let window = MaterializationWindow(provider: Row(), estimatedLength: 20, dataKey: "feed")
    window.apply(feed.subject.current)
    let end = window.extents.totalExtent
    window.updateViewport(offset: max(0, end - 200), length: 200, crossExtent: 320)
    return window
}

@MainActor
@Test
func test_loader_hooksDoNotRunBeforeActivation() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    await settle()

    #expect(feed.calls.isEmpty)
    loader.activate()
    await settle()
    #expect(feed.calls.map(\.reason) == [.initial])
}

@MainActor
@Test
func test_loader_initialRunsOnceAndRemountDoesNotRequestAgain() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)

    loader.activate()
    loader.activate()
    await settle()
    #expect(feed.calls.count == 1)

    // Cancelled while in flight: the next activation may try again.
    loader.deactivate()
    await feed.resolve()
    #expect(feed.subject.current.count == 0)
    loader.activate()
    await settle()
    #expect(feed.calls.count == 2)

    await feed.resolve()
    #expect(feed.subject.current.count == 20)
    loader.deactivate()
    loader.activate()
    await settle()
    #expect(feed.calls.count == 2)
}

@MainActor
@Test
func test_loader_lateResponseOfOldDataKeyIsIgnored() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    loader.activate()
    await settle()

    feed.subject.send(Snapshot.initial(dataKey: "filter"))
    loader.sourceDidChange()
    await settle()
    #expect(feed.calls.map(\.dataKey) == ["feed", "filter"])

    await feed.resolve()  // the old "feed" request
    #expect(feed.subject.current.dataKey == "filter")
    #expect(feed.subject.current.count == 0)

    await feed.resolve()  // the "filter" request
    #expect(feed.subject.current.dataKey == "filter")
    #expect(feed.subject.current.count == 20)
}

@MainActor
@Test
func test_loader_pageDemandIsDeduplicatedAndRefreshSupersedesIt() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    loader.activate()
    await settle()
    await feed.resolve()

    let window = windowAtEnd(of: feed)
    #expect(loader.evaluateDemand(in: window) == .request(baseRevision: 1))
    #expect(loader.evaluateDemand(in: window) == .duplicate)
    await settle()
    #expect(feed.calls.map(\.reason) == [.initial, .loadMore])
    #expect(feed.calls.last?.pageSize == 20)

    loader.refresh()
    loader.refresh()
    await settle()
    #expect(feed.calls.map(\.reason) == [.initial, .loadMore, .refresh])

    await feed.resolve()  // late page result: not current any more
    #expect(feed.subject.current.count == 20)
    #expect(feed.subject.current.revision == 1)

    await feed.resolve()  // refresh
    #expect(feed.subject.current.revision == 2)
    #expect(feed.subject.current.items.first?.id == 0)
    #expect(loader.runningCount == 0)
}

@MainActor
@Test
func test_loader_pageSuccessRearmsForNextRevision() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    loader.activate()
    await settle()
    await feed.resolve()

    #expect(loader.evaluateDemand(in: windowAtEnd(of: feed)) == .request(baseRevision: 1))
    await settle()
    await feed.resolve()
    #expect(feed.subject.current.count == 40)

    #expect(loader.evaluateDemand(in: windowAtEnd(of: feed)) == .request(baseRevision: 2))
}

@MainActor
@Test
func test_loader_failedPageWaitsAndRetryRepeatsThePage() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    loader.activate()
    await settle()
    await feed.resolve()

    let window = windowAtEnd(of: feed)
    #expect(loader.evaluateDemand(in: window) == .request(baseRevision: 1))
    await settle()
    await feed.resolve(false)
    #expect(loader.failedReason == .loadMore)
    #expect(loader.evaluateDemand(in: window) == .awaitingRetry)

    loader.retry()
    await settle()
    #expect(feed.calls.last?.reason == .retry(of: .loadMore))
    #expect(loader.evaluateDemand(in: window) == .duplicate)
    await feed.resolve()
    #expect(feed.subject.current.count == 40)
    #expect(loader.failedReason == nil)
}

@MainActor
@Test
func test_loader_failedInitialRetryUsesRetryHook() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    var retries: [CollectionLoadReason] = []
    loader.onRetry = { [weak feed] context in
        retries.append(context.reason)
        return await feed?.hook(context) ?? .completed
    }
    loader.activate()
    await settle()
    await feed.resolve(false)
    #expect(loader.failedReason == .initial)

    loader.retry()
    await settle()
    #expect(retries == [.retry(of: .initial)])
    await feed.resolve()
    #expect(feed.subject.current.count == 20)
}

@MainActor
@Test
func test_loader_releaseCancelsInFlightTask() async {
    let feed = FakeFeed()
    weak var released: CollectionLoader<Int, String>?
    do {
        let loader = makeLoader(feed)
        released = loader
        loader.activate()
        await settle()
        #expect(feed.inFlight == 1)
    }
    #expect(released == nil)

    await feed.resolve()
    #expect(feed.cancelledOnResume == 1)
    #expect(feed.subject.current.count == 0)
}

// Defect #85: an initial request that published nothing must not be followed by page demand.
@MainActor
@Test
func test_loader_noPageDemandBeforeInitialDataArrives() async {
    let feed = FakeFeed()
    let loader = makeLoader(feed)
    let window = MaterializationWindow(provider: Row(), estimatedLength: 20, dataKey: "feed")
    window.updateViewport(offset: 0, length: 200, crossExtent: 320)
    loader.activate()
    await settle()
    #expect(loader.evaluateDemand(in: window) == .duplicate)

    feed.loader = nil  // the model drops the answer: the phase stays .initial
    await feed.resolve()
    #expect(loader.runningCount == 0)
    #expect(loader.evaluateDemand(in: window) == .notNeeded)
    await settle()
    #expect(feed.calls.map(\.reason) == [.initial])
}
