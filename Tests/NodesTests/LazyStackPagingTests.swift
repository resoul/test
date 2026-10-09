import LayoutCore
import StateCore
import Testing
import Tracing
import os

@testable import Nodes

private struct Entry: Identifiable {
    let id: Int
}

/// An item's node: 30 long.
@MainActor
private final class Cell: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 20, height: 30)) }
}

/// A scroll of a lazy stack that pages, and a record of the pages it asked for.
@MainActor
private final class PagedFeed: Node {
    let cells = NodeCache<Int, Cell> { _ in Cell() }
    lazy var stack = LazyStack<Entry>(estimatedLength: 30) { [cells] entry in cells[entry.id] }
    lazy var scroll = Scroll(.vertical, content: stack)
    var requests: [PageRequest] = []
    /// What the loader does with a page: add `pageSize` items by default.
    var behavior: @MainActor (PageRequest) async throws -> Void = { _ in }
    private(set) var nextID = 0

    init(count: Int, policy: PaginationPolicy? = PaginationPolicy(pageSize: 10)) {
        super.init()
        append(count)
        stack.pagination = policy
        stack.loadMore = { [weak self] request in
            guard let self else { return }

            requests.append(request)
            try await behavior(request)
        }
    }

    func append(_ count: Int) {
        stack.items += (0..<count).map { _ in
            defer { nextID += 1 }
            return Entry(id: nextID)
        }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }
}

@MainActor
private func host(_ root: Node, height: Double = 150) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: 200, height: height))
    host.layoutIfNeeded()
    return host
}

/// Lets the load tasks run, and the host lay out what they changed as its adapter does, until
/// `condition` holds.
@MainActor
private func settle(_ host: NodeHost? = nil, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        host?.layoutIfNeeded()
        if condition() { return true }

        await Task.yield()
    }
    return condition()
}

@MainActor
private func scroll(_ feed: PagedFeed, to y: Double, in host: NodeHost) {
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: y)
    host.layoutIfNeeded()
}

@Test @MainActor
func theStackAsksForAPageWhenTheWindowComesNearTheEnd() async {
    // 20 items are 600 long; the window is 150, so two windows of it are 300.
    let feed = PagedFeed(count: 20)
    feed.behavior = { [weak feed] _ in feed?.append(10) }
    let host = host(feed)

    // 450 are left after the window: far.
    #expect(feed.requests.isEmpty)
    #expect(feed.stack.pageLoadState == .idle)

    // 250 are left after it.
    scroll(feed, to: 200, in: host)

    #expect(await settle { feed.stack.items.count == 30 })
    #expect(feed.requests == [PageRequest(pageSize: 10, loadedCount: 20)])
    #expect(await settle { feed.stack.pageLoadState == .idle })
    host.detach()
}

@Test @MainActor
func aPageOnItsWayShowsAsLoadingAndIsNotAskedForTwice() async {
    let feed = PagedFeed(count: 20)
    var finish: CheckedContinuation<Void, Never>?
    feed.behavior = { _ in await withCheckedContinuation { finish = $0 } }
    let host = host(feed)

    scroll(feed, to: 300, in: host)
    #expect(await settle { feed.stack.pageLoadState == .loading })
    // The window moves again while the page is on its way.
    scroll(feed, to: 400, in: host)
    scroll(feed, to: 450, in: host)

    #expect(feed.requests.count == 1)
    finish?.resume()
    #expect(await settle { feed.stack.pageLoadState == .idle })
    host.detach()
}

@Test @MainActor
func aFailedPageShowsAsFailedAndWaitsForARetry() async {
    struct Offline: Error {}
    let feed = PagedFeed(count: 20)
    feed.behavior = { _ in throw Offline() }
    let host = host(feed)
    scroll(feed, to: 300, in: host)
    #expect(await settle { feed.stack.pageLoadState == .failed })
    #expect(feed.stack.pageLoadError is Offline)

    // Scrolling does not ask again by itself.
    scroll(feed, to: 400, in: host)
    scroll(feed, to: 450, in: host)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(feed.requests.count == 1)
    #expect(feed.stack.pageLoadState == .failed)

    // The person asks again; this time it works.
    feed.behavior = { [weak feed] _ in feed?.append(10) }
    feed.stack.retryLoadingPage()
    #expect(await settle { feed.stack.items.count == 30 })
    #expect(feed.requests.count == 2)
    #expect(feed.requests[1].isRetry)
    #expect(await settle { feed.stack.pageLoadState == .idle })
    #expect(feed.stack.pageLoadError == nil)
    host.detach()
}

@Test @MainActor
func theEndOfThePagesStopsTheAsking() async {
    let feed = PagedFeed(count: 20)
    feed.behavior = { [weak feed] _ in
        feed?.append(3)
        feed?.stack.reachedEnd = true
    }
    let host = host(feed)

    scroll(feed, to: 300, in: host)
    #expect(await settle { feed.stack.reachedEnd })
    scroll(feed, to: 500, in: host)
    scroll(feed, to: 600, in: host)

    #expect(feed.requests.count == 1)
    #expect(feed.stack.pageLoadState == .endReached)
    host.detach()
}

@Test @MainActor
func anEmptyStackAsksForItsFirstPage() async {
    let feed = PagedFeed(count: 0)
    feed.behavior = { [weak feed] _ in feed?.append(40) }
    let host = host(feed)

    #expect(await settle(host) { feed.stack.items.count == 40 })
    #expect(feed.requests == [PageRequest(pageSize: 10, loadedCount: 0)])
    host.detach()
}

