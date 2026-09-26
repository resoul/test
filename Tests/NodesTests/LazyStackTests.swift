import LayoutCore
import StateCore
import Testing

@testable import Nodes

private struct Entry: Identifiable {
    let id: Int
    var length: Double = 30
}

/// An item's node: as long along `axis` as its entry says, and focusable.
@MainActor
private final class Cell: Node {
    let axis: ScrollAxis
    var entry = Entry(id: -1) {
        didSet { setNeedsLayout() }
    }

    init(_ axis: ScrollAxis = .vertical) {
        self.axis = axis
        super.init()
        isFocusable = true
    }

    func showing(_ entry: Entry) -> Cell {
        if entry.length != self.entry.length || entry.id != self.entry.id {
            self.entry = entry
        }
        return self
    }

    override var layoutContent: LeafContent? {
        axis == .vertical
            ? .size(LayoutSize(width: 20, height: entry.length))
            : .size(LayoutSize(width: entry.length, height: 20))
    }
}

/// A vertical scroll of a lazy stack of `count` entries, with an optional header above the
/// stack inside the scroll.
@MainActor
private final class Feed: Node {
    let cells = NodeCache<Int, Cell> { _ in Cell() }
    let header: Cell?
    lazy var stack = LazyStack<Entry>(estimatedLength: 30) { [cells] entry in
        cells[entry.id].showing(entry)
    }
    lazy var scroll = Scroll(.vertical, content: body)
    private lazy var body = Body(header: header, stack: stack)

    init(count: Int, length: Double = 30, header: Double? = nil) {
        self.header = header.map { Cell().showing(Entry(id: -2, length: $0)) }
        super.init()
        stack.items = (0..<count).map { Entry(id: $0, length: length) }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }

    private final class Body: Node {
        let header: Cell?
        let stack: LazyStack<Entry>

        init(header: Cell?, stack: LazyStack<Entry>) {
            self.header = header
            self.stack = stack
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                header
                stack
            }
        }
    }
}

@MainActor
private func host(_ root: Node, width: Double = 200, height: Double = 150) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: width, height: height))
    host.layoutIfNeeded()
    return host
}

/// Where `node` shows in the scroll's window, along the vertical axis.
@MainActor
private func shown(_ node: Node, in scroll: Scroll) -> Double? {
    scroll.frame(of: node).map { $0.origin.y - scroll.contentOffset.y }
}

@Test @MainActor
func aLongStackLaysOutOnlyTheItemsNearTheWindow() {
    let feed = Feed(count: 1000)
    let host = host(feed)

    // Five items show, and a screen of five more is laid out after them.
    #expect(feed.stack.laidOutItems == 0..<10)
    #expect(feed.stack.subnodes.count == 10)
    #expect(feed.stack.frame.size.height == 30 * 1000)
    #expect(feed.scroll.offsetRange.highest.y == 30 * 1000 - 150)
    #expect(feed.stack.subnodes[3].frame.origin.y == 90)
    host.detach()
}

@Test @MainActor
func scrollingFarLaysOutTheItemsTheWindowCameTo() {
    let feed = Feed(count: 1000)
    let host = host(feed)

    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    #expect(host.needsLayout)
    host.layoutIfNeeded()

    // Item 500 is at the top; five before and five after the window are laid out.
    #expect(feed.stack.laidOutItems == 495..<510)
    let first = feed.cells[500]
    #expect(first.isMounted)
    #expect(shown(first, in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func scrollingWithinWhatIsLaidOutDoesNotLayOutAgain() {
    let feed = Feed(count: 1000)
    let host = host(feed)
    // A layout of the stack where it knows where it is, as after any scroll.
    host.setNeedsLayout()
    host.layoutIfNeeded()
    let passes = host.passes

    // The window reaches 70 points further, less than half a screen past what is laid out.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 70)
    host.layoutIfNeeded()
    #expect(host.passes == passes)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 80)
    host.layoutIfNeeded()
    #expect(host.passes == passes + 1)
    #expect(feed.stack.laidOutItems == 0..<13)
    host.detach()
}

