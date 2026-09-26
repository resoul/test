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
    host.setNeedsLayout()
    host.layoutIfNeeded()
    host.solvesInBackground = true
    let passes = host.passes

    // The window still shows items laid out, and nears their end: the next items are laid
    // out on the host's thread.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 80)
    host.layoutIfNeeded()
    #expect(host.passes == passes)
    // Moves while that layout is solved need no other one: it covers them.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 90)
    #expect(!host.needsLayout)
    await host.layoutFinished()

    #expect(host.passes == passes + 1)
    #expect(feed.stack.laidOutItems == 0..<13)
    host.detach()
}

@Test @MainActor
func aWindowMovedPastWhatIsLaidOutIsLaidOutAtOnceThoughTheHostSolvesInTheBackground() {
    let feed = Feed(count: 1000)
    let host = host(feed)
    host.solvesInBackground = true

    // Nothing laid out shows there: waiting for the host's thread would show nothing.
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    host.layoutIfNeeded()

    #expect(feed.stack.laidOutItems == 495..<510)
    #expect(shown(feed.cells[500], in: feed.scroll) == 0)
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

// MARK: - Animated moves

/// A host whose adapter draws frames, counting how many times it was asked to start.
@MainActor
private func framedHost(_ root: Node) -> (NodeHost, asked: () -> Int) {
    let host = host(root)
    var asked = 0
    host.onNeedsFrames = { asked += 1 }
    return (host, { asked })
}

/// Whether the items at both ends of the window of the feed's scroll are mounted where they
/// show, their ids being their indices.
@MainActor
private func windowIsLaidOut(_ feed: Feed, itemLength: Double = 30) -> Bool {
    let top = feed.scroll.contentOffset.y
    let first = Int(top / itemLength)
    let last = min(feed.stack.items.count - 1, Int((top + 150 - 1) / itemLength))
    return [first, last].allSatisfy { index in
        let cell = feed.cells[index]
        return cell.isMounted && feed.scroll.frame(of: cell)?.origin.y == Double(index) * itemLength
    }
}

@Test @MainActor
func anAnimatedFarMoveLaysOutTheContentAllAlongTheWay() {
    let feed = Feed(count: 1000)
    let (host, asked) = framedHost(feed)

    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }
    // Nothing moves until the frames come; the adapter was asked for them once.
    #expect(host.needsFrames)
    #expect(asked() == 1)
    #expect(feed.scroll.contentOffset.y == 0)
    #expect(!host.needsLayout)

    var offsets: [Double] = []
    for frame in 0...20 {
        host.advanceFrames(to: 100 + Double(frame) * 0.05)
        host.layoutIfNeeded()
        offsets.append(feed.scroll.contentOffset.y)
        #expect(windowIsLaidOut(feed), "frame \(frame) at \(feed.scroll.contentOffset.y)")
    }

    #expect(offsets[0] == 0)
    #expect(offsets[10] == 7500)
    #expect(offsets[20] == 15000)
    #expect(!host.needsFrames)
    #expect(asked() == 1)
    #expect(shown(feed.cells[500], in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func aHostSolvingInTheBackgroundLaysOutEachFrameOfAMoveInThatFrame() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    host.solvesInBackground = true

    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }
    for frame in 0...20 {
        host.advanceFrames(to: Double(frame) * 0.05)
        host.layoutIfNeeded()
        #expect(windowIsLaidOut(feed), "frame \(frame) at \(feed.scroll.contentOffset.y)")
    }

    #expect(!host.needsFrames)
    host.detach()
}

@Test @MainActor
func anAnimatedMoveWithinReachIsDrawnWithItsAnimation() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)

    // A screen away: the layout where it ends still has the items where it starts.
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 150)
    }

    #expect(!host.needsFrames)
    #expect(feed.scroll.contentOffset.y == 150)
    #expect(host.renderAnimation == .linear(duration: 1))
    host.detach()
}

