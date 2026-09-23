import CoreGraphics
import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T07 — LayerRenderer's internal raster layer for TextNode (D65): a second CALayer nested
// inside the node's own (outer) layer, sized to the same local bounds, updated only through
// `applyDisplayArtifact(_:for:)`. These tests exercise the layer contract directly against
// `LayerRenderer`; the end-to-end path from a `TextNode` edit through `DisplayScheduler` to a
// committed `DisplayArtifact` is T06's `TextDisplayIntegrationTests`.

@MainActor
private func commitFrames(_ root: Node, _ frames: [(Node, LayoutFrame)]) {
    let result = LayoutResult(
        placements: frames.map { LayoutPlacement(identity: $0.0.id, frame: $0.1) },
        treeIdentity: root.id
    )
    #expect(root.applyLayoutResult(result))
}

@MainActor
private func rendererRequest(scale: Double = 2) -> HostRenderRequest {
    HostRenderRequest(
        hostID: 9,
        generation: 1,
        treeIdentity: NodeIDAllocator.allocate(),
        contentRevision: 0,
        environmentRevision: 0,
        bounds: LayoutFrame(width: 400, height: 400),
        scale: scale,
        direction: .leftToRight
    )
}

/// A tiny, distinguishable `CGImage` for asserting identity (`===`-by-pixel-size) rather than
/// pixel content — the raster's own correctness is CoreText's (T05/T06), not this layer's.
private func fixtureImage(width: Int = 4, height: Int = 3) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func fixtureArtifact(width: Int = 4, height: Int = 3, scale: Double = 2) -> DisplayArtifact
{
    DisplayArtifact(
        image: fixtureImage(width: width, height: height),
        pixelWidth: width,
        pixelHeight: height,
        scale: scale
    )
}

@Test
@MainActor
func test_textNode_getsAnInternalRasterLayerSizedAndPinnedToItsOwnBounds() throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()

    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let outer = try #require(renderer.layer(for: label.id))
    let raster = try #require(renderer.rasterLayer(for: label.id))
    #expect(raster.superlayer === outer)
    #expect(raster.bounds == CGRect(x: 0, y: 0, width: 80, height: 24))
    #expect(raster.position == .zero)
    #expect(raster.anchorPoint == CGPoint(x: 0, y: 0))
    #expect(raster.contentsGravity == .topLeft)
    #expect(raster.masksToBounds)
    #expect(raster.contents == nil)
}

@Test
@MainActor
func test_plainNode_getsNoRasterLayer() throws {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let host = CALayer()
    let renderer = LayerRenderer()

    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (child, LayoutFrame(width: 50, height: 50)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    #expect(renderer.rasterLayer(for: child.id) == nil)
}

@Test
@MainActor
func test_applyDisplayArtifact_setsContentsAndScaleOnTheRasterLayerOnly() throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let artifact = fixtureArtifact(scale: 3)
    renderer.applyDisplayArtifact(artifact, for: label.id)

    let outer = try #require(renderer.layer(for: label.id))
    let raster = try #require(renderer.rasterLayer(for: label.id))
    let contents = try #require(raster.contents)
    #expect((contents as! CGImage) === artifact.image)
    #expect(raster.contentsScale == 3)
    #expect(outer.contents == nil)
}

@Test
@MainActor
func test_applyDisplayArtifact_forAnUnknownNode_isANoOp() {
    let renderer = LayerRenderer()
    // No commit ever happened for this identity — the raster layer was never created.
    renderer.applyDisplayArtifact(fixtureArtifact(), for: NodeIDAllocator.allocate())
    // Nothing to assert beyond "did not crash": there is no layer to inspect.
}

@Test
@MainActor
func test_paintOnlyAppearanceReapply_neverClearsTheRasterBitmap() throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())
    let artifact = fixtureArtifact()
    renderer.applyDisplayArtifact(artifact, for: label.id)

    label.appearance.background = .color(ThemeColor(red: 1, green: 0, blue: 0))
    renderer.applyAppearance(root: root)

    let raster = try #require(renderer.rasterLayer(for: label.id))
    #expect((raster.contents as! CGImage) === artifact.image)
}

