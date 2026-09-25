import LayoutCore
import Testing

@testable import Nodes

@MainActor
private final class Box: Node {
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

/// A 20-point header that sticks to the top, over three 30-point rows: 110 points.
@MainActor
private final class Section: Node {
    let header = Box(100, 20, tappable: true)
    let rows = (0..<3).map { _ in Box(100, 30, tappable: true) }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            header.sticky(top: 0)
            for row in rows { row }
        }
    }
}

/// Three sections, one under another.
@MainActor
private final class Sections: Node {
    let sections = (0..<3).map { _ in Section() }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for section in sections { section }
        }
    }
}

/// A 100-point window onto the sections.
@MainActor
private struct Scene {
    let content = Sections()
    let scroll: Scroll
    let host: NodeHost

    init() {
        scroll = Scroll(.vertical, content: content)
        host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
        host.layoutIfNeeded()
    }

    func scroll(to y: Double) {
        scroll.contentOffset = LayoutPoint(x: 0, y: y)
    }

    func header(_ index: Int) -> Node { content.sections[index].header }
}

@Test @MainActor
func aStickyHeaderStaysAtTheTopWhileItsSectionPasses() {
    let scene = Scene()
    defer { scene.host.detach() }

    #expect(scene.header(0).stickyOffset == .zero)
    scene.scroll(to: 50)

    // Laid out at 0, it shows at the window's top, 50 points into the content.
    #expect(scene.header(0).frame.origin.y == 0)
    #expect(scene.header(0).stickyOffset == LayoutPoint(x: 0, y: 50))
    #expect(scene.header(1).stickyOffset == .zero)
}

@Test @MainActor
func theNextSectionPushesTheHeaderOut() {
    let scene = Scene()
    defer { scene.host.detach() }

    scene.scroll(to: 100)
    // The first section ends at 110: its header can go no lower than 90.
    #expect(scene.header(0).stickyOffset == LayoutPoint(x: 0, y: 90))

    scene.scroll(to: 120)
    #expect(scene.header(0).stickyOffset == LayoutPoint(x: 0, y: 90))
    #expect(scene.header(1).stickyOffset == LayoutPoint(x: 0, y: 10))
}

@Test @MainActor
func aStickyHeaderIsOverTheRowsItCovers() {
    let scene = Scene()
    defer { scene.host.detach() }
    scene.scroll(to: 50)

    // 5 points into the window is 55 into the content: the second row, under the header.
    #expect(scene.scroll.hitTest(LayoutPoint(x: 10, y: 5)) === scene.header(0))
    #expect(scene.content.sections[0].subnodesInDrawingOrder.last === scene.header(0))
    let header = scene.host.focusItems().first { $0.node == scene.header(0).id }
    #expect(header?.frame == LayoutRect(x: 0, y: 0, width: 200, height: 20))
}

@Test @MainActor
func aNodeStuckToTheBottomWaitsThereForItsPlace() {
    let rows = Tall()
    let scroll = Scroll(.vertical, content: rows)
    let host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
    host.layoutIfNeeded()
    defer { host.detach() }

    // Laid out at 150, it is held at the window's bottom edge: 80 to 100.
    #expect(rows.footer.stickyOffset == LayoutPoint(x: 0, y: -70))
    scroll.contentOffset = LayoutPoint(x: 0, y: 100)
    #expect(rows.footer.stickyOffset == .zero)
}

/// A footer that sticks to the bottom, after 150 points of rows.
@MainActor
private final class Tall: Node {
    let top = Box(100, 150)
    let footer = Box(100, 20)
    let rest = Box(100, 200)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            top
            footer.sticky(bottom: 0)
            rest
        }
    }
}

@Test @MainActor
func outsideAScrollNothingSticks() {
    let section = Section()
    let host = NodeHost(root: section, size: LayoutSize(width: 200, height: 100))
    host.layoutIfNeeded()
    defer { host.detach() }

    #expect(section.header.sticky != nil)
    #expect(section.header.stickyOffset == .zero)
}

/// A header bounded by the container around it and its rows, not by the whole node.
@MainActor
private final class Grouped: Node {
    let header = Box(100, 20)
    let rows = (0..<2).map { _ in Box(100, 30) }
    let after = Box(100, 300)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            FlexContainer(.column) {
                header.sticky(top: 0)
                for row in rows { row }
            }
            after
        }
    }
}

@Test @MainActor
func aHeaderIsBoundedByTheContainerItIsLaidOutIn() {
    let grouped = Grouped()
    let scroll = Scroll(.vertical, content: grouped)
    let host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
    host.layoutIfNeeded()
    defer { host.detach() }

    scroll.contentOffset = LayoutPoint(x: 0, y: 200)

    // Its container ends at 80: the header stops at 60, not at the node's end.
    #expect(grouped.header.stickyOffset == LayoutPoint(x: 0, y: 60))
}