@Test @MainActor
func aListShorterThanItsWindowFillsItButOnlyUpToTheAutomaticLimit() async {
    // Pages of two items, 60 long: the 150 window never fills.
    let feed = PagedFeed(count: 0, policy: PaginationPolicy(pageSize: 2, maximumAutomaticPages: 3))
    feed.behavior = { [weak feed] _ in feed?.append(2) }
    let host = host(feed)

    #expect(await settle(host) { feed.requests.count == 3 })
    try? await Task.sleep(for: .milliseconds(50))
    host.layoutIfNeeded()

    #expect(feed.requests.count == 3)
    #expect(feed.stack.items.count == 6)
    host.detach()
}

@Test @MainActor
func aPageThatAddsNothingDoesNotMakeTheStackAskForever() async {
    let feed = PagedFeed(count: 5)
    let live = host(feed)

    #expect(await settle(live) { feed.requests.count == 1 })
    for _ in 0..<5 {
        live.setNeedsLayout()
        live.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
    }

    // The loader did nothing: no items, no end. Layouts do not ask again.
    #expect(feed.requests.count == 1)
    live.detach()
}

@Test @MainActor
func leavingTheScreenCancelsThePageOnItsWayWithoutFailingIt() async {
    let feed = PagedFeed(count: 20)
    var cancelled = false
    feed.behavior = { _ in
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled = true
            throw error
        }
    }
    let host = host(feed)
    scroll(feed, to: 300, in: host)
    #expect(await settle { feed.stack.pageLoadState == .loading })

    host.detach()

    #expect(await settle { cancelled })
    #expect(await settle { feed.stack.pageLoadState == .idle })
    #expect(feed.stack.pageLoadError == nil)
}

@Test @MainActor
func restartingPagingForgetsTheFailureTheEndAndThePageOnItsWay() async {
    struct Offline: Error {}
    let feed = PagedFeed(count: 20)
    feed.behavior = { _ in throw Offline() }
    let host = host(feed)
    scroll(feed, to: 300, in: host)
    #expect(await settle { feed.stack.pageLoadState == .failed })
    feed.stack.reachedEnd = true

    // A new search: other items, a first page to ask for.
    feed.behavior = { [weak feed] _ in feed?.append(10) }
    feed.stack.items = []
    feed.stack.restartPagination()
    host.layoutIfNeeded()

    #expect(feed.stack.reachedEnd == false)
    #expect(feed.stack.pageLoadError == nil)
    #expect(await settle { feed.requests.count == 2 })
    #expect(feed.requests[1].loadedCount == 0)
    #expect(await settle { feed.stack.items.count >= 10 })
    host.detach()
}

@Test @MainActor
func withoutPaginationOrALoaderTheStackNeverAsks() async {
    let withoutPolicy = PagedFeed(count: 20, policy: nil)
    let host1 = host(withoutPolicy)
    scroll(withoutPolicy, to: 450, in: host1)

    let withoutLoader = PagedFeed(count: 20)
    withoutLoader.stack.loadMore = nil
    let host2 = host(withoutLoader)
    scroll(withoutLoader, to: 450, in: host2)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(withoutPolicy.requests.isEmpty)
    #expect(withoutLoader.requests.isEmpty)
    host1.detach()
    host2.detach()
}

@Test @MainActor
func theItemsTriggerCountsFromTheLastItemThatShowsInAGrid() async {
    // 3 across: 60 items are 20 lines of 30. The window shows 5 lines: items 0...14.
    let feed = PagedFeed(
        count: 60,
        policy: PaginationPolicy(pageSize: 9, trigger: .remainingItems(6))
    )
    feed.stack.lanes = 3
    feed.behavior = { [weak feed] _ in feed?.append(9) }
    let firstHost = host(feed)
    #expect(feed.requests.isEmpty)

    // The window shows lines 15...19: items 45...59, none left after them.
    scroll(feed, to: 450, in: firstHost)
    #expect(await settle { feed.requests.count == 1 })

    // Lines 12...16 show: items up to 50, nine left — not near enough yet.
    let other = PagedFeed(
        count: 60,
        policy: PaginationPolicy(pageSize: 9, trigger: .remainingItems(6))
    )
    other.stack.lanes = 3
    let otherHost = host(other)
    scroll(other, to: 360, in: otherHost)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(other.requests.isEmpty)
    firstHost.detach()
    otherHost.detach()
}

@Test @MainActor
func aPageOnItsWayIsMarkedFromTheRequestToTheAnswer() async {
    let feed = PagedFeed(count: 23)
    feed.behavior = { [weak feed] _ in feed?.append(10) }
    let host = host(feed)
    let marks = OSAllocatedUnfairLock<[Trace.Record]>(initialState: [])
    let observation = Trace.observe { record in
        guard record.name == .pageLoad else { return }
        marks.withLock { $0.append(record) }
    }
    defer { observation.cancel() }

    scroll(feed, to: 250, in: host)

    #expect(await settle { feed.stack.items.count == 33 })
    #expect(await settle { feed.stack.pageLoadState == .idle })
    let seen = marks.withLock { $0 }.filter { $0.detail == "loaded 23" }
    #expect(seen.map(\.phase) == [.begin, .end])
    host.detach()
}
