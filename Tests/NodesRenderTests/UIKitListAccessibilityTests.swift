#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing
    import UIKit

    @testable import NodesUIKit

    private struct Numbered: Identifiable {
        let id: Int
    }

    /// A row that reads its number.
    @MainActor
    private final class Row: Node {
        func showing(_ number: Int) -> Row {
            accessibility.label = "Row \(number)"
            return self
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 30)) }
    }

    /// A title, then a scroll of a thousand 30-point rows, then a button.
    @MainActor
    private final class Screen: Node {
        let rows = NodeCache<Int, Row> { _ in Row() }
        let title = Row().showing(-1)
        let done = Row().showing(-2)
        lazy var stack = LazyStack<Numbered>(estimatedLength: 30) { [rows] item in
            rows[item.id].showing(item.id)
        }
        lazy var scroll = Scroll(.vertical, content: stack)

        override init() {
            super.init()
            stack.items = (0..<1000).map { Numbered(id: $0) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                title
                scroll
                done
            }
        }
    }

    @MainActor
    private func view(of screen: Screen) -> NodeView {
        let view = NodeView(root: screen)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 210)
        view.layoutIfNeeded()
        return view
    }

    @Test @MainActor
    func aLazyListIsAListContainerOfAllItsItems() throws {
        let screen = Screen()
        let view = view(of: screen)
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])

        #expect(elements.count == 3)
        #expect(elements[0].accessibilityLabel == "Row -1")
        #expect(elements[2].accessibilityLabel == "Row -2")
        let list = try #require(elements[1] as? ListAccessibilityContainer)
        #expect(list.accessibilityContainerType == .list)
        #expect(!list.isAccessibilityElement)
        #expect(
            list.accessibilityFrameInContainerSpace == CGRect(x: 0, y: 30, width: 200, height: 150)
        )
        // One element for each of the thousand items.
        #expect(list.accessibilityElementCount() == 1000)
        let first = try #require(list.accessibilityElement(at: 0) as? UIAccessibilityElement)
        #expect(first.accessibilityLabel == "Row 0")
        #expect(list.index(ofAccessibilityElement: first) == 0)
        #expect(list.accessibilityElement(at: 1000) == nil)
        view.host.detach()
    }

    @Test @MainActor
    func anItemNotLaidOutStandsInWhereItIsExpected() throws {
        let screen = Screen()
        let view = view(of: screen)
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityContainer)

        let standIn = try #require(list.accessibilityElement(at: 700) as? ListItemStandIn)
        #expect(standIn.item == 700)
        #expect(standIn.isAccessibilityElement)
        #expect(list.index(ofAccessibilityElement: standIn) == 700)
        // In the list's coordinates: 700 rows of 30 points down from its top.
        #expect(standIn.accessibilityFrameInContainerSpace.minY == 21_000)
        #expect(list.accessibilityElement(at: 700) as AnyObject === standIn)
        view.host.detach()
    }

    @Test @MainActor
    func voiceOverMovingToAnItemNotLaidOutLaysItOut() throws {
        let screen = Screen()
        let view = view(of: screen)
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityContainer)
        let standIn = try #require(list.accessibilityElement(at: 700) as? ListItemStandIn)

        standIn.accessibilityElementDidBecomeFocused()

        #expect(screen.stack.laidOutItems.contains(700))
        #expect(screen.scroll.contentOffset.y == 21_000)
        let now = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        #expect(now[1] === list)
        let element = try #require(list.accessibilityElement(at: 700) as? UIAccessibilityElement)
        #expect(element.accessibilityLabel == "Row 700")
        #expect(!(element is ListItemStandIn))
        #expect(list.index(ofAccessibilityElement: element) == 700)
        // Its frame is in the list's coordinates: at the top of the window.
        #expect(element.accessibilityFrameInContainerSpace.minY == 0)
        // Before and after the items laid out, the others still stand in.
        #expect(list.accessibilityElement(at: 0) is ListItemStandIn)
        #expect(list.accessibilityElement(at: 999) is ListItemStandIn)
        #expect(list.accessibilityElementCount() == 1000)
        view.host.detach()
    }

    @Test @MainActor
    func theElementsOfAListAreInsideIt() throws {
        let screen = Screen()
        let view = view(of: screen)
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityContainer)
        let row = try #require(list.accessibilityElement(at: 2) as? UIAccessibilityElement)

        #expect(row.accessibilityContainer as AnyObject === list)
        // Row 2 is 60 points into the list, in the list's coordinates; the list is 30 points
        // down the view. Screen frames follow from these where the view is on a screen.
        #expect(
            row.accessibilityFrameInContainerSpace == CGRect(x: 0, y: 60, width: 200, height: 30)
        )
        #expect(list.accessibilityContainer as AnyObject === view)
        view.host.detach()
    }
    /// A row of two elements: its name and a button.
    @MainActor
    private final class PairRow: Node {
        let name = Row()
        let button = Row()

        func showing(_ number: Int) -> PairRow {
            _ = name.showing(number)
            button.accessibility.label = "Open \(number)"
            button.onTap = {}
            return self
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                name
                button
            }
        }
    }

    /// A scroll of a thousand rows of two elements each.
    @MainActor
    private final class PairScreen: Node {
        let rows = NodeCache<Int, PairRow> { _ in PairRow() }
        lazy var stack = LazyStack<Numbered>(estimatedLength: 30) { [rows] item in
            rows[item.id].showing(item.id)
        }
        lazy var scroll = Scroll(.vertical, content: stack)

        override init() {
            super.init()
            stack.items = (0..<1000).map { Numbered(id: $0) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @Test @MainActor
    func itemsOfSeveralElementsCountEachOfThem() throws {
        let screen = PairScreen()
        let view = NodeView(root: screen)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        view.layoutIfNeeded()
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        let list = try #require(elements.first as? ListAccessibilityContainer)

        // Items before those laid out stand in one each, those laid out give two elements
        // each, and the ones after stand in one each again.
        let laidOut = screen.stack.laidOutItems
        let first = laidOut.lowerBound
        let past = first + 2 * laidOut.count
        let count = past + (1000 - laidOut.upperBound)
        #expect(list.accessibilityElementCount() == count)
        let name = try #require(list.accessibilityElement(at: first) as? UIAccessibilityElement)
        let button = try #require(
            list.accessibilityElement(at: first + 1) as? UIAccessibilityElement
        )
        #expect(name.accessibilityLabel == "Row \(laidOut.lowerBound)")
        #expect(button.accessibilityLabel == "Open \(laidOut.lowerBound)")
        let after = try #require(list.accessibilityElement(at: past) as? ListItemStandIn)
        #expect(after.item == laidOut.upperBound)
        #expect(list.index(ofAccessibilityElement: after) == past)
        let last = try #require(list.accessibilityElement(at: count - 1) as? ListItemStandIn)
        #expect(last.item == 999)

        // Item 700 stands 700 - upperBound places after the first one past those laid out.
        let far = past + 700 - laidOut.upperBound
        let standIn = try #require(list.accessibilityElement(at: far) as? ListItemStandIn)
        #expect(standIn.item == 700)
        standIn.accessibilityElementDidBecomeFocused()
        #expect(screen.stack.laidOutItems.contains(700))
        view.host.detach()
    }
#endif
