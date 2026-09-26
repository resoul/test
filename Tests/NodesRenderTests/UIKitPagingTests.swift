#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Block: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 250)) }
    }

    /// A 100-point window onto 250 points.
    @MainActor
    private final class Pager: Node {
        lazy var scroll = Scroll(.vertical, content: Block())

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @Test @MainActor
    func aDragLetGoOnAPagerGlidesToThePageItPicks() throws {
        // On a TV the focus scrolls; there is no drag.
        guard UIDevice.current.userInterfaceIdiom != .tv else { return }

        let pager = Pager()
        pager.scroll.isPaging = true
        let view = NodeView(root: pager)
        view.zoom = 2
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        let driver = try #require(view.scrollDriver(for: pager.scroll))
        #expect(driver.decelerationRate == .fast)

        // Dragged 10 points in and flicked on: the glide ends on the second page, in the
        // view's points.
        driver.scrollViewWillBeginDragging(UIScrollView())
        pager.scroll.platformDidScroll(to: LayoutPoint(x: 0, y: 10))
        var target = CGPoint(x: 0, y: 30)
        driver.scrollViewWillEndDragging(
            UIScrollView(),
            withVelocity: CGPoint(x: 0, y: 1.8),
            targetContentOffset: &target
        )
        #expect(target == CGPoint(x: 0, y: 200))
        view.host.detach()
    }

    @Test @MainActor
    func aScrollThatDoesNotPageGlidesWhereTheFlickTakesIt() throws {
        guard UIDevice.current.userInterfaceIdiom != .tv else { return }

        let pager = Pager()
        let view = NodeView(root: pager)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.layoutIfNeeded()
        let driver = try #require(view.scrollDriver(for: pager.scroll))
        #expect(driver.decelerationRate == .normal)

        driver.scrollViewWillBeginDragging(UIScrollView())
        var target = CGPoint(x: 0, y: 37)
        driver.scrollViewWillEndDragging(
            UIScrollView(),
            withVelocity: CGPoint(x: 0, y: 1.8),
            targetContentOffset: &target
        )
        #expect(target == CGPoint(x: 0, y: 37))
        view.host.detach()
    }
#endif
