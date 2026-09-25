import LayoutCore
import StateCore
import Testing

@testable import Nodes

/// A leaf of a fixed size; tappable, and so focusable, when asked.
@MainActor
private final class Row: Node {
    let size: LayoutSize

    init(_ width: Double, _ height: Double, tappable: Bool = false) {
        size = LayoutSize(width: width, height: height)
        super.init()
        if tappable {
            onTap = {}
        }
    }

    override var layoutContent: LeafContent? { .size(size) }
}

/// Ten rows of 30 points, one under another.
@MainActor
private final class List: Node {
    let rows = (0..<10).map { _ in Row(50, 30, tappable: true) }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for row in rows { row }
        }
        .alignItems(.start)
    }
}

/// A 50-point header over a scroll of the list that takes the rest of the height.
@MainActor
private final class Screen: Node {
    let header = Row(100, 50)
    let list = List()
    lazy var scroll = Scroll(.vertical, content: list)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            header
            scroll
        }
    }
}

@MainActor
private func host(_ root: Node, width: Double = 200, height: Double = 150) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: width, height: height))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func aScrollTakesTheSizeItIsGivenAndItsContentKeepsItsLength() {
    let screen = Screen()
    let host = host(screen)

    // The content is 300 points long, yet the scroll gets the 100 left under the header.
    #expect(screen.scroll.frame == LayoutRect(x: 0, y: 50, width: 200, height: 100))
    #expect(screen.list.frame == LayoutRect(x: 0, y: 0, width: 200, height: 300))
    #expect(screen.scroll.contentBounds == LayoutRect(x: 0, y: 0, width: 200, height: 300))
    #expect(screen.scroll.offsetRange.highest == LayoutPoint(x: 0, y: 200))
    #expect(screen.scroll.canScroll)
    host.detach()
}

/// A scroll beside a row of a fixed height, in a column the size of its content.
@MainActor
private final class Stack: Node {
    let top = Row(100, 40)
    let list = List()
    lazy var scroll = Scroll(.vertical, content: list)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            top.size(width: 100, height: 60)
            scroll
        }
    }
}

@Test @MainActor
func theNodesBesideAScrollKeepTheirSize() {
    let stack = Stack()
    let host = host(stack)

    // Sized by its 300-point content, the scroll would have squeezed the row to its 40.
    #expect(stack.top.frame.size.height == 60)
    #expect(stack.scroll.frame.size.height == 90)
    host.detach()
}

@Test @MainActor
func shortContentFillsTheWindowAndDoesNotScroll() {
    let list = List()
    let scroll = Scroll(.vertical, content: list)
    let host = host(scroll, height: 400)

    #expect(list.frame.size.height == 400)
    #expect(!scroll.canScroll)
    scroll.contentOffset = LayoutPoint(x: 0, y: 50)
    #expect(scroll.contentOffset == .zero)
    host.detach()
}

@Test @MainActor
func anOffsetPastTheEndShowsTheEnd() {
    let screen = Screen()
    let host = host(screen)
    var reported: [LayoutPoint] = []
    screen.scroll.onScroll = { reported.append($0) }

    screen.scroll.contentOffset = LayoutPoint(x: 30, y: 500)

    #expect(screen.scroll.contentOffset == LayoutPoint(x: 0, y: 200))
    #expect(reported == [LayoutPoint(x: 0, y: 200)])
    host.detach()
}

@Test @MainActor
func anOffsetSetBeforeTheFirstLayoutIsKeptUntilThere() {
    let screen = Screen()
    screen.scroll.contentOffset = LayoutPoint(x: 0, y: 90)

    let host = host(screen)

    #expect(screen.scroll.contentOffset == LayoutPoint(x: 0, y: 90))
    host.detach()
}

@Test @MainActor
func tapsFindTheNodesWhereTheContentWasMoved() {
    let screen = Screen()
    let host = host(screen)
    screen.scroll.contentOffset = LayoutPoint(x: 0, y: 65)

    // 10 points into the scroll is 75 into the content: the third row (60 to 90).
    #expect(screen.hitTest(LayoutPoint(x: 10, y: 60)) === screen.list.rows[2])
    // The header covers what the content scrolled up: it is cut off there.
    #expect(screen.hitTest(LayoutPoint(x: 10, y: 20)) === screen.header)
    host.detach()
}

@Test @MainActor
func focusFramesFollowTheOffset() {
    let screen = Screen()
    let host = host(screen)

    screen.scroll.contentOffset = LayoutPoint(x: 0, y: 40)

    let third = host.focusItems().first { $0.node == screen.list.rows[2].id }
    #expect(third?.frame == LayoutRect(x: 0, y: 70, width: 50, height: 30))
    host.detach()
}

@Test @MainActor
func focusMovingToANodeOutOfSightScrollsItIntoView() {
    let screen = Screen()
    let host = host(screen)

    host.focus(screen.list.rows[9].id)

    // The last row, 270 to 300, ends at the window's bottom.
    #expect(screen.scroll.contentOffset == LayoutPoint(x: 0, y: 200))
    host.focus(screen.list.rows[1].id)
    #expect(screen.scroll.contentOffset == LayoutPoint(x: 0, y: 30))
    host.detach()
}