@Test @MainActor
func withoutFramesAnAnimatedFarMoveIsDrawnWithItsAnimation() {
    let feed = Feed(count: 1000)
    let host = host(feed)

    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }

    #expect(!host.needsFrames)
    #expect(feed.scroll.contentOffset.y == 15000)
    host.detach()
}

@Test @MainActor
func thePlatformMovingTheScrollStopsAnAnimatedMove() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }
    host.advanceFrames(to: 0)
    host.advanceFrames(to: 0.1)
    host.layoutIfNeeded()
    #expect(feed.scroll.contentOffset.y == 1500)

    // A finger takes the content where the move had it.
    feed.scroll.platformDidScroll(to: LayoutPoint(x: 0, y: 1490))
    host.advanceFrames(to: 0.2)

    #expect(!host.needsFrames)
    #expect(feed.scroll.contentOffset.y == 1490)
    host.detach()
}

@Test @MainActor
func settingTheOffsetWithoutAnimationStopsAnAnimatedMove() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }
    host.advanceFrames(to: 0)
    host.advanceFrames(to: 0.1)

    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 300)
    host.advanceFrames(to: 0.2)

    #expect(!host.needsFrames)
    #expect(feed.scroll.contentOffset.y == 300)
    host.detach()
}

@Test @MainActor
func itemsAddedBeforeTheWindowOnTheWayDoNotChangeWhereTheMoveEnds() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }
    host.advanceFrames(to: 0)
    host.advanceFrames(to: 0.5)
    host.layoutIfNeeded()

    // Ten items before the window: what shows stays, and so does where the move goes.
    feed.stack.items.insert(contentsOf: (0..<10).map { Entry(id: 2000 + $0) }, at: 0)
    host.layoutIfNeeded()
    host.advanceFrames(to: 1)
    host.layoutIfNeeded()

    #expect(feed.scroll.contentOffset.y == 15300)
    #expect(shown(feed.cells[500], in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func aMoveGoesOnFromWhereAShiftPutTheOffset() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    }
    host.advanceFrames(to: 0)
    host.advanceFrames(to: 0.5)
    #expect(feed.scroll.contentOffset.y == 7500)

    // Content changed between the start and the window: the end stays.
    feed.scroll.shiftOffset(by: LayoutPoint(x: 0, y: 100), movesTarget: false)
    host.advanceFrames(to: 0.5)
    #expect(feed.scroll.contentOffset.y == 7600)
    host.advanceFrames(to: 1)

    #expect(feed.scroll.contentOffset.y == 15000)
    host.detach()
}

@Test @MainActor
func anAnimatedMoveBackToTheStartEndsThereThoughTheItemsOnTheWayGrew() {
    // Every item is 45 long, half again its estimate: each one laid out on the way up grows
    // before what shows, and the offset follows to keep what shows in place.
    let feed = Feed(count: 1000, length: 45)
    let (host, _) = framedHost(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 20000)
    host.layoutIfNeeded()

    withAnimation(.easeInOut(duration: 1)) {
        feed.scroll.contentOffset = .zero
    }
    var offsets: [Double] = []
    var frame = 0
    while host.needsFrames, frame < 40 {
        host.advanceFrames(to: Double(frame) * 0.05)
        host.layoutIfNeeded()
        offsets.append(feed.scroll.contentOffset.y)
        frame += 1
    }

    #expect(!host.needsFrames)
    #expect(feed.scroll.contentOffset.y == 0)
    #expect(shown(feed.cells[0], in: feed.scroll) == 0)
    // What shows only ever moves toward the start: the way bends to take the growth in.
    let shownTops = zip(offsets, offsets.dropFirst())
    #expect(shownTops.allSatisfy { $1 <= $0 })
    host.detach()
}

