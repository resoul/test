import LayoutCore
import Testing

@testable import Nodes

@MainActor
private final class Square: Node {
    init(label: String) {
        super.init()
        accessibility.label = label
        accessibility.isElement = true
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
}

/// A square over another, in a column, the top one moved aside.
@MainActor
private final class Pile: Node {
    let top = Square(label: "Top")
    let under = Square(label: "Under")

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            top
            under
        }
        .alignItems(.start)
    }
}

@Test @MainActor
func aNodeMovedAsideIsFoundWhereItIsDrawn() {
    let pile = Pile()
    let host = NodeHost(root: pile, size: LayoutSize(width: 300, height: 100))
    host.layoutIfNeeded()
    host.didRender()

    pile.top.appearance.offset = LayoutPoint(x: 150, y: 0)

    // Drawn again, not laid out again.
    #expect(host.needsRender)
    #expect(!host.needsLayout)
    #expect(pile.top.frame.origin == LayoutPoint(x: 0, y: 0))
    #expect(host.root.hitTest(LayoutPoint(x: 50, y: 20)) === pile)
    #expect(host.root.hitTest(LayoutPoint(x: 200, y: 20)) === pile.top)
    let items = host.accessibilityItems()
    #expect(items[0].frame == LayoutRect(x: 150, y: 0, width: 100, height: 40))
    #expect(items[1].frame == LayoutRect(x: 0, y: 40, width: 100, height: 40))
    host.detach()
}
