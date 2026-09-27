#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @testable import NodesAppKit

    @MainActor
    private final class Block: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 350)) }
    }

    /// A 100-point window onto 350 points, paging.
    @MainActor
    private final class Pager: Node {
        lazy var scroll = Scroll(.vertical, content: Block())

        override init() {
            super.init()
            scroll.isPaging = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @MainActor
    private func view(of pager: Pager) -> NodeNSView {
        let view = NodeNSView(root: pager)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.layout()
        return view
    }

    private let inside = LayoutPoint(x: 50, y: 50)

    /// Fingers down, moving `steps` times by `step` points every `interval` seconds, then up.
    @MainActor
    private func drag(_ view: NodeNSView, by step: Double, steps: Int, interval: Double) {
        view.scroll(by: .zero, at: inside, phase: .began, time: 1)
        for index in 1...steps {
            view.scroll(
                by: LayoutPoint(x: 0, y: step),
                at: inside,
                phase: .touching,
                time: 1 + Double(index) * interval
            )
        }
        view.scroll(by: .zero, at: inside, phase: .released, time: 1 + Double(steps + 1) * interval)
    }

    @Test @MainActor
    func aSwipeOnAPagerGoesOnToTheNextPage() {
        let pager = Pager()
        let view = view(of: pager)

        // 20 points at 1000 points a second.
        drag(view, by: 5, steps: 4, interval: 0.005)

        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        view.host.detach()
    }

    @Test @MainActor
    func aSlowDragGoesToTheNearestPage() {
        for (steps, page) in [(8, 0.0), (12, 100.0)] {
            let pager = Pager()
            let view = view(of: pager)

            // 5 points every tenth of a second: 50 a second.
            drag(view, by: 5, steps: steps, interval: 0.1)

            #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: page), "\(steps * 5) in")
            view.host.detach()
        }
    }

    @Test @MainActor
    func aFlickAtTheEndOfASlowDragTurnsThePage() {
        let pager = Pager()
        let view = view(of: pager)

        // 30 points slowly, then 10 in a hundredth of a second: the speed at the end counts.
        view.scroll(by: .zero, at: inside, phase: .began, time: 1)
        for index in 1...6 {
            view.scroll(
                by: LayoutPoint(x: 0, y: 5),
                at: inside,
                phase: .touching,
                time: 1 + Double(index) * 0.1
            )
        }
        view.scroll(by: LayoutPoint(x: 0, y: 5), at: inside, phase: .touching, time: 1.605)
        view.scroll(by: LayoutPoint(x: 0, y: 5), at: inside, phase: .touching, time: 1.61)
        view.scroll(by: .zero, at: inside, phase: .released, time: 1.615)

        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        view.host.detach()
    }

    @Test @MainActor
    func theGlideAfterASwipeDoesNotMoveThePager() {
        let pager = Pager()
        let view = view(of: pager)
        drag(view, by: 5, steps: 4, interval: 0.005)

        view.scroll(by: LayoutPoint(x: 0, y: 40), at: inside, phase: .gliding, time: 2)
        view.scroll(by: .zero, at: inside, phase: .glideEnded, time: 2.1)

        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        #expect(pager.scroll.overscroll == .zero)
        view.host.detach()
    }

    @Test @MainActor
    func aMouseWheelTurnsAPagerAPageATurn() {
        let pager = Pager()
        let view = view(of: pager)

        view.scroll(by: LayoutPoint(x: 0, y: 10), at: inside, phase: .wheel, time: 1)
        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        // The same turn going on.
        view.scroll(by: LayoutPoint(x: 0, y: 10), at: inside, phase: .wheel, time: 1.1)
        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        // A new turn, and one back.
        view.scroll(by: LayoutPoint(x: 0, y: 10), at: inside, phase: .wheel, time: 2)
        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 200))
        view.scroll(by: LayoutPoint(x: 0, y: -10), at: inside, phase: .wheel, time: 3)
        #expect(pager.scroll.contentOffset == LayoutPoint(x: 0, y: 100))
        view.host.detach()
    }

    /// A 300-point window onto 600 points, refreshing.
    @MainActor
    private final class Feed: Node {
        lazy var scroll = Scroll(.vertical, content: Tall())

        override init() {
            super.init()
            scroll.refreshIndicator = RefreshSpinner()
            scroll.onRefresh = { try? await Task.sleep(for: .seconds(60)) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }

        final class Tall: Node {
            override var layoutContent: LeafContent? {
                .size(LayoutSize(width: 100, height: 600))
            }
        }
    }

    @Test @MainActor
    func fingersLettingGoFarEnoughPastTheTopRefresh() {
        for (pull, refreshes) in [(-200.0, true), (-60.0, false)] {
            let feed = Feed()
            let view = NodeNSView(root: feed)
            view.zoom = 1
            view.frame = CGRect(x: 0, y: 0, width: 100, height: 300)
            view.layout()

            view.scroll(by: .zero, at: inside, phase: .began, time: 1)
            view.scroll(by: LayoutPoint(x: 0, y: pull), at: inside, phase: .touching, time: 1.1)
            view.scroll(by: .zero, at: inside, phase: .released, time: 1.2)

            // The resistance shows 80 of 200 points: past the 56 it takes. 60 show 30.
            #expect(feed.scroll.isRefreshing == refreshes, "\(pull)")
            #expect(feed.scroll.shownOffset.y == (refreshes ? -56 : 0), "\(pull)")
            view.host.detach()
        }
    }
#endif