@Test @MainActor
func anAnimatedMoveToTheEndEndsThereThoughTheContentGrewOnTheWay() {
    // Every item is 45 long, half again its estimate: the list grows as the move passes.
    let feed = Feed(count: 1000, length: 45)
    let (host, _) = framedHost(feed)
    withAnimation(.easeInOut(duration: 1)) {
        feed.scroll.contentOffset = feed.scroll.offsetRange.highest
    }
    var frame = 0
    while host.needsFrames, frame < 40 {
        host.advanceFrames(to: Double(frame) * 0.05)
        host.layoutIfNeeded()
        frame += 1
    }

    #expect(!host.needsFrames)
    #expect(feed.scroll.contentOffset == feed.scroll.offsetRange.highest)
    #expect(feed.cells[999].isMounted)
    host.detach()
}

@Test @MainActor
func anAnimatedMoveToTheEndEndsThereThoughItemsCameAfterOnTheWay() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = feed.scroll.offsetRange.highest
    }
    host.advanceFrames(to: 0)
    host.advanceFrames(to: 0.5)
    host.layoutIfNeeded()

    // Messages arrive at the end of a chat while it scrolls down to them.
    feed.stack.items.append(contentsOf: (0..<10).map { Entry(id: 2000 + $0) })
    host.layoutIfNeeded()
    host.advanceFrames(to: 1)
    host.layoutIfNeeded()

    #expect(feed.scroll.contentOffset.y == 1010 * 30 - 150)
    #expect(feed.cells[2009].isMounted)
    host.detach()
}

@Test @MainActor
func anAnimatedMoveToTheEndStaysOnForTheLengthItsLastFrameFound() {
    // Every third item is three times its estimate.
    let feed = Feed(count: 0)
    feed.stack.items = (0..<10_000).map { Entry(id: $0, length: $0 % 3 == 0 ? 90 : 30) }
    let (host, _) = framedHost(feed)
    withAnimation(.easeInOut(duration: 0.8)) {
        feed.scroll.contentOffset = feed.scroll.offsetRange.highest
    }
    var frames = 0
    while host.needsFrames, frames < 100 {
        host.advanceFrames(to: Double(frames) / 60)
        host.layoutIfNeeded()
        frames += 1
    }

    // The frame that got to the end laid out items there longer than thought; the move went
    // on to the end they made.
    #expect(frames > 49)
    #expect(feed.scroll.contentOffset == feed.scroll.offsetRange.highest)
    #expect(feed.cells[9999].isMounted)
    host.detach()
}

// MARK: - Scrolling to an item

@Test @MainActor
func scrollingToAnItemPutsItAtTheWindowsStartThoughTheItemsAroundItWereGuessed() {
    // Every item is 45 long, half again its estimate: where item 500 is was a guess.
    let feed = Feed(count: 1000, length: 45)
    let host = host(feed)

    #expect(feed.stack.scroll(to: 500))
    host.layoutIfNeeded()

    #expect(shown(feed.cells[500], in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func anAnimatedScrollToAFarItemEndsOnItThoughTheItemsOnTheWayGrew() {
    for (from, to) in [(0.0, 700), (40000.0, 20)] {
        let feed = Feed(count: 1000, length: 45)
        let (host, _) = framedHost(feed)
        feed.scroll.contentOffset = LayoutPoint(x: 0, y: from)
        host.layoutIfNeeded()

        withAnimation(.easeInOut(duration: 1)) {
            #expect(feed.stack.scroll(to: to))
        }
        #expect(host.needsFrames)
        var frame = 0
        while host.needsFrames, frame < 40 {
            host.advanceFrames(to: Double(frame) * 0.05)
            host.layoutIfNeeded()
            frame += 1
        }

        #expect(!host.needsFrames)
        #expect(shown(feed.cells[to], in: feed.scroll) == 0, "from \(from) to item \(to)")
        host.detach()
    }
}

@Test @MainActor
func anItemNearTheEndShowsAsFarAsTheScrollGoes() {
    let feed = Feed(count: 1000)
    let host = host(feed)

    #expect(feed.stack.scroll(to: 998))
    host.layoutIfNeeded()

    #expect(feed.scroll.contentOffset == feed.scroll.offsetRange.highest)
    #expect(shown(feed.cells[998], in: feed.scroll) == 90)
    host.detach()
}