@Test @MainActor
func aHorizontalScrollRightToLeftStartsAtTheRight() {
    let strip = Strip()
    let scroll = Scroll(.horizontal, content: strip)
    let host = NodeHost(root: scroll, size: LayoutSize(width: 100, height: 40))
    host.direction = .rightToLeft
    host.layoutIfNeeded()

    // The strip is 300 wide and starts at the right: its left part is off to the left.
    #expect(strip.frame.origin.x == -200)
    #expect(scroll.offsetRange.lowest == LayoutPoint(x: -200, y: 0))
    #expect(scroll.offsetRange.highest == .zero)
    #expect(scroll.contentOffset == .zero)
    scroll.contentOffset = LayoutPoint(x: -500, y: 0)
    #expect(scroll.contentOffset == LayoutPoint(x: -200, y: 0))
    host.detach()
}

/// Three 100-point tiles in a row.
@MainActor
private final class Strip: Node {
    let tiles = (0..<3).map { _ in Row(100, 40) }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            for tile in tiles { tile }
        }
    }
}

@Test @MainActor
func scrollingWithoutAnimationDrawsJustTheScroll() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    screen.scroll.contentOffset = LayoutPoint(x: 0, y: 10)

    #expect(!host.needsRender)
    #expect(host.scrolledSinceRender.count == 1)
    host.didRender()
    #expect(host.scrolledSinceRender.isEmpty)
    host.detach()
}

@Test @MainActor
func scrollingWithAnimationDrawsTheTreeWithIt() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    withAnimation(.linear(duration: 1)) {
        screen.scroll.contentOffset = LayoutPoint(x: 0, y: 10)
    }

    #expect(host.needsRender)
    #expect(host.renderAnimation == .linear(duration: 1))
    host.detach()
}

/// A header that sticks out more the further its scroll went.
@MainActor
private final class Stretchy: Node {
    let header = Row(100, 20)
    let list = List()
    lazy var scroll = Scroll(.vertical, content: list)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            header.size(width: 100, height: .points(20 + scroll.contentOffset.y / 2))
            scroll
        }
    }
}

@Test @MainActor
func aLayoutReadingTheOffsetIsLaidOutAgainWhenItChanges() {
    let screen = Stretchy()
    let host = host(screen)

    screen.scroll.contentOffset = LayoutPoint(x: 0, y: 40)
    host.layoutIfNeeded()

    #expect(screen.header.frame.size.height == 40)
    host.detach()
}

/// A row of tiles scrolling sideways between two rows, in a column the size of its content.
@MainActor
private final class Carousel: Node {
    let above = Row(100, 20)
    let strip = Strip()
    lazy var scroll = Scroll(.horizontal, content: strip)
    let below = Row(100, 20)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            above
            scroll
            below
        }
    }
}

@Test @MainActor
func aSidewaysScrollInAColumnIsAsTallAsItsContent() {
    let carousel = Carousel()
    let host = host(carousel, width: 150, height: 300)

    #expect(carousel.scroll.frame == LayoutRect(x: 0, y: 20, width: 150, height: 40))
    #expect(carousel.below.frame.origin.y == 60)
    #expect(carousel.scroll.offsetRange.highest == LayoutPoint(x: 150, y: 0))
    host.detach()
}

/// The carousel as the content of a vertical scroll: its column is sized by its content.
@MainActor
private final class Feed: Node {
    let carousel = Carousel()
    lazy var scroll = Scroll(.vertical, content: carousel)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }
}

@Test @MainActor
func aSidewaysScrollInsideAScrollingListKeepsItsHeight() {
    let feed = Feed()
    let host = host(feed, width: 150, height: 50)

    #expect(feed.carousel.scroll.frame.size.height == 40)
    #expect(feed.scroll.offsetRange.highest == LayoutPoint(x: 0, y: 30))
    // A drag in the carousel moves it sideways and the list up and down.
    let found = host.scrolls(at: LayoutPoint(x: 10, y: 30))
    #expect(found.count == 2)
    #expect(found.first === feed.carousel.scroll)
    #expect(found.last === feed.scroll)
    host.detach()
}

/// A scroll given a height where it is placed, in a column the size of its content.
@MainActor
private final class Sized: Node {
    let list = List()
    lazy var scroll = Scroll(.vertical, content: list)
    let below = Row(100, 20)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            scroll.size(height: 80)
            below
        }
        .alignItems(.start)
    }
}

@Test @MainActor
func aSizeSetWhereTheScrollIsPlacedIsKept() {
    let sized = Sized()
    let feed = Scroll(.vertical, content: sized)
    let host = host(feed, width: 200, height: 60)

    #expect(sized.scroll.frame.size.height == 80)
    #expect(sized.below.frame.origin.y == 80)
    host.detach()
}

@Test @MainActor
func assistiveScrollingTurnsPagesAndStopsAtTheEnd() {
    let screen = Screen()
    let host = host(screen)
    let row = screen.list.rows[0].id

    // A 100-point window onto 300 points: pages at 0, 100 and 200.
    #expect(
        host.scrollPage(around: row, axis: .vertical, forward: true)
            == ScrollPage(number: 2, count: 3)
    )
    #expect(
        host.scrollPage(around: row, axis: nil, forward: true) == ScrollPage(number: 3, count: 3)
    )
    #expect(host.scrollPage(around: row, axis: .vertical, forward: true) == nil)
    #expect(host.scrollPage(around: row, axis: .horizontal, forward: false) == nil)
    #expect(
        host.scrollPage(around: row, axis: .vertical, forward: false)
            == ScrollPage(number: 2, count: 3)
    )
    host.detach()
}

@Test @MainActor
func revealingANodeScrollsToIt() {
    let screen = Screen()
    let host = host(screen)

    host.reveal(screen.list.rows[8].id)

    #expect(screen.scroll.contentOffset == LayoutPoint(x: 0, y: 170))
    host.detach()
}
