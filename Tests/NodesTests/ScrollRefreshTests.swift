import LayoutCore
import StateCore
import Testing

@testable import Nodes

@MainActor
private final class Block: Node {
    let size: LayoutSize

    init(_ width: Double, _ height: Double) {
        size = LayoutSize(width: width, height: height)
    }

    override var layoutContent: LeafContent? { .size(size) }
}

/// Keeps what the scroll told it.
@MainActor
private final class Indicator: Node, RefreshIndicator {
    var shown: [(pull: Double, isRefreshing: Bool)] = []

    func showRefresh(pull: Double, isRefreshing: Bool) {
        shown.append((pull, isRefreshing))
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 0, height: 0)) }
}

/// A refresh that waits for the test to let it end.
@MainActor
private final class Refresh {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func run() async {
        calls += 1
        await withCheckedContinuation { waiting = $0 }
    }

    func finish() {
        waiting?.resume()
        waiting = nil
    }
}

/// A 100-point window onto 300 points, refreshing.
@MainActor
private final class Feed: Node {
    let indicator = Indicator()
    let refresh = Refresh()
    lazy var scroll = Scroll(.vertical, content: Block(100, 300))

    override init() {
        super.init()
        scroll.refreshIndicator = indicator
        scroll.onRefresh = { [refresh] in await refresh.run() }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }
}

@MainActor
private func host(_ root: Node) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: 100, height: 100))
    host.layoutIfNeeded()
    return host
}

private func down(_ y: Double) -> LayoutPoint { LayoutPoint(x: 0, y: y) }

@Test @MainActor
func pulledPastTheDistanceAndLetGoItRefreshesWithTheRoomOpen() async {
    let feed = Feed()
    let host = host(feed)
    let scroll = feed.scroll

    scroll.platformDidScroll(to: down(-70))
    #expect(feed.indicator.shown.last?.pull == 1)
    #expect(scroll.platformDidRelease())

    #expect(scroll.isRefreshing)
    #expect(scroll.contentOffset == down(-56))
    #expect(scroll.offsetRange.lowest == down(-56))
    #expect(feed.indicator.shown.last?.isRefreshing == true)
    // Letting go again does not start another.
    #expect(!scroll.platformDidRelease())
    for _ in 0..<10 where feed.refresh.calls == 0 { await Task.yield() }
    #expect(feed.refresh.calls == 1)

    feed.refresh.finish()
    for _ in 0..<100 where scroll.isRefreshing { await Task.yield() }

    #expect(!scroll.isRefreshing)
    #expect(scroll.contentOffset == down(0))
    #expect(feed.indicator.shown.last?.isRefreshing == false)
    host.detach()
}

@Test @MainActor
func aShortPullDoesNotRefresh() {
    let feed = Feed()
    let host = host(feed)

    feed.scroll.platformDidScroll(to: down(-28))

    #expect(feed.indicator.shown.last?.pull == 0.5)
    #expect(!feed.scroll.platformDidRelease())
    #expect(!feed.scroll.isRefreshing)
    host.detach()
}

@Test @MainActor
func aPullThatReachedTheDistanceRefreshesThoughItEasedOff() {
    let feed = Feed()
    let host = host(feed)
    let scroll = feed.scroll

    scroll.platformDidScroll(to: down(-60))
    scroll.platformDidScroll(to: down(-30))

    #expect(scroll.platformDidRelease())
    #expect(scroll.isRefreshing)
    host.detach()
}

@Test @MainActor
func aLaterShortPullDoesNotRefreshForAnEarlierLongOne() {
    let feed = Feed()
    feed.scroll.onRefresh = nil
    let host = host(feed)
    let scroll = feed.scroll
    scroll.platformDidScroll(to: down(-60))
    scroll.platformDidRelease()
    scroll.platformDidScroll(to: down(0))

    feed.scroll.onRefresh = { [refresh = feed.refresh] in await refresh.run() }
    scroll.platformDidScroll(to: down(-20))

    #expect(!scroll.platformDidRelease())
    host.detach()
}

@Test @MainActor
func theIndicatorIsOverTheContentAndNotPartOfIt() {
    let feed = Feed()
    let host = host(feed)

    #expect(feed.indicator.frame == LayoutRect(x: 0, y: -56, width: 100, height: 56))
    #expect(feed.scroll.contentBounds == LayoutRect(x: 0, y: 0, width: 100, height: 300))
    #expect(feed.scroll.offsetRange.lowest == down(0))
    host.detach()
}

@Test @MainActor
func withoutARefreshAPullIsOnlyAPull() {
    let feed = Feed()
    feed.scroll.onRefresh = nil
    let host = host(feed)

    feed.scroll.platformDidScroll(to: down(-80))

    #expect(!feed.scroll.platformDidRelease())
    #expect(feed.indicator.shown.isEmpty)
    // Nor is the indicator placed.
    #expect(feed.indicator.supernode == nil)
    host.detach()
}

@Test @MainActor
func aRefreshStartedFurtherDownLeavesTheContentWhereItIs() async {
    let feed = Feed()
    let host = host(feed)
    feed.scroll.contentOffset = down(150)

    feed.scroll.beginRefresh()

    #expect(feed.scroll.isRefreshing)
    #expect(feed.scroll.contentOffset == down(150))
    feed.refresh.finish()
    for _ in 0..<100 where feed.scroll.isRefreshing { await Task.yield() }
    #expect(feed.scroll.contentOffset == down(150))
    host.detach()
}

@Test @MainActor
func aHorizontalScrollDoesNotRefresh() {
    let scroll = Scroll(.horizontal, content: Block(300, 40))
    scroll.onRefresh = {}
    let host = NodeHost(root: scroll, size: LayoutSize(width: 100, height: 40))
    host.layoutIfNeeded()

    scroll.beginRefresh()

    #expect(!scroll.isRefreshing)
    host.detach()
}