@Test @MainActor
func anAnimatedScrollToAnItemNearTheEndEndsWithItsTime() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)

    withAnimation(.linear(duration: 1)) {
        #expect(feed.stack.scroll(to: 998))
    }
    var frames = 0
    while host.needsFrames, frames < 40 {
        host.advanceFrames(to: Double(frames) * 0.05)
        host.layoutIfNeeded()
        frames += 1
    }

    // The item cannot get to the window's start: the move gets to the end on its time, and
    // the frame after finds it still there.
    #expect(frames == 22, "frames \(frames)")
    #expect(feed.scroll.contentOffset == feed.scroll.offsetRange.highest)
    host.detach()
}

@Test @MainActor
func scrollingToAnItemOfAStackBelowAHeaderCountsTheHeader() {
    let feed = Feed(count: 1000, header: 400)
    let host = host(feed)

    #expect(feed.stack.scroll(to: 10))
    host.layoutIfNeeded()

    #expect(feed.scroll.contentOffset.y == 700)
    #expect(shown(feed.cells[10], in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func scrollingToAnItemThatIsNotThereDoesNotMove() {
    let feed = Feed(count: 1000)
    let host = host(feed)
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 300)
    host.layoutIfNeeded()

    #expect(!feed.stack.scroll(to: 5000))
    #expect(feed.scroll.contentOffset.y == 300)
    host.detach()
}

@Test @MainActor
func scrollingToAnItemOfAGridShowsItsLine() {
    let grid = Grid((0..<1000).map { Entry(id: $0, length: $0 % 2 == 0 ? 60 : 30) })
    let host = host(grid, width: 210, height: 150)

    #expect(grid.stack.scroll(to: 301))
    host.layoutIfNeeded()

    // Item 301 is second in line 100: the line starts where the window does.
    #expect(grid.scroll.frame(of: grid.cells[301])?.origin.y == grid.scroll.contentOffset.y)
    #expect(grid.scroll.frame(of: grid.cells[300])?.origin.y == grid.scroll.contentOffset.y)
    host.detach()
}

@Test @MainActor
func scrollingToAnItemOfARowRightToLeftPutsItAtTheRight() {
    let strip = Strip()
    let host = NodeHost(root: strip, size: LayoutSize(width: 200, height: 40))
    host.direction = .rightToLeft
    host.layoutIfNeeded()

    #expect(strip.stack.scroll(to: 50))
    host.layoutIfNeeded()

    #expect(strip.scroll.contentOffset.x == -5000)
    #expect(strip.scroll.frame(of: strip.cells[50])?.origin.x == -4900)
    host.detach()
}

@Test @MainActor
func aMoveToAnEndThatNeverSettlesStopsAFewFramesPastItsTime() {
    let feed = Feed(count: 1000)
    let (host, _) = framedHost(feed)
    withAnimation(.linear(duration: 1)) {
        feed.scroll.contentOffset = feed.scroll.offsetRange.highest
    }
    var frames = 0
    while host.needsFrames, frames < 100 {
        host.advanceFrames(to: Double(frames) * 0.05)
        host.layoutIfNeeded()
        // An item comes on every frame, and the end moves on with it.
        feed.stack.items.append(Entry(id: 2000 + frames))
        host.layoutIfNeeded()
        frames += 1
    }

    // Its time is 21 frames; a few more at most look for the end.
    #expect(frames <= 30, "frames \(frames)")
    host.detach()
}

/// A lazy stack and a 40-point title that sticks to the top of the scroll.
@MainActor
private final class TitledFeed: Node {
    enum Arrangement {
        /// The title, then the stack.
        case titleAbove
        /// The title in a section of its own, 240 points long, then the stack.
        case titleInItsOwnSection
        /// The stack, then the title and 200 points after it.
        case titleBelow
    }

