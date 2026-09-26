#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @testable import NodesAppKit

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

    /// A title, then a scroll of a thousand 30-point rows, then a 60-point button.
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
            done.onTap = {}
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                title
                scroll
                done.size(width: 200, height: 60)
            }
        }
    }

    /// The screen in a window, so that elements have frames on the screen.
    @MainActor
    private func window(of screen: Screen) -> (NSWindow, NodeNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 210),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = NodeNSView(root: screen)
        view.zoom = 1
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 210)
        view.layout()
        return (window, view)
    }

    /// Where `rect`, in the view's points from its top left, is on the screen.
    @MainActor
    private func onScreen(_ rect: CGRect, in view: NodeNSView) -> CGRect {
        NSAccessibility.screenRect(fromView: view, rect: rect)
    }

    private let scrollToVisible = NSAccessibility.Action(rawValue: "AXScrollToVisible")

    @Test @MainActor
    func aLazyListIsAListOfARowForEachItem() throws {
        let screen = Screen()
        let (window, view) = window(of: screen)
        defer { window.close() }
        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])

        #expect(elements.count == 3)
        #expect(elements[0].accessibilityLabel() == "Row -1")
        #expect(elements[2].accessibilityLabel() == "Row -2")
        let list = try #require(elements[1] as? ListAccessibilityElement)
        #expect(list.accessibilityRole() == .list)
        #expect(list.accessibilityRowCount() == 1000)
        let rows = try #require(list.accessibilityRows() as? [ListRowAccessibilityElement])
        #expect(rows.count == 1000)
        #expect(rows.map { $0.accessibilityIndex() } == Array(0..<1000))
        #expect(rows[0].accessibilityRole() == .row)
        // A row laid out holds its item's elements; one not laid out is empty.
        let first = try #require(rows[0].accessibilityChildren() as? [NSAccessibilityElement])
        #expect(first.map { $0.accessibilityLabel() } == ["Row 0"])
        #expect(rows[999].accessibilityChildren()?.isEmpty == true)
        let visible = list.accessibilityVisibleRows() as? [ListRowAccessibilityElement]
        #expect(visible?.map(\.item) == Array(screen.stack.laidOutItems))
        view.host.detach()
    }

    @Test @MainActor
    func aListGivesItsRowsAFewAtATime() throws {
        let screen = Screen()
        let (window, view) = window(of: screen)
        defer { window.close() }
        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityElement)

        #expect(list.accessibilityArrayAttributeCount(.children) == 1000)
        let some = list.accessibilityArrayAttributeValues(.rows, index: 500, maxCount: 3)
        let rows = try #require(some as? [ListRowAccessibilityElement])
        #expect(rows.map(\.item) == [500, 501, 502])
        #expect(list.accessibilityIndex(ofChild: rows[1]) == 501)
        // Past the end: as many as there are.
        #expect(
            list.accessibilityArrayAttributeValues(.children, index: 998, maxCount: 5).count == 2
        )
        view.host.detach()
    }

    @Test @MainActor
    func elementsAreOnTheScreenWhereTheyShow() throws {
        let screen = Screen()
        let (window, view) = window(of: screen)
        defer { window.close() }
        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityElement)
        let rows = try #require(list.accessibilityRows() as? [ListRowAccessibilityElement])

        // The title at the top, the button under the list's 120 points.
        #expect(
            elements[0].accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 0, width: 200, height: 30), in: view)
        )
        #expect(
            elements[2].accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 150, width: 200, height: 60), in: view)
        )
        #expect(
            list.accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 30, width: 200, height: 120), in: view)
        )
        // The row of item 2 and its element, in the list; item 700, not laid out, where it
        // is expected.
        #expect(
            rows[2].accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 90, width: 200, height: 30), in: view)
        )
        let element = try #require(
            rows[2].accessibilityChildren()?.first as? NSAccessibilityElement
        )
        #expect(
            element.accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 90, width: 200, height: 30), in: view)
        )
        #expect(
            rows[700].accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 21030, width: 200, height: 30), in: view)
        )
        view.host.detach()
    }

    @Test @MainActor
    func voiceOverMovingToARowNotLaidOutLaysItOut() throws {
        let screen = Screen()
        let (window, view) = window(of: screen)
        defer { window.close() }
        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityElement)
        let row = list.row(700)
        #expect(row.accessibilityActionNames() == [scrollToVisible])

        row.accessibilityPerformAction(scrollToVisible)

        #expect(screen.stack.laidOutItems.contains(700))
        // The rows the list left are empty again.
        #expect(list.row(0).accessibilityChildren()?.isEmpty == true)
        let children = try #require(row.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.map { $0.accessibilityLabel() } == ["Row 700"])
        // At the top of the list's window.
        #expect(
            row.accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 30, width: 200, height: 30), in: view)
        )
        #expect(
            children[0].accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 30, width: 200, height: 30), in: view)
        )
        // Drawn there at once, where VoiceOver shows its cursor.
        #expect(
            view.renderedLayer(for: screen.scroll)?.bounds.origin.y
                == CGFloat(screen.scroll.contentOffset.y)
        )
        view.host.detach()
    }

    @Test @MainActor
    func voiceOverMovingToAnElementBelowTheWindowScrollsItIn() throws {
        let screen = Screen()
        let (window, view) = window(of: screen)
        defer { window.close() }
        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let list = try #require(elements[1] as? ListAccessibilityElement)
        // Item 7 is laid out beyond the window's 120 points.
        let element = try #require(
            list.row(7).accessibilityChildren()?.first as? NSAccessibilityElement
        )
        #expect(screen.scroll.contentOffset.y == 0)

        element.accessibilityPerformAction(scrollToVisible)

        #expect(screen.scroll.contentOffset.y > 0)
        let shown = try #require(screen.scroll.frame(of: screen.rows[7]))
        #expect(shown.origin.y + shown.size.height <= screen.scroll.contentOffset.y + 120)
        view.host.detach()
    }

    /// A 300-point header, then the list, in one scroll: the list starts below the window.
    @MainActor
    private final class Below: Node {
        let rows = NodeCache<Int, Row> { _ in Row() }
        let header = Row().showing(-1)
        lazy var stack = LazyStack<Numbered>(estimatedLength: 30) { [rows] item in
            rows[item.id].showing(item.id)
        }
        lazy var scroll = Scroll(.vertical, content: Column(header: header, stack: stack))

        override init() {
            super.init()
            stack.items = (0..<1000).map { Numbered(id: $0) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }

        private final class Column: Node {
            let header: Row
            let stack: LazyStack<Numbered>

            init(header: Row, stack: LazyStack<Numbered>) {
                self.header = header
                self.stack = stack
                super.init()
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) {
                    header.size(width: 200, height: 300)
                    stack
                }
            }
        }
    }

    @Test @MainActor
    func theRowsOfAListBelowTheWindowAreWhereTheListIs() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 150),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let below = Below()
        let view = NodeNSView(root: below)
        view.zoom = 1
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        view.layout()
        // Nothing of the list shows, though its first items are laid out ahead.

        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let list = try #require(elements.last as? ListAccessibilityElement)
        #expect(
            list.accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 300, width: 200, height: 30000), in: view)
        )
        #expect(
            list.row(1).accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 330, width: 200, height: 30), in: view)
        )
        #expect(
            list.row(500).accessibilityFrame()
                == onScreen(CGRect(x: 0, y: 15300, width: 200, height: 30), in: view)
        )
        view.host.detach()
    }

    @Test @MainActor
    func anElementIsPressedThroughTheActionToo() throws {
        let screen = Screen()
        var presses = 0
        screen.done.onTap = { presses += 1 }
        let (window, view) = window(of: screen)
        defer { window.close() }
        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])

        #expect(elements[2].accessibilityActionNames() == [.press, scrollToVisible])
        elements[2].accessibilityPerformAction(.press)

        #expect(presses == 1)
        view.host.detach()
    }
#endif
