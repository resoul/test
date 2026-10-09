import LayoutCore
import Testing

@testable import Nodes

@MainActor
private final class Icon: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 20, height: 20)) }
}

/// Two icons side by side with a gap between, 30 from the left and 30 from the top.
@MainActor
private final class Toolbar: Node {
    let first = Icon()
    let second = Icon()
    var clips = false

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            first
            second
        }
        .gap(10)
        .padding(30)
        .alignItems(.start)
    }
}

@MainActor
private func host(_ toolbar: Toolbar, direction: LayoutDirection = .leftToRight) -> NodeHost {
    let host = NodeHost(root: toolbar, size: LayoutSize(width: 200, height: 100))
    host.direction = direction
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func aNodeWithoutInsetsAnswersInsideItsBoxOnly() {
    let toolbar = Toolbar()
    let host = host(toolbar)

    #expect(toolbar.first.frame == LayoutRect(x: 30, y: 30, width: 20, height: 20))
    #expect(toolbar.hitTest(LayoutPoint(x: 35, y: 35)) === toolbar.first)
    #expect(toolbar.hitTest(LayoutPoint(x: 25, y: 35)) === toolbar)
    host.detach()
}

@Test @MainActor
func insetsExtendWhereANodeAnswers() {
    let toolbar = Toolbar()
    toolbar.first.hitTestInsets = Edges(top: 12, leading: 12, bottom: 12, trailing: 4)
    let host = host(toolbar)

    #expect(toolbar.hitTest(LayoutPoint(x: 20, y: 35)) === toolbar.first)  // 10 left of the box
    #expect(toolbar.hitTest(LayoutPoint(x: 35, y: 19)) === toolbar.first)  // 11 above it
    #expect(toolbar.hitTest(LayoutPoint(x: 35, y: 61)) === toolbar.first)  // 11 below it
    #expect(toolbar.hitTest(LayoutPoint(x: 17, y: 35)) === toolbar)  // 13 left: past the inset
    #expect(toolbar.hitTest(LayoutPoint(x: 53, y: 35)) === toolbar.first)  // 3 right of the box
    #expect(toolbar.hitTest(LayoutPoint(x: 55, y: 35)) === toolbar)  // 5 right: past the inset
    host.detach()
}

@Test @MainActor
func aMinimumSizeWidensTheAreaAroundTheCenter() {
    let toolbar = Toolbar()
    toolbar.first.minimumHitSize = LayoutSize(width: 44, height: 44)
    let host = host(toolbar)

    // 12 around the 20-point box, which is centered at (40, 40): 18 to 62 on both axes.
    #expect(toolbar.hitTest(LayoutPoint(x: 19, y: 40)) === toolbar.first)
    #expect(toolbar.hitTest(LayoutPoint(x: 40, y: 61)) === toolbar.first)
    #expect(toolbar.hitTest(LayoutPoint(x: 17, y: 40)) === toolbar)
    #expect(toolbar.hitTest(LayoutPoint(x: 40, y: 63)) === toolbar)
    host.detach()
}

@Test @MainActor
func aMinimumSizeNeverNarrowsAnAreaThatIsBigger() {
    let toolbar = Toolbar()
    toolbar.first.minimumHitSize = LayoutSize(width: 10, height: 10)
    let host = host(toolbar)

    #expect(toolbar.hitTest(LayoutPoint(x: 31, y: 31)) === toolbar.first)
    #expect(toolbar.hitTest(LayoutPoint(x: 49, y: 49)) === toolbar.first)
    host.detach()
}

@Test @MainActor
func aNegativeInsetTakesTheEdgeIn() {
    let toolbar = Toolbar()
    toolbar.first.hitTestInsets = Edges(top: 0, leading: -8, bottom: 0, trailing: 0)
    let host = host(toolbar)

    #expect(toolbar.hitTest(LayoutPoint(x: 34, y: 35)) === toolbar)
    #expect(toolbar.hitTest(LayoutPoint(x: 39, y: 35)) === toolbar.first)
    host.detach()
}

@Test @MainActor
func aNodeDrawnLaterWinsWhereTheAreasMeet() {
    let toolbar = Toolbar()
    // The first reaches 20 past its right edge, over the gap and into the second.
    toolbar.first.hitTestInsets = Edges(top: 0, leading: 0, bottom: 0, trailing: 20)
    let host = host(toolbar)

    #expect(toolbar.second.frame.origin.x == 60)
    #expect(toolbar.hitTest(LayoutPoint(x: 55, y: 35)) === toolbar.first)  // in the gap
    #expect(toolbar.hitTest(LayoutPoint(x: 65, y: 35)) === toolbar.second)  // in the second's box
    host.detach()
}

@Test @MainActor
func theAreaFollowsTheDirectionOfTheHost() {
    let toolbar = Toolbar()
    toolbar.first.hitTestInsets = Edges(top: 0, leading: 0, bottom: 0, trailing: 8)
    let host = host(toolbar, direction: .rightToLeft)

    // Right to left puts the first icon at the right, and its trailing edge is the left one.
    let box = toolbar.first.frame
    #expect(box.origin.x > 100)
    let inFront = LayoutPoint(x: box.origin.x - 5, y: 35)
    #expect(toolbar.hitTest(inFront) === toolbar.first)
    let behind = LayoutPoint(x: box.origin.x + box.size.width + 5, y: 35)
    #expect(toolbar.hitTest(behind) === toolbar)
    host.detach()
}

@Test @MainActor
func aClippingAncestorCutsTheAreaAtItsOwnBox() {
    let toolbar = Toolbar()
    toolbar.appearance.clipsContent = true
    toolbar.first.hitTestInsets = Edges(all: 40)
    let host = host(toolbar)

    // 40 past the first icon's left edge is outside the toolbar, which clips.
    #expect(toolbar.hitTest(LayoutPoint(x: -5, y: 35)) == nil)
    #expect(toolbar.hitTest(LayoutPoint(x: 5, y: 35)) === toolbar.first)
    host.detach()
}

@Test @MainActor
func theInsetsAreSetWhereTheNodeIsPlaced() {
    let icon = Icon().hitTestInsets(Edges(all: 6)).minimumHitSize(LayoutSize(width: 44, height: 44))

    #expect(icon.hitTestInsets == Edges(all: 6))
    #expect(icon.minimumHitSize == LayoutSize(width: 44, height: 44))
}

@Test @MainActor
func aTapInTheAreaAroundANodeTapsIt() {
    let toolbar = Toolbar()
    toolbar.first.minimumHitSize = LayoutSize(width: 44, height: 44)
    var taps = 0
    toolbar.first.onTap = { taps += 1 }
    let host = host(toolbar)

    // 4 left of the icon's box: outside it, inside the 44-point area.
    #expect(host.pointerDown(at: LayoutPoint(x: 26, y: 40)))
    host.pointerUp(at: LayoutPoint(x: 26, y: 40))
    #expect(taps == 1)

    // 20 left of it: outside the area, nothing is under the finger.
    #expect(!host.pointerDown(at: LayoutPoint(x: 10, y: 40)))
    host.pointerUp(at: LayoutPoint(x: 10, y: 40))
    #expect(taps == 1)
    host.detach()
}