    let cells = NodeCache<Int, Cell> { _ in Cell() }
    let title = Cell().showing(Entry(id: -3, length: 40))
    let filler = Cell().showing(Entry(id: -4, length: 200))
    let arrangement: Arrangement
    lazy var stack = LazyStack<Entry>(estimatedLength: 30) { [cells] entry in
        cells[entry.id].showing(entry)
    }
    lazy var scroll = Scroll(.vertical, content: Body(owner: self))

    init(_ arrangement: Arrangement = .titleAbove, count: Int = 1000) {
        self.arrangement = arrangement
        super.init()
        stack.items = (0..<count).map { Entry(id: $0) }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }

    private final class Body: Node {
        unowned let owner: TitledFeed

        init(owner: TitledFeed) {
            self.owner = owner
        }

        override func layoutSpec() -> LayoutSpec? {
            switch owner.arrangement {
            case .titleAbove:
                return FlexContainer(.column) {
                    owner.title.sticky(top: 0)
                    owner.stack
                }
            case .titleInItsOwnSection:
                return FlexContainer(.column) {
                    FlexContainer(.column) {
                        owner.title.sticky(top: 0)
                        owner.filler
                    }
                    owner.stack
                }
            case .titleBelow:
                return FlexContainer(.column) {
                    owner.stack
                    owner.title.sticky(top: 0)
                    owner.filler
                }
            }
        }
    }
}

@Test @MainActor
func anItemScrolledToShowsBelowATitleStuckToTheTop() {
    let feed = TitledFeed()
    let host = host(feed)

    #expect(feed.stack.scroll(to: 100))
    host.layoutIfNeeded()

    #expect(shown(feed.cells[100], in: feed.scroll) == 40)
    host.detach()
}

@Test @MainActor
func aTitleWhoseSectionScrolledAwayDoesNotMoveTheItem() {
    let feed = TitledFeed(.titleInItsOwnSection)
    let host = host(feed)

    #expect(feed.stack.scroll(to: 100))
    host.layoutIfNeeded()

    #expect(shown(feed.cells[100], in: feed.scroll) == 0)
    host.detach()
}

@Test @MainActor
func aTitleFurtherDownTheWindowDoesNotMoveTheItem() {
    // Three items, then the title: in the window, but not at its top.
    let feed = TitledFeed(.titleBelow, count: 3)
    let host = host(feed)

    #expect(feed.stack.scroll(to: 1))
    host.layoutIfNeeded()

    #expect(shown(feed.cells[1], in: feed.scroll) == 0)
    host.detach()
}

/// A row that scrolls sideways: a 40-point title sticking to the leading edge, then a lazy
/// stack of 100-point items.
@MainActor
private final class TitledStrip: Node {
    let cells = NodeCache<Int, Cell> { _ in Cell(.horizontal) }
    let title = Cell(.horizontal).showing(Entry(id: -3, length: 40))
    lazy var stack = LazyStack<Entry>(.horizontal, estimatedLength: 100) { [cells] entry in
        cells[entry.id].showing(entry)
    }
    lazy var scroll = Scroll(.horizontal, content: Body(owner: self))

    override init() {
        super.init()
        stack.items = (0..<100).map { Entry(id: $0, length: 100) }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }

    private final class Body: Node {
        unowned let owner: TitledStrip

        init(owner: TitledStrip) {
            self.owner = owner
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                owner.title.sticky(leading: 0)
                owner.stack
            }
        }
    }
}

@Test @MainActor
func anItemOfARowScrolledToShowsAfterATitleStuckToTheLeadingEdge() {
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
        let strip = TitledStrip()
        let host = NodeHost(root: strip, size: LayoutSize(width: 200, height: 40))
        host.direction = direction
        host.layoutIfNeeded()

        #expect(strip.stack.scroll(to: 50))
        host.layoutIfNeeded()

        let item = strip.scroll.frame(of: strip.cells[50])!
        let window = strip.scroll.contentOffset.x
        if direction == .leftToRight {
            #expect(item.origin.x - window == 40)
        } else {
            #expect(window + 200 - (item.origin.x + item.size.width) == 40)
        }
        host.detach()
    }
}
