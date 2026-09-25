#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesUIKit
    import Testing
    import UIKit

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

    /// A 20-point bar over a scroll of the list.
    @MainActor
    private final class Screen: Node {
        let bar = Row()
        let list = List()
        lazy var scroll = Scroll(.vertical, content: list)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                bar.size(width: 50, height: 20)
                scroll
            }
        }
    }

    /// A 200 × 120 view of the screen, laid out: the scroll gets the 100 points under the bar.
    @MainActor
    private func view(of screen: Screen) -> NodeView {
        let view = NodeView(root: screen)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        view.layoutIfNeeded()
        return view
    }

    @MainActor
    private func physics(in view: NodeView) -> UIScrollView? {
        view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    @Test @MainActor
    func aScrollGetsThePlatformsScrollingOverItsFrame() throws {
        let screen = Screen()
        let view = view(of: screen)
        guard view.traitCollection.userInterfaceIdiom != .tv else { return }

        let physics = try #require(physics(in: view))
        #expect(physics.frame == CGRect(x: 0, y: 20, width: 200, height: 100))
        #expect(physics.contentSize == CGSize(width: 200, height: 300))
        #expect(view.gestureRecognizers?.contains { $0 === physics.panGestureRecognizer } == true)
        // Touches over it come to the node view, so taps reach the nodes.
        #expect(view.hitTest(CGPoint(x: 10, y: 60), with: nil) === view)
        view.host.detach()
    }

    @Test @MainActor
    func thePlatformsScrollingMovesTheScrollAndItsLayer() throws {
        let screen = Screen()
        let view = view(of: screen)
        guard view.traitCollection.userInterfaceIdiom != .tv else { return }

        let physics = try #require(physics(in: view))
        physics.contentOffset = CGPoint(x: 0, y: 80)
        view.layoutIfNeeded()

        #expect(screen.scroll.contentOffset == LayoutPoint(x: 0, y: 80))
        #expect(view.renderedLayer(for: screen.scroll)?.bounds.origin == CGPoint(x: 0, y: 80))
        view.host.detach()
    }

    @Test @MainActor
    func pastTheEndTheContentBouncesWithoutChangingTheOffset() throws {
        let screen = Screen()
        let view = view(of: screen)
        guard view.traitCollection.userInterfaceIdiom != .tv else { return }

        let physics = try #require(physics(in: view))
        physics.contentOffset = CGPoint(x: 0, y: -30)
        view.layoutIfNeeded()

        #expect(screen.scroll.contentOffset == .zero)
        #expect(screen.scroll.overscroll == LayoutPoint(x: 0, y: -30))
        #expect(view.renderedLayer(for: screen.scroll)?.bounds.origin == CGPoint(x: 0, y: -30))
        view.host.detach()
    }

    @Test @MainActor
    func theScrollingFollowsAScrollMovedByCode() throws {
        let screen = Screen()
        let view = view(of: screen)
        guard view.traitCollection.userInterfaceIdiom != .tv else { return }

        screen.scroll.contentOffset = LayoutPoint(x: 0, y: 150)
        view.layoutIfNeeded()

        let physics = try #require(physics(in: view))
        #expect(physics.contentOffset == CGPoint(x: 0, y: 150))
        view.host.detach()
    }

    @Test @MainActor
    func onATVTheFocusScrollsNotTheTouchSurface() {
        let screen = Screen()
        let view = view(of: screen)
        guard view.traitCollection.userInterfaceIdiom == .tv else { return }

        #expect(physics(in: view) == nil)
        view.host.detach()
    }
#endif

#if canImport(UIKit)
    /// A tappable, so focusable, row.
    @MainActor
    private final class Item: Node {
        override init() {
            super.init()
            onTap = {}
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 30)) }
    }

    @MainActor
    private final class Items: Node {
        let items = (0..<10).map { _ in Item() }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for item in items { item }
            }
        }
    }

    @Test @MainActor
    func theFocusSystemSearchesAScrollsWholeContentAndScrollsIt() throws {
        let items = Items()
        let scroll = Scroll(.vertical, content: items)
        let view = NodeView(root: scroll)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutIfNeeded()
        guard
            view.traitCollection.userInterfaceIdiom == .tv
                || view.traitCollection.userInterfaceIdiom == .pad
        else { return }

        let top = view.focusItems(in: view.bounds)
        // The scroll's own container, and not the empty scroll view giving its physics.
        #expect(top.count == 1)
        let container = try #require(
            top.compactMap { $0.focusItemContainer as? any UIFocusItemScrollableContainer }.first
        )
        #expect(container.contentSize == CGSize(width: 200, height: 300))
        #expect(container.visibleSize == CGSize(width: 200, height: 100))
        // The last row, far below what shows, is found in the content.
        let inside = container.focusItems(in: CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(inside.count == 10)
        #expect(inside.contains { $0.frame == CGRect(x: 0, y: 270, width: 200, height: 30) })

        container.contentOffset = CGPoint(x: 0, y: 150)
        #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 150))
        view.host.detach()
    }
#endif

#if canImport(UIKit)
    @MainActor
    private func itemsView() -> (NodeView, Scroll) {
        let scroll = Scroll(.vertical, content: Items())
        let view = NodeView(root: scroll)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutIfNeeded()
        return (view, scroll)
    }

    @Test @MainActor
    func accessibilityElementsStayTheSameWhileTheirFramesFollowTheScroll() throws {
        let (view, scroll) = itemsView()
        let before = try #require(view.accessibilityElements as? [UIAccessibilityElement])

        scroll.contentOffset = LayoutPoint(x: 0, y: 60)
        view.layoutIfNeeded()

        let after = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        #expect(after.count == 10)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        #expect(after[2].accessibilityFrameInContainerSpace.minY == 0)
        view.host.detach()
    }

    @Test @MainActor
    func threeFingersTurnAPageOfTheScrollAroundTheElement() throws {
        let (view, scroll) = itemsView()
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])

        #expect(elements[0].accessibilityScroll(.up))
        #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        #expect(!elements[0].accessibilityScroll(.left))
        #expect(elements[0].accessibilityScroll(.previous))
        #expect(scroll.contentOffset == .zero)
        view.host.detach()
    }

    @Test @MainActor
    func voiceOverMovingToAnElementOutOfSightScrollsToIt() throws {
        let (view, scroll) = itemsView()
        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])

        elements[9].accessibilityElementDidBecomeFocused()

        #expect(scroll.contentOffset == LayoutPoint(x: 0, y: 200))
        view.host.detach()
    }
#endif