@Test @MainActor
func theNodesOfItemsFarAwayAreReleased() {
    let feed = Feed(count: 1000)
    let host = host(feed)
    weak var firstCell = feed.cells[0]

    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    host.layoutIfNeeded()
    // The cache lets go of what the pass before it did not ask for.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 20000)
    host.layoutIfNeeded()

    #expect(firstCell == nil)
    // What the last two passes asked for: 15 items and 16.
    #expect(feed.cells.count == 15 + 16)
    host.detach()
}

@Test @MainActor
func itemsLongerThanTheirEstimateDoNotMoveWhatShows() {
    // Every item is 60 long, twice the estimate.
    let feed = Feed(count: 1000, length: 60)
    let host = host(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    host.layoutIfNeeded()
    let top = feed.stack.subnodes.first { shown($0, in: feed.scroll).map { $0 >= 0 } ?? false }!
    let before = shown(top, in: feed.scroll)!

    // Scrolling up brings items before it in, each 30 longer than the space kept for it.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: feed.scroll.contentOffset.y - 100)
    #expect(shown(top, in: feed.scroll) == before + 100)
    host.layoutIfNeeded()

    #expect(shown(top, in: feed.scroll) == before + 100)
    host.detach()
}

@Test @MainActor
func itemsLaidOutGetTheirOwnLengthAndTheRestKeepTheEstimate() {
    let feed = Feed(count: 100, length: 50)
    let host = host(feed)

    // The first layout took ten estimated items for the window and a screen after it.
    #expect(feed.stack.laidOutItems == 0..<10)
    #expect(feed.stack.subnodes.map(\.frame.size.height) == Array(repeating: 50, count: 10))
    #expect(feed.stack.frame.size.height == 10 * 50 + 90 * 30)
    host.detach()
}

@Test @MainActor
func itemsAddedBeforeTheWindowDoNotMoveWhatShows() {
    let feed = Feed(count: 100)
    let host = host(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 600)
    host.layoutIfNeeded()
    let top = feed.cells[20]
    #expect(shown(top, in: feed.scroll) == 0)

    feed.stack.items.insert(contentsOf: [Entry(id: 1000), Entry(id: 1001)], at: 0)
    host.layoutIfNeeded()

    #expect(shown(top, in: feed.scroll) == 0)
    #expect(feed.scroll.contentOffset.y == 660)
    host.detach()
}

@Test @MainActor
func showingTheStartTheWindowShowsItemsAddedThere() {
    let feed = Feed(count: 100)
    let host = host(feed)

    feed.stack.items.insert(Entry(id: 1000), at: 0)
    host.layoutIfNeeded()

    #expect(feed.scroll.contentOffset.y == 0)
    #expect(shown(feed.cells[1000], in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func aStackBelowAHeaderInTheScrollLaysOutWhatShowsOfIt() {
    // A 400-point header fills the window and more: of the stack, only what is within a
    // screen of the window is laid out, once the stack knows where it is.
    let feed = Feed(count: 1000, header: 400)
    let host = host(feed)
    #expect(feed.stack.frame.origin.y == 400)
    host.setNeedsLayout()
    host.layoutIfNeeded()

    #expect(feed.stack.laidOutItems.isEmpty)
    #expect(feed.stack.frame.size.height == 30 * 1000)

    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 300)
    host.layoutIfNeeded()
    // The window shows the stack's first 50 points; a screen after that is laid out.
    #expect(feed.stack.laidOutItems == 0..<7)
    host.detach()
}

@Test @MainActor
func aScrollingHostLaysTheStackOutOnItsOwnThread() async {
    let feed = Feed(count: 1000)
    let host = host(feed)
    host.solvesInBackground = true

    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    host.layoutIfNeeded()
    // Moves while that layout is solved need no other one: it covers them.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15010)
    #expect(!host.needsLayout)
    await host.layoutFinished()

    #expect(feed.stack.laidOutItems == 495..<510)
    host.detach()
}

@Test @MainActor
func focusMovesThroughTheWholeStack() {
    let feed = Feed(count: 200)
    let host = host(feed)
    host.focus(feed.cells[0].id)

    for _ in 0..<150 {
        guard host.moveFocus(.down) else {
            Issue.record("the focus stopped at \(String(describing: host.focusedNode))")
            break
        }
        host.layoutIfNeeded()
    }

    #expect(host.focusedNode == feed.cells[150].id)
    let shownAt = shown(feed.cells[150], in: feed.scroll)!
    #expect(shownAt >= 0 && shownAt + 30 <= 150)
    host.detach()
}

