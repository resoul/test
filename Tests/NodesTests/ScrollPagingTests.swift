import LayoutCore
import StateCore
import Testing

@testable import Nodes

/// A leaf of a fixed size.
@MainActor
private final class Block: Node {
    let size: LayoutSize

    init(_ width: Double, _ height: Double) {
        size = LayoutSize(width: width, height: height)
    }

    override var layoutContent: LeafContent? { .size(size) }
}

/// A 100-point window onto 250 points: pages start at 0 and 100, and the last one at 150,
/// where the content ends.
@MainActor
private final class Pager: Node {
    lazy var scroll = Scroll(.vertical, content: Block(100, 250))

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }
}

/// A 100-point window onto a row of three 100-point tiles.
@MainActor
private final class Row: Node {
    lazy var scroll = Scroll(.horizontal, content: Tiles())

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }

    final class Tiles: Node {
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                Block(100, 40)
                Block(100, 40)
                Block(100, 40)
            }
        }
    }
}

@MainActor
private func host(_ root: Node, width: Double = 100, height: Double = 100) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: width, height: height))
    host.layoutIfNeeded()
    return host
}

private func down(_ y: Double) -> LayoutPoint { LayoutPoint(x: 0, y: y) }

@Test @MainActor
func pagesAreWindowsFromTheStartAndTheLastEndsTheContent() {
    let pager = Pager()
    let host = host(pager)
    let scroll = pager.scroll

    #expect(scroll.pageCount == 3)
    #expect(scroll.page == 0)
    scroll.scroll(toPage: 1)
    #expect(scroll.contentOffset == down(100))
    #expect(scroll.page == 1)
    scroll.scroll(toPage: 2)
    #expect(scroll.contentOffset == down(150))
    #expect(scroll.page == 2)
    scroll.scroll(toPage: 7)
    #expect(scroll.contentOffset == down(150))
    host.detach()
}

@Test @MainActor
func aSlowDragGoesToTheNearestPageAndASwipeToTheNext() {
    let pager = Pager()
    let host = host(pager)
    let scroll = pager.scroll

    // Let go 40 in: back to the first page; 60 in: on to the second.
    #expect(scroll.pagingTarget(from: down(0), at: down(40), velocity: down(50)) == down(0))
    #expect(scroll.pagingTarget(from: down(0), at: down(60), velocity: down(50)) == down(100))
    // A swipe only 10 in goes on; one back from the second page goes back.
    #expect(scroll.pagingTarget(from: down(0), at: down(10), velocity: down(900)) == down(100))
    #expect(scroll.pagingTarget(from: down(100), at: down(95), velocity: down(-900)) == down(0))
    // Never more than one page from where it started.
    #expect(scroll.pagingTarget(from: down(0), at: down(140), velocity: down(5000)) == down(100))
    host.detach()
}

@Test @MainActor
func aRowFromTheRightPagesFromItsRightEdge() {
    let row = Row()
    let host = NodeHost(root: row, size: LayoutSize(width: 100, height: 40))
    host.direction = .rightToLeft
    host.layoutIfNeeded()
    let scroll = row.scroll

    // It starts at its right: the offsets toward its end go down.
    #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 0))
    #expect(scroll.pageCount == 3)
    scroll.scroll(toPage: 2)
    #expect(scroll.contentOffset == LayoutPoint(x: -200, y: 0))
    #expect(scroll.page == 2)
    // From the last page, a swipe raising the offset goes back toward the start: page 1.
    let target = scroll.pagingTarget(
        from: LayoutPoint(x: -200, y: 0),
        at: LayoutPoint(x: -190, y: 0),
        velocity: LayoutPoint(x: 900, y: 0)
    )
    #expect(target == LayoutPoint(x: -100, y: 0))
    host.detach()
}

@Test @MainActor
func pagingIsOffUntilAsked() {
    let pager = Pager()
    let host = host(pager)
    host.didRender()
    #expect(!pager.scroll.isPaging)

    pager.scroll.isPaging = true

    // The adapters take it when the tree is drawn.
    #expect(host.needsRender)
    host.detach()
}
