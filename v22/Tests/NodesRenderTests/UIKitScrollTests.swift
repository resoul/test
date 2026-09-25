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