/// A row of 100-point items in a horizontal scroll.
@MainActor
private final class Strip: Node {
    let cells = NodeCache<Int, Cell> { _ in Cell(.horizontal) }
    lazy var stack = LazyStack<Entry>(.horizontal, estimatedLength: 100) { [cells] entry in
        cells[entry.id].showing(entry)
    }
    lazy var scroll = Scroll(.horizontal, content: stack)

    override init() {
        super.init()
        stack.items = (0..<100).map { Entry(id: $0, length: 100) }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }
}

@Test @MainActor
func aRowRightToLeftStartsAtTheRight() {
    let strip = Strip()
    let host = NodeHost(root: strip, size: LayoutSize(width: 200, height: 40))
    host.direction = .rightToLeft
    host.layoutIfNeeded()

    // Two items show, two more are laid out after them — to the left.
    #expect(strip.stack.laidOutItems == 0..<4)
    #expect(strip.stack.frame.size.width == 100 * 100)
    let first = strip.cells[0]
    #expect(strip.scroll.frame(of: first)?.origin.x == 100)
    #expect(strip.scroll.frame(of: strip.cells[3])?.origin.x == -200)

    strip.scroll.contentOffset = LayoutPoint(x: -5000, y: 0)
    host.layoutIfNeeded()
    // Items 50 and 51 show.
    #expect(strip.scroll.frame(of: strip.cells[50])?.origin.x == -4900)
    #expect(strip.stack.laidOutItems == 48..<54)
    host.detach()
}

/// A vertical scroll of a lazy grid of `count` entries, `lanes` side by side.
@MainActor
private final class Grid: Node {
    let cells = NodeCache<Int, Cell> { _ in Cell() }
    lazy var stack = LazyStack<Entry>(lanes: 3, estimatedLength: 30) { [cells] entry in
        cells[entry.id].showing(entry)
    }
    lazy var scroll = Scroll(.vertical, content: stack)

    init(_ entries: [Entry]) {
        super.init()
        stack.items = entries
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }
}

@Test @MainActor
func aGridLaysOutWholeLinesNearTheWindow() {
    let grid = Grid((0..<1000).map { Entry(id: $0) })
    let host = host(grid, width: 210, height: 150)

    // Ten lines of three: five show, five more after them.
    #expect(grid.stack.laidOutItems == 0..<30)
    #expect(grid.stack.frame.size.height == 334 * 30)
    let fifth = grid.cells[4]
    #expect(fifth.frame == LayoutRect(x: 70, y: 30, width: 70, height: 30))

    grid.scroll.contentOffset = LayoutPoint(x: 0, y: 9000)
    host.layoutIfNeeded()
    // Line 300 is at the top.
    #expect(grid.stack.laidOutItems == 885..<930)
    #expect(shown(grid.cells[900], in: grid.scroll) == 0)
    host.detach()
}

@Test @MainActor
func theLastLineOfAGridKeepsItsItemsAsWideAsTheOthers() {
    let grid = Grid((0..<4).map { Entry(id: $0) })
    grid.stack.spacing = 6
    let host = host(grid, width: 210, height: 150)

    // Three shares of 210 less two gaps of 6.
    #expect(grid.cells[0].frame == LayoutRect(x: 0, y: 0, width: 66, height: 30))
    #expect(grid.cells[2].frame.origin.x == 144)
    #expect(grid.cells[3].frame == LayoutRect(x: 0, y: 36, width: 66, height: 30))
    host.detach()
}

@Test @MainActor
func aGridLineIsAsLongAsItsLongestItem() {
    let grid = Grid([
        Entry(id: 0), Entry(id: 1, length: 60), Entry(id: 2),
        Entry(id: 3), Entry(id: 4), Entry(id: 5),
    ])
    let host = host(grid, width: 210, height: 150)

    #expect(grid.cells[0].frame.size.height == 60)
    #expect(grid.cells[3].frame.origin.y == 60)
    #expect(grid.cells[5].frame.size.height == 30)
    host.detach()
}

