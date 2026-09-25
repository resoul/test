#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import NodesRender
    import QuartzCore
    import Testing

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

    /// A 100-point window onto the 300-point list, drawn once.
    @MainActor
    private struct Scene {
        let list = List()
        let scroll: Scroll
        let host: NodeHost
        let renderer = LayerRenderer()
        let container = CALayer()

        init() {
            scroll = Scroll(.vertical, content: list)
            host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
            CATransaction.begin()
            render()
        }

        func close() {
            host.detach()
            CATransaction.commit()
        }

        func render() {
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(scroll, in: container, animation: host.renderAnimation)
            } else {
                renderer.renderScrolls(host.scrolledSinceRender)
            }
            host.didRender()
        }
    }

    @Test @MainActor
    func aScrollsLayerStartsAtItsOffsetAndClipsItsContent() throws {
        let scene = Scene()
        defer { scene.close() }

        scene.scroll.contentOffset = LayoutPoint(x: 0, y: 70)
        scene.render()

        let layer = try #require(scene.renderer.layer(for: scene.scroll))
        #expect(layer.bounds == CGRect(x: 0, y: 70, width: 200, height: 100))
        #expect(layer.masksToBounds)
        // The content's own layer stays where it was laid out.
        #expect(scene.renderer.layer(for: scene.list)?.frame.origin == .zero)
    }

    @Test @MainActor
    func scrollingMovesTheScrollWithoutRedrawingTheTree() throws {
        let scene = Scene()
        defer { scene.close() }
        let row = try #require(scene.renderer.layer(for: scene.list.rows[0]))
        row.position = CGPoint(x: -1, y: -1)

        scene.scroll.contentOffset = LayoutPoint(x: 0, y: 40)
        scene.render()

        let layer = try #require(scene.renderer.layer(for: scene.scroll))
        #expect(layer.bounds.origin == CGPoint(x: 0, y: 40))
        // A drawing of the tree would have put the row back.
        #expect(row.position == CGPoint(x: -1, y: -1))
    }

    @Test @MainActor
    func theIndicatorShowsWhereTheOffsetIsAndFadesAfterAMove() throws {
        let scene = Scene()
        defer { scene.close() }
        let layer = try #require(scene.renderer.layer(for: scene.scroll))
        let indicator = try #require(layer.sublayers?.last)
        #expect(indicator.animation(forKey: "opacity") == nil)

        scene.scroll.contentOffset = LayoutPoint(x: 0, y: 200)
        scene.render()

        // At the end: the bar's bottom is 3 points above the window's, in the layer's
        // coordinates, which start at the offset. A third of the 94-point track, at least 36.
        #expect(indicator.frame.maxY == 297)
        #expect(indicator.frame.height == 36)
        #expect(indicator.frame.maxX == 197)
        #expect(indicator.opacity == 0)
        #expect(indicator.animation(forKey: "opacity") is CAKeyframeAnimation)
    }

    @Test @MainActor
    func anAnimatedScrollMovesFromWhereItWas() throws {
        let scene = Scene()
        defer { scene.close() }

        withAnimation(.linear(duration: 1)) {
            scene.scroll.contentOffset = LayoutPoint(x: 0, y: 100)
        }
        scene.render()

        let layer = try #require(scene.renderer.layer(for: scene.scroll))
        let move = try #require(layer.animation(forKey: "bounds") as? CABasicAnimation)
        #expect(move.fromValue as? CGRect == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(move.toValue as? CGRect == CGRect(x: 0, y: 100, width: 200, height: 100))
    }

    /// A 20-point header sticking to the top, over ten rows.
    @MainActor
    private final class Section: Node {
        let header = Row()
        let rows = (0..<10).map { _ in Row() }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                header.size(height: 20).sticky(top: 0)
                for row in rows { row }
            }
        }
    }

    @Test @MainActor
    func aStickyNodesLayerFollowsTheScrollOverTheOthers() throws {
        let section = Section()
        let scroll = Scroll(.vertical, content: section)
        let host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
        let renderer = LayerRenderer()
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        host.layoutIfNeeded()
        renderer.render(scroll, in: CALayer())
        host.didRender()

        scroll.contentOffset = LayoutPoint(x: 0, y: 70)
        renderer.renderScrolls(host.scrolledSinceRender)

        let header = try #require(renderer.layer(for: section.header))
        #expect(header.frame == CGRect(x: 0, y: 70, width: 200, height: 20))
        #expect(renderer.layer(for: section)?.sublayers?.last === header)
    }
#endif
