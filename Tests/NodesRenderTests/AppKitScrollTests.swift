#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
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

    /// Ten tappable rows: each an accessibility element.
    @MainActor
    private final class Buttons: Node {
        let rows = (0..<10).map { _ in Row() }

        override init() {
            super.init()
            for row in rows {
                row.onTap = {}
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for row in rows { row }
            }
        }
    }

    @Test @MainActor
    func accessibilityElementsStayTheSameWhileTheirFramesFollowTheScroll() throws {
        let scroll = Scroll(.vertical, content: Buttons())
        let view = view(of: scroll)
        let before = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])

        view.scroll(by: LayoutPoint(x: 0, y: 60), at: LayoutPoint(x: 10, y: 10))
        view.layout()

        let after = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(after.count == 10)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        #expect(after[2].accessibilityFrameInParentSpace().minY == 0)
        view.host.detach()
    }

    @Test @MainActor
    func theTrackpadPullsPastTheEndWithResistanceAndItSpringsBack() {
        let scroll = Scroll(.vertical, content: List())
        let view = view(of: scroll)
        let top = LayoutPoint(x: 10, y: 10)

        view.scroll(by: LayoutPoint(x: 0, y: -60), at: top, phase: .began)
        let first = scroll.overscroll.y
        #expect(scroll.contentOffset == .zero)
        #expect(first < 0 && first > -60)
        view.scroll(by: LayoutPoint(x: 0, y: -60), at: top, phase: .touching)
        // Twice the pull shows less than twice as far.
        #expect(scroll.overscroll.y < first && scroll.overscroll.y > 2 * first)

        // Back down: the pull goes first, then the content.
        view.scroll(by: LayoutPoint(x: 0, y: 100), at: top, phase: .touching)
        #expect(scroll.overscroll.y < 0)
        #expect(scroll.contentOffset == .zero)
        view.scroll(by: LayoutPoint(x: 0, y: -100), at: top, phase: .touching)
        view.layout()

        view.scroll(by: .zero, at: top, phase: .released)
        #expect(scroll.overscroll == .zero)
        #expect(view.host.renderAnimation == .spring(response: 0.3, dampingRatio: 1))
        view.host.detach()
    }

    @Test @MainActor
    func theWheelStopsAtTheEnd() {
        let scroll = Scroll(.vertical, content: List())
        let view = view(of: scroll)

        view.scroll(by: LayoutPoint(x: 0, y: -60), at: LayoutPoint(x: 10, y: 10), phase: .wheel)

        #expect(scroll.overscroll == .zero)
        view.host.detach()
    }

    @Test @MainActor
    func aGlideThatReachesTheEndBouncesOnce() {
        let scroll = Scroll(.vertical, content: List())
        let view = view(of: scroll)
        let point = LayoutPoint(x: 10, y: 10)
        view.scroll(by: LayoutPoint(x: 0, y: 150), at: point, phase: .began)
        view.scroll(by: .zero, at: point, phase: .released)

        view.scroll(by: LayoutPoint(x: 0, y: 100), at: point, phase: .gliding)

        #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 200))
        #expect(scroll.overscroll == .zero)
        #expect(view.host.renderAnimation == .spring(response: 0.3, dampingRatio: 1))
        view.scroll(by: LayoutPoint(x: 0, y: 100), at: point, phase: .gliding)
        #expect(scroll.overscroll == .zero)
        view.host.detach()
    }

    private struct Numbered: Identifiable {
        let id: Int
    }

    /// A scroll of a lazy stack of a thousand 30-point rows.
    @MainActor
    private final class Feed: Node {
        var rows: [Int: Row] = [:]
        lazy var stack = LazyStack<Numbered>(estimatedLength: 30) { [unowned self] item in
            if let row = rows[item.id] { return row }

            let row = Row()
            rows[item.id] = row
            return row
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

    /// Whether the Mac's display is awake: a sleeping display gives no frames.
    private let displayIsAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0

    @Test(.enabled(if: displayIsAwake, "a sleeping display gives no frames")) @MainActor
    func anAnimatedFarScrollOfALazyStackMovesWithTheDisplaysFrames() async throws {
        let feed = Feed()
        let view = NodeNSView(root: feed)
        // The display's frames come to a view on a screen.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        // On screen, and not seen.
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // A Mac with no display gives no frames to test.
        guard window.screen != nil else { return }

        view.layoutSubtreeIfNeeded()

        withAnimation(.linear(duration: 0.3)) {
            feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15_000)
        }
        #expect(view.host.needsFrames)

        var between = 0
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while view.host.needsFrames, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            view.layoutSubtreeIfNeeded()
            let top = feed.scroll.contentOffset.y
            if top > 0, top < 15_000 {
                between += 1
                let row = try #require(feed.rows[Int(top / 30)])
                #expect(view.renderedLayer(for: row) != nil)
            }
        }

        #expect(!view.host.needsFrames)
        #expect(between > 1)
        #expect(feed.scroll.contentOffset.y == 15_000)
        view.host.detach()
        window.contentView = nil
    }

    /// A line of text, as long as its text wraps to.
    @MainActor
    private final class Line: Node {
        let label = Text("", style: TextStyle(size: 15))

        func showing(_ number: Int) -> Line {
            let text =
                number % 3 == 0
                ? "Line \(number): a longer line that wraps to more than one line of text here."
                : "Line \(number)"
            if label.text != text {
                label.text = text
            }
            return self
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { label }.padding(4)
        }
    }

    /// Ten thousand lines of text, some longer than the estimate.
    @MainActor
    private final class LongFeed: Node {
        let lines = NodeCache<Int, Line> { _ in Line() }
        lazy var stack = LazyStack<Numbered>(estimatedLength: 26) { [lines] item in
            lines[item.id].showing(item.id)
        }
        lazy var scroll = Scroll(.vertical, content: stack)

        override init() {
            super.init()
            stack.items = (0..<10_000).map { Numbered(id: $0) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @Test @MainActor
    func aFastGlideOverALazyStackSolvedInTheBackgroundNeverShowsItEmpty() async throws {
        let feed = LongFeed()
        let view = NodeNSView(root: feed)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.layout()
        view.host.solvesInBackground = true

        // Half a screen on every frame of a display at 120 Hz, for a second.
        var empty: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<120 {
            view.scroll(by: LayoutPoint(x: 0, y: 300), at: LayoutPoint(x: 10, y: 10))
            view.layout()
            let top = feed.scroll.contentOffset.y
            for probe in [0.0, 300, 599] {
                let shown = feed.stack.subnodes.contains { node in
                    guard let rect = feed.scroll.frame(of: node) else { return false }
                    return rect.origin.y <= top + probe
                        && rect.origin.y + rect.size.height > top + probe
                }
                if !shown {
                    empty.append(top + probe)
                }
            }
            try await clock.sleep(for: .milliseconds(8))
        }

        #expect(empty.isEmpty, "nothing shows at \(empty.prefix(5))")
        #expect(feed.scroll.contentOffset.y > 30_000)
        view.host.detach()
    }
#endif
