import LayoutCore
import StateCore
import Testing

@testable import Nodes

private struct Entry: Identifiable, Equatable {
    let id: Int
}

/// An item's node: 30 long.
@MainActor
private final class Cell: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 20, height: 30)) }
}

/// A scroll of a lazy stack of 100 items 30 long, with a record of what it prefetched.
@MainActor
private final class Feed: Node {
    let cells = NodeCache<Int, Cell> { _ in Cell() }
    lazy var stack = LazyStack<Entry>(estimatedLength: 30) { [cells] entry in cells[entry.id] }
    lazy var scroll = Scroll(.vertical, content: stack)
    var shown = true
    var prefetched: [[Int]] = []
    var cancelled: [[Int]] = []

    var allPrefetched: [Int] { prefetched.flatMap { $0 } }
    var allCancelled: [Int] { cancelled.flatMap { $0 } }

    init(count: Int = 100) {
        super.init()
        stack.items = (0..<count).map(Entry.init)
        stack.prefetch = { [weak self] items in self?.prefetched.append(items.map(\.id)) }
        stack.cancelPrefetch = { [weak self] items in self?.cancelled.append(items.map(\.id)) }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { if shown { scroll } }
    }
}

@MainActor
private func host(_ feed: Feed, height: Double = 150) -> NodeHost {
    let host = NodeHost(root: feed, size: LayoutSize(width: 200, height: height))
    host.layoutIfNeeded()
    return host
}

@MainActor
private func scroll(_ feed: Feed, to y: Double, in host: NodeHost) {
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: y)
    host.layoutIfNeeded()
}

@Test @MainActor
func theItemsNearTheWindowArePrefetchedOnceTheStackShows() {
    let feed = Feed()
    let host = host(feed)

    // The window is 0..150, two window lengths after it are 150..450: items 0 to 14.
    #expect(feed.prefetched == [Array(0...14)])
    #expect(feed.cancelled.isEmpty)
    host.detach()
}

@Test @MainActor
func scrollingPrefetchesTheItemsThatComeNearAndNoneTwice() {
    let feed = Feed()
    let host = host(feed)

    scroll(feed, to: 300, in: host)

    // The window is 300..450; the zone reaches 750: items 15 to 24 are new.
    #expect(feed.prefetched.last == Array(15...24))
    #expect(feed.allPrefetched.count == Set(feed.allPrefetched).count)
    host.detach()
}

@Test @MainActor
func aSmallMoveOfTheWindowAsksForNothing() {
    let feed = Feed()
    let host = host(feed)
    let calls = feed.prefetched.count

    scroll(feed, to: 5, in: host)
    scroll(feed, to: 10, in: host)

    #expect(feed.prefetched.count == calls)
    host.detach()
}

@Test @MainActor
func itemsLeftFarBehindAreCancelledAndItemsJustOutsideTheZoneAreNot() {
    let feed = Feed()
    let host = host(feed)

    // The window is 600..750: the zone is 300..1050, and the items kept reach one window
    // length farther, to 150: items before 5 are far, the rest are kept.
    scroll(feed, to: 600, in: host)

    #expect(Set(feed.allCancelled) == Set(0...4))
    #expect(feed.allPrefetched.contains(10), "item 10 was prefetched and is only just outside")
    #expect(!feed.allCancelled.contains(10))
    host.detach()
}

@Test @MainActor
func aWindowThatComesBackPrefetchesTheCancelledItemsAgain() {
    let feed = Feed()
    let host = host(feed)
    scroll(feed, to: 1_500, in: host)
    #expect(feed.allCancelled.contains(0))
    let before = feed.allPrefetched.filter { $0 == 0 }.count

    scroll(feed, to: 0, in: host)

    #expect(feed.allPrefetched.filter { $0 == 0 }.count == before + 1)
    host.detach()
}

@Test @MainActor
func itemsRemovedFromTheListAreCancelled() {
    let feed = Feed()
    let host = host(feed)

    feed.stack.items = (0..<100).filter { $0 >= 3 }.map(Entry.init)
    host.layoutIfNeeded()

    #expect(Set(feed.allCancelled) == [0, 1, 2])
    host.detach()
}

@Test @MainActor
func aStackThatLeavesTheScreenCancelsEverythingItPrefetched() {
    let feed = Feed()
    let host = host(feed)
    let told = Set(feed.allPrefetched)

    feed.shown = false
    feed.setNeedsLayout()
    host.layoutIfNeeded()

    #expect(Set(feed.allCancelled) == told)
    host.detach()
}

@Test @MainActor
func theDistanceSetsHowFarTheZoneReaches() {
    let feed = Feed()
    feed.stack.prefetchDistance = 0
    let host = host(feed)

    // Only the window itself: 150 long, five items.
    #expect(feed.allPrefetched == Array(0...4))
    host.detach()
}

@Test @MainActor
func aStackWithoutCallbacksAsksForNothing() {
    let feed = Feed()
    feed.stack.prefetch = nil
    feed.stack.cancelPrefetch = nil
    let host = host(feed)

    scroll(feed, to: 600, in: host)

    #expect(feed.prefetched.isEmpty)
    host.detach()
}
