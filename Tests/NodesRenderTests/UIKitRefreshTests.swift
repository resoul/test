#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Block: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 300)) }
    }

    @MainActor
    private final class Feed: Node {
        lazy var scroll = Scroll(.vertical, content: Block())

        override init() {
            super.init()
            scroll.refreshIndicator = RefreshSpinner()
            // Never ends while the test looks.
            scroll.onRefresh = { try? await Task.sleep(for: .seconds(60)) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @Test @MainActor
    func aFingerLettingGoFarEnoughRestsWithTheRoomOpen() throws {
        guard UIDevice.current.userInterfaceIdiom != .tv else { return }

        let feed = Feed()
        let view = NodeView(root: feed)
        view.zoom = 2
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        let driver = try #require(view.scrollDriver(for: feed.scroll))
        #expect(driver.contentInset.top == 0)

        // Pulled 70 points past the top, and let go.
        driver.scrollViewWillBeginDragging(UIScrollView())
        feed.scroll.platformDidScroll(to: LayoutPoint(x: 0, y: -70))
        var target = CGPoint(x: 0, y: 0)
        driver.scrollViewWillEndDragging(
            UIScrollView(),
            withVelocity: .zero,
            targetContentOffset: &target
        )

        // The glide ends on the room, 56 points, which the physics now lets it reach.
        #expect(feed.scroll.isRefreshing)
        #expect(target == CGPoint(x: 0, y: -112))
        #expect(driver.contentInset.top == 112)
        view.host.detach()
    }

    @Test @MainActor
    func aDrawingLeavesThePhysicsWhereItPulledTheContent() throws {
        guard UIDevice.current.userInterfaceIdiom != .tv else { return }

        let feed = Feed()
        let view = NodeView(root: feed)
        view.zoom = 2
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        let driver = try #require(view.scrollDriver(for: feed.scroll))

        // The physics pulled the content 40 points past the top, and the tree is drawn
        // again — the refresh indicator redraws as the pull grows — after the finger left
        // and before the bounce back began.
        let pulled = UIScrollView()
        pulled.contentOffset = CGPoint(x: 0, y: -80)
        driver.scrollViewDidScroll(pulled)
        #expect(feed.scroll.overscroll == LayoutPoint(x: 0, y: -40))
        view.host.setNeedsRender()
        view.layoutIfNeeded()

        // The drawing does not set the physics' offset: it would stop its bounce back.
        #expect(driver.physicsOffset == .zero)
        view.host.detach()
    }
#endif
