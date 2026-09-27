import LayoutCore
import StateCore
import Testing

@testable import Nodes

@MainActor
private final class Block: Node {
    init(label: String) {
        super.init()
        accessibility.label = label
        accessibility.isElement = true
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 100)) }
}

/// Two 100-point squares side by side, in a 200 × 100 window that zooms up to 3.
@MainActor
private final class Photo: Node {
    let left = Block(label: "Left")
    let right = Block(label: "Right")
    lazy var scroll = Scroll(.vertical, content: Pair(left: left, right: right))

    override init() {
        super.init()
        scroll.zoomRange = 1...3
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { scroll }
    }

    final class Pair: Node {
        let left: Block
        let right: Block

        init(left: Block, right: Block) {
            self.left = left
            self.right = right
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                left
                right
            }
        }
    }
}

@MainActor
private func host(_ root: Node) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: 200, height: 100))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func zoomingKeepsThePointAtTheCenterWhereItIs() {
    let photo = Photo()
    let host = host(photo)
    let scroll = photo.scroll

    scroll.zoom(to: 2)

    // The content's point (100, 50), at the window's center, stays there.
    #expect(scroll.zoomScale == 2)
    #expect(scroll.contentOffset == LayoutPoint(x: 100, y: 50))
    #expect(scroll.contentBounds == LayoutRect(x: 0, y: 0, width: 400, height: 200))
    #expect(scroll.offsetRange.highest == LayoutPoint(x: 200, y: 100))
    #expect(scroll.frame(of: photo.right) == LayoutRect(x: 200, y: 0, width: 200, height: 200))
    host.detach()
}

@Test @MainActor
func zoomingAroundAPointKeepsThatOne() {
    let photo = Photo()
    let host = host(photo)

    photo.scroll.zoom(to: 3, around: LayoutPoint(x: 0, y: 0))

    #expect(photo.scroll.contentOffset == LayoutPoint(x: 0, y: 0))
    // Beyond the range: as far as it goes.
    photo.scroll.zoom(to: 10, around: LayoutPoint(x: 0, y: 0))
    #expect(photo.scroll.zoomScale == 3)
    photo.scroll.zoomRange = 1...2
    #expect(photo.scroll.zoomScale == 2)
    host.detach()
}

@Test @MainActor
func aTapOnZoomedContentFindsWhatIsDrawnUnderIt() {
    let photo = Photo()
    let host = host(photo)
    #expect(host.root.hitTest(LayoutPoint(x: 150, y: 50)) === photo.right)

    photo.scroll.zoom(to: 2)

    // Offset (100, 50): the window's (50, 50) is the content's (75, 50), on the left square.
    #expect(host.root.hitTest(LayoutPoint(x: 50, y: 50)) === photo.left)
    #expect(host.root.hitTest(LayoutPoint(x: 150, y: 50)) === photo.right)
    host.detach()
}

@Test @MainActor
func theElementsOfZoomedContentAreWhereTheyAreDrawn() {
    let photo = Photo()
    let host = host(photo)

    photo.scroll.zoom(to: 2)

    let items = host.accessibilityItems()
    #expect(items.map(\.label) == ["Left", "Right"])
    #expect(items[0].frame == LayoutRect(x: -100, y: -50, width: 200, height: 200))
    #expect(items[1].frame == LayoutRect(x: 100, y: -50, width: 200, height: 200))
    host.detach()
}

@Test @MainActor
func thePlatformsPinchZoomsAndMoves() {
    let photo = Photo()
    let host = host(photo)

    photo.scroll.platformDidZoom(to: 1.5, offset: LayoutPoint(x: 10, y: 20))

    #expect(photo.scroll.zoomScale == 1.5)
    #expect(photo.scroll.contentOffset == LayoutPoint(x: 10, y: 20))
    #expect(host.needsRender)
    host.detach()
}

@Test @MainActor
func aZoomInAnimationIsDrawnWithIt() {
    let photo = Photo()
    let host = host(photo)
    host.didRender()

    withAnimation(.easeOut(duration: 0.3)) {
        photo.scroll.zoom(to: 2)
    }

    #expect(host.renderAnimation == .easeOut(duration: 0.3))
    host.detach()
}

@Test @MainActor
func aScrollThatDoesNotZoomMovesAlongItsAxisOnly() {
    let photo = Photo()
    photo.scroll.zoomRange = 1...1
    let host = host(photo)

    #expect(!photo.scroll.isZoomable)
    photo.scroll.zoom(to: 2)
    #expect(photo.scroll.zoomScale == 1)
    #expect(photo.scroll.offsetRange.highest == LayoutPoint(x: 0, y: 0))
    host.detach()
}

private struct Line: Identifiable {
    let id: Int
}

@MainActor
private final class Row: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 200, height: 20)) }
}

@Test @MainActor
func zoomedOutALazyListLaysOutWhatNowShows() {
    let rows = NodeCache<Int, Row> { _ in Row() }
    let stack = LazyStack<Line>(estimatedLength: 20) { rows[$0.id] }
    stack.items = (0..<1000).map { Line(id: $0) }
    let scroll = Scroll(.vertical, content: stack)
    scroll.zoomRange = 0.25...1
    let host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
    host.layoutIfNeeded()
    let before = stack.laidOutItems

    scroll.zoom(to: 0.25, around: .zero)
    host.layoutIfNeeded()

    // A quarter of the size, the window shows four times as many lines: 20 instead of 5.
    #expect(stack.laidOutItems.lowerBound == 0)
    #expect(stack.laidOutItems.upperBound >= 20)
    #expect(stack.laidOutItems.upperBound > before.upperBound)
    host.detach()
}

@MainActor
private final class Wide: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 300, height: 40)) }
}

@Test @MainActor
func aRowFromTheRightZoomsFromWhereItsContentStarts() {
    let scroll = Scroll(.horizontal, content: Wide())
    scroll.zoomRange = 1...2
    let host = NodeHost(root: scroll, size: LayoutSize(width: 100, height: 40))
    host.direction = .rightToLeft
    host.layoutIfNeeded()
    // Laid out from the right, the content starts 200 points left of the window.
    #expect(scroll.contentBounds.origin.x == -200)

    scroll.zoom(to: 2, around: .zero)

    #expect(scroll.contentBounds == LayoutRect(x: -400, y: 0, width: 600, height: 80))
    #expect(scroll.offsetRange.lowest.x == -400)
    host.detach()
}
