#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import NodesRender
    import QuartzCore
    import Testing

    @MainActor
    private final class Block: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 200, height: 100)) }
    }

    @Test @MainActor
    func zoomedContentIsDrawnBiggerFromItsOrigin() throws {
        let block = Block()
        let scroll = Scroll(.vertical, content: block)
        scroll.zoomRange = 1...4
        let host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
        let renderer = LayerRenderer()
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        host.layoutIfNeeded()
        scroll.zoom(to: 2, around: .zero)
        host.layoutIfNeeded()
        renderer.render(scroll, in: CALayer())

        let layer = try #require(renderer.layer(for: block))
        // Its center, (100, 50) as laid out, is drawn at (200, 100), twice as big: its top
        // left corner stays at the content's origin.
        #expect(layer.position == CGPoint(x: 200, y: 100))
        #expect(layer.transform.m11 == 2)
        #expect(layer.transform.m22 == 2)
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 400, height: 200))

        scroll.zoom(to: 1)
        host.layoutIfNeeded()
        renderer.render(scroll, in: CALayer())
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test @MainActor
    func zoomedTextIsDrawnForTheZoomedPixels() throws {
        let text = Text("Zoom", style: TextStyle(size: 14))
        let scroll = Scroll(.vertical, content: text)
        scroll.zoomRange = 1...4
        let host = NodeHost(root: scroll, size: LayoutSize(width: 200, height: 100))
        let renderer = LayerRenderer()
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        host.layoutIfNeeded()
        renderer.render(scroll, in: CALayer(), scale: 2)
        let layer = try #require(renderer.layer(for: text))
        let plain = layer.contents as! CGImage

        scroll.zoom(to: 3)
        host.layoutIfNeeded()
        renderer.render(scroll, in: CALayer(), scale: 2)

        // Three times the pixels each way, and the layer takes them as that many a point.
        let zoomed = layer.contents as! CGImage
        #expect(zoomed.width == plain.width * 3)
        #expect(layer.contentsScale == 6)
    }

    @Test @MainActor
    func aNodeMovedAsideIsDrawnThere() throws {
        let block = Block()
        let host = NodeHost(root: block, size: LayoutSize(width: 200, height: 100))
        let renderer = LayerRenderer()
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        block.appearance.offset = LayoutPoint(x: -30, y: 5)
        host.layoutIfNeeded()
        renderer.render(block, in: CALayer())

        let layer = try #require(renderer.layer(for: block))
        #expect(layer.frame == CGRect(x: -30, y: 5, width: 200, height: 100))
    }
#endif
