import LayoutCore
import StateCore
import Testing

@testable import Nodes

@MainActor
private final class Box: Node {
    let size: LayoutSize

    init(_ width: Double, _ height: Double, tappable: Bool = false) {
        size = LayoutSize(width: width, height: height)
        super.init()
        if tappable { onTap = {} }
    }

    override var layoutContent: LeafContent? { .size(size) }
}

@MainActor
private final class Column: Node {
    let top = Box(100, 20)
    let middle = Box(60, 30, tappable: true)
    let bottom = Box(40, 10)
    let showsBottom = State(true)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            top
            middle
            if showsBottom.value { bottom }
        }
        .alignItems(.start)
        .padding(5)
    }
}

@MainActor
private func host(_ root: Node, width: Double = 200, height: Double = 150) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: width, height: height))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func theFramesAreInTheRootsCoordinatesInReadingOrderWithDepthAndKind() {
    let column = Column()
    let host = host(column)

    let frames = host.debugFrames()

    #expect(frames.map(\.id) == [column.id, column.top.id, column.middle.id, column.bottom.id])
    #expect(frames.map(\.depth) == [0, 1, 1, 1])
    #expect(frames[0].frame == LayoutRect(x: 0, y: 0, width: 200, height: 150))
    #expect(frames[1].frame == LayoutRect(x: 5, y: 5, width: 100, height: 20))
    #expect(frames[2].frame == LayoutRect(x: 5, y: 25, width: 60, height: 30))
    #expect(frames[3].frame == LayoutRect(x: 5, y: 55, width: 40, height: 10))
    #expect(frames.map(\.typeName) == ["Column", "Box", "Box", "Box"])
    host.detach()
}

@Test @MainActor
func onlyANodeThatTakesFocusIsInteractive() {
    let column = Column()
    let host = host(column)

    let interactive = host.debugFrames().filter(\.isInteractive).map(\.id)

    #expect(interactive == [column.middle.id])
    host.detach()
}

@Test @MainActor
func aNodeTheLayoutLeftOutAndAHiddenOrTransparentOneAreNotListed() {
    let column = Column()
    let host = host(column)
    column.showsBottom.value = false
    StateUpdates.flush()
    host.layoutIfNeeded()
    column.top.appearance.opacity = 0

    let ids = host.debugFrames().map(\.id)

    #expect(ids == [column.id, column.middle.id])
    host.detach()
}

@MainActor
private final class Rows: Node {
    let rows = (0..<10).map { _ in Box(50, 30) }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for row in rows { row }
        }
        .alignItems(.start)
    }
}

@Test @MainActor
func aScrollMovesTheFramesOfItsContentWhereTheyShow() {
    let rows = Rows()
    let scroll = Scroll(.vertical, content: rows)
    let host = host(scroll, height: 100)
    let before = host.debugFrames().first { $0.id == rows.rows[3].id }

    scroll.contentOffset = LayoutPoint(x: 0, y: 40)
    let after = host.debugFrames().first { $0.id == rows.rows[3].id }

    #expect(before?.frame.origin.y == 90)
    #expect(after?.frame.origin.y == 50)
    host.detach()
}

@Test @MainActor
func theOverlayFlagAsksForARedrawOnlyWhenItChanges() {
    let column = Column()
    let host = host(column)
    host.didRender()
    #expect(!host.needsRender)

    host.showsDebugOverlay = false
    #expect(!host.needsRender, "setting the value it has is not a change")
    host.showsDebugOverlay = true
    #expect(host.needsRender)
    host.detach()
}

// MARK: Distance to the window

@Test @MainActor
func aNodeIsAsFarFromTheWindowAsItsBoxIsOutsideIt() {
    let rows = Rows()
    let scroll = Scroll(.vertical, content: rows)
    let host = host(scroll, width: 100, height: 100)

    // Rows of 30 points: the first three and a third of the fourth are in a 100-point window.
    #expect(rows.rows[0].distanceToScreen == 0)
    #expect(rows.rows[3].distanceToScreen == 0, "partly in the window is in it")
    #expect(rows.rows[4].distanceToScreen == 20, "a row starting 20 points below the window")
    #expect(rows.rows[9].distanceToScreen == 170)

    // The scroll moves what is far near, and what was near far.
    scroll.contentOffset = LayoutPoint(x: 0, y: 200)
    #expect(rows.rows[9].distanceToScreen == 0)
    #expect(rows.rows[0].distanceToScreen == 170, "a row that ended 170 points above the window")
    host.detach()
}

@Test @MainActor
func aNodeThatIsNotInAHostHasNoDistance() {
    let loose = Box(10, 10)

    #expect(loose.distanceToScreen == nil)
}