@Test @MainActor
func linesLongerThanTheirEstimateDoNotMoveWhatShows() {
    let grid = Grid((0..<3000).map { Entry(id: $0, length: 60) })
    let host = host(grid, width: 210, height: 150)
    grid.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    host.layoutIfNeeded()
    let top = grid.stack.subnodes.first {
        shown($0, in: grid.scroll).map { $0 >= 0 } ?? false
    }!
    let before = shown(top, in: grid.scroll)!

    grid.scroll.contentOffset = LayoutPoint(x: 0, y: grid.scroll.contentOffset.y - 100)
    host.layoutIfNeeded()

    #expect(shown(top, in: grid.scroll) == before + 100)
    host.detach()
}

@Test @MainActor
func changingTheLanesLaysTheGridOutAgain() {
    let grid = Grid((0..<10).map { Entry(id: $0) })
    let host = host(grid, width: 210, height: 150)

    grid.stack.lanes = 2
    host.layoutIfNeeded()

    #expect(grid.cells[1].frame == LayoutRect(x: 105, y: 0, width: 105, height: 30))
    #expect(grid.cells[2].frame.origin.y == 30)
    #expect(grid.cells[9].frame.origin.y == 120)
    host.detach()
}

@Test @MainActor
func aLineOfItemsMeasuredApartTakesTheLongestOfThem() {
    // Item 1 is 60 long, so the first line is; the rest are 30.
    let grid = Grid((0..<3000).map { Entry(id: $0, length: $0 == 1 ? 60 : 30) })
    let host = host(grid, width: 210, height: 150)
    grid.scroll.contentOffset = LayoutPoint(x: 0, y: 9000)
    host.layoutIfNeeded()

    // Two items added at the start move item 0 — measured 60 in its old line — into the
    // first line with them, far from the window.
    grid.stack.items.insert(contentsOf: [Entry(id: 5000), Entry(id: 5001)], at: 0)
    host.layoutIfNeeded()

    // Lines of 60 for [5000, 5001, 0] and [1, 2, 3]; 999 more of 30.
    #expect(grid.stack.frame.size.height == 2 * 60 + 999 * 30)
    host.detach()
}

@Test @MainActor
func moreThanAScreenOfItemsAddedBeforeTheWindowDoNotMoveWhatShows() {
    let feed = Feed(count: 1000)
    let host = host(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 7500)
    host.layoutIfNeeded()
    #expect(shown(feed.cells[250], in: feed.scroll) == 0)

    // 300 points of items, two screens: what showed is past the reach of the old window.
    feed.stack.items.insert(contentsOf: (0..<10).map { Entry(id: 2000 + $0) }, at: 0)
    host.layoutIfNeeded()

    #expect(shown(feed.cells[250], in: feed.scroll) == 0)
    #expect(feed.scroll.contentOffset.y == 7800)
    #expect(feed.stack.laidOutItems == 255..<270)
    host.detach()
}

@Test @MainActor
func moreThanAScreenOfItemsRemovedBeforeTheWindowDoNotMoveWhatShows() {
    let feed = Feed(count: 1000)
    let host = host(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 7500)
    host.layoutIfNeeded()

    feed.stack.items.removeSubrange(100..<120)
    host.layoutIfNeeded()

    #expect(shown(feed.cells[250], in: feed.scroll) == 0)
    #expect(feed.scroll.contentOffset.y == 6900)
    host.detach()
}

@Test @MainActor
func moreThanAScreenOfLinesAddedBeforeTheWindowOfAGridDoNotMoveWhatShows() {
    let feed = Feed(count: 1000)
    feed.stack.lanes = 2
    let host = host(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 3000)
    host.layoutIfNeeded()
    #expect(shown(feed.cells[200], in: feed.scroll) == 0)

    // Ten lines of two.
    feed.stack.items.insert(contentsOf: (0..<20).map { Entry(id: 2000 + $0) }, at: 0)
    host.layoutIfNeeded()

    #expect(shown(feed.cells[200], in: feed.scroll) == 0)
    #expect(feed.scroll.contentOffset.y == 3300)
    host.detach()
}