@Test
@MainActor
func test_resizeWithoutANewArtifact_updatesRasterBoundsButKeepsTheOldBitmapClippedNotStretched()
    throws
{
    let root = Node()
    let label = TextNode(text: "Hello")
    root.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())
    let artifact = fixtureArtifact()
    renderer.applyDisplayArtifact(artifact, for: label.id)

    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 140, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let raster = try #require(renderer.rasterLayer(for: label.id))
    // Bounds follow the new box immediately...
    #expect(raster.bounds == CGRect(x: 0, y: 0, width: 140, height: 24))
    // ...but the bitmap itself is untouched until a new artifact is applied (D65): no stretch,
    // held at native size and clipped by the gravity/masksToBounds pair set at materialization.
    #expect((raster.contents as! CGImage) === artifact.image)
    #expect(raster.contentsGravity == .topLeft)
    #expect(raster.masksToBounds)
}

@Test
@MainActor
func test_moveWithoutResize_leavesTheRasterLayerBoundsAndBitmapUntouched() throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())
    let artifact = fixtureArtifact()
    renderer.applyDisplayArtifact(artifact, for: label.id)
    let rasterBefore = try #require(renderer.rasterLayer(for: label.id))
    let boundsBefore = rasterBefore.bounds

    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(origin: LayoutPoint(x: 50, y: 40), width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let outer = try #require(renderer.layer(for: label.id))
    let raster = try #require(renderer.rasterLayer(for: label.id))
    #expect(raster === rasterBefore)
    #expect(raster.bounds == boundsBefore)
    #expect(raster.position == .zero)
    #expect((raster.contents as! CGImage) === artifact.image)
    // Only the outer layer moved.
    #expect(outer.position == CGPoint(x: 90, y: 52))
}

@Test
@MainActor
func test_removingTheTextNodeDropsItsRasterLayerToo() throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())
    #expect(renderer.rasterLayer(for: label.id) != nil)

    label.removeFromSupernode()
    commitFrames(root, [(root, LayoutFrame(width: 200, height: 100))])
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    #expect(renderer.layer(for: label.id) == nil)
    #expect(renderer.rasterLayer(for: label.id) == nil)
}

@Test
@MainActor
func test_skipsLayoutOnlyWrappers_stillGivesTheTextNodeItsOwnLayerAndRaster() throws {
    let root = Node()
    let wrapper = Node()
    wrapper.isArrangementWrapper = true
    let label = TextNode(text: "Hello")
    root.addSubnode(wrapper)
    wrapper.addSubnode(label)
    let host = CALayer()
    let renderer = LayerRenderer()
    renderer.skipsLayoutOnlyWrappers = true

    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (wrapper, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    #expect(renderer.layer(for: wrapper.id) == nil)
    let root2 = try #require(renderer.layer(for: root.id))
    let outer = try #require(renderer.layer(for: label.id))
    let raster = try #require(renderer.rasterLayer(for: label.id))
    #expect(raster.superlayer === outer)
    // `wrapper` is flattened (it carries no paint), but `root` itself is not a wrapper and
    // keeps its own layer — `label`'s outer layer parents under `root`'s layer, not `host`
    // directly.
    #expect(outer.superlayer === root2)
}

@Test
@MainActor
func test_siblingReorderNeverMovesTheRasterLayerOutOfItsOwnNode() throws {
    let root = Node()
    let label = TextNode(text: "Hello")
    let other = Node()
    root.addSubnode(label)
    root.addSubnode(other)
    let host = CALayer()
    let renderer = LayerRenderer()
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (label, LayoutFrame(width: 80, height: 24)),
            (other, LayoutFrame(origin: LayoutPoint(x: 0, y: 30), width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())
    let artifact = fixtureArtifact()
    renderer.applyDisplayArtifact(artifact, for: label.id)

    root.moveSubnode(from: 0, to: 1)
    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 200, height: 100)),
            (other, LayoutFrame(origin: LayoutPoint(x: 0, y: 30), width: 80, height: 24)),
            (label, LayoutFrame(width: 80, height: 24)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let outer = try #require(renderer.layer(for: label.id))
    let raster = try #require(renderer.rasterLayer(for: label.id))
    #expect(raster.superlayer === outer)
    #expect((raster.contents as! CGImage) === artifact.image)
    // The reordering happened among `host`'s children (the outer layers), never among the
    // text node's own single raster sublayer.
    #expect(outer.sublayers == [raster])
}
