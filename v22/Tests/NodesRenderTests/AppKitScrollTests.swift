#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import Testing

    @testable import NodesAppKit

    @MainActor
    private final class Row: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 30)) }
    }

    /// Ten 30-point rows, one under another.
    @MainActor
    private final class List: Node {
        let rows = (0..<10).map { _ in Row() }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for row in rows { row }
            }
        }
    }

    /// A 60-point window onto a list, between two 200-point rows.
    @MainActor
    private final class Nested: Node {
        let inner = Scroll(.vertical, content: List())
        let above = Row()
        let below = Row()

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                above.size(width: 50, height: 200)
                inner.size(width: 200, height: 60)
                below.size(width: 50, height: 200)
            }
        }
    }

    @MainActor
    private final class Page: Node {
        let nested = Nested()
        lazy var outer = Scroll(.vertical, content: nested)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { outer }
        }
    }

    @MainActor
    private func view(of root: Node, zoom: Double = 1) -> NodeNSView {
        let view = NodeNSView(root: root)
        view.zoom = zoom
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layout()
        return view
    }

    @Test @MainActor
    func theWheelMovesTheScrollUnderThePointerAndOnlyItsContentIsRedrawn() throws {
        let list = List()
        let scroll = Scroll(.vertical, content: list)
        let view = view(of: scroll)
        let row = try #require(view.renderedLayer(for: list.rows[0]))
        row.position = CGPoint(x: -1, y: -1)

        #expect(view.scroll(by: LayoutPoint(x: 0, y: 45), at: LayoutPoint(x: 10, y: 10)))
        view.layout()

        #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 45))
        #expect(view.renderedLayer(for: scroll)?.bounds.origin == CGPoint(x: 0, y: 45))
        // Nothing else was drawn: the row is where the test put it.
        #expect(row.position == CGPoint(x: -1, y: -1))
        view.host.detach()
    }

    @Test @MainActor
    func theWheelGoesOnToTheScrollAroundOnceTheInnerOneIsAtItsEnd() {
        let page = Page()
        let view = view(of: page)
        // The inner list starts 200 points down: bring it into view.
        page.outer.contentOffset = LayoutPoint(x: 0, y: 200)
        view.layout()

        // 240 of the inner list's 300 can scroll; the other 60 move the page.
        #expect(view.scroll(by: LayoutPoint(x: 0, y: 300), at: LayoutPoint(x: 10, y: 10)))

        #expect(page.nested.inner.contentOffset == LayoutPoint(x: 0, y: 240))
        #expect(page.outer.contentOffset == LayoutPoint(x: 0, y: 260))
        view.host.detach()
    }

    @Test @MainActor
    func aWheelWithNothingToScrollIsPassedOn() {
        let row = Row()
        let view = view(of: row)

        #expect(!view.scroll(by: LayoutPoint(x: 0, y: 20), at: LayoutPoint(x: 10, y: 10)))
        view.host.detach()
    }

    @Test @MainActor
    func theWheelScrollsByThePointsOnScreenWhenZoomed() {
        let list = List()
        let scroll = Scroll(.vertical, content: list)
        let view = view(of: scroll, zoom: 2)

        view.scroll(by: LayoutPoint(x: 0, y: 40), at: LayoutPoint(x: 10, y: 10))

        #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 20))
        view.host.detach()
    }
#endif
