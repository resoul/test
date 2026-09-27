#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import QuartzCore
    import Testing

    @testable import NodesRender

    @MainActor
    private final class Dot: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 20, height: 20)) }
    }

    @Test @MainActor
    func aSpinningNodeKeepsTurningUntilItStops() throws {
        let dot = Dot()
        let host = NodeHost(root: dot, size: LayoutSize(width: 20, height: 20))
        let renderer = LayerRenderer()
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        dot.appearance.spin = 2
        host.layoutIfNeeded()
        renderer.render(dot, in: CALayer())

        let layer = try #require(renderer.layer(for: dot))
        let turn = try #require(layer.animation(forKey: "spin") as? CABasicAnimation)
        #expect(turn.keyPath == "transform.rotation.z")
        #expect(turn.duration == 0.5)
        #expect(turn.repeatCount == .infinity)
        #expect(turn.isAdditive)

        // Drawn again, it goes on turning; stopped, it stops.
        renderer.render(dot, in: CALayer())
        #expect(layer.animation(forKey: "spin") === turn)
        dot.appearance.spin = 0
        renderer.render(dot, in: CALayer())
        #expect(layer.animation(forKey: "spin") == nil)
    }

    @Test @MainActor
    func theSpinnerGrowsWithThePullAndTurnsWhileRefreshing() {
        let spinner = RefreshSpinner()
        let before = spinner.drawingRevision

        spinner.showRefresh(pull: 0.5, isRefreshing: false)
        #expect(spinner.sweep == 0.375)
        #expect(spinner.drawingRevision != before)
        #expect(spinner.appearance.spin == 0)
        #expect(spinner.accessibility.isElement == false)

        spinner.showRefresh(pull: 1, isRefreshing: true)
        #expect(spinner.sweep == 0.75)
        #expect(spinner.appearance.spin == 1)
        #expect(spinner.accessibility.isElement == true)
    }
#endif
