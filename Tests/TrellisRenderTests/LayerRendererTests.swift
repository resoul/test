import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

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

@Test
@MainActor
func test_layerRenderer_preservesIdentityAndUsesParentLocalGeometryAcrossReparentAndReorder() throws
{
    let root = Node()
    let first = Node()
    let second = Node()
    let moving = Node()
    let leaf = Node()
    root.addSubnode(first)
    root.addSubnode(second)
    first.addSubnode(moving)
    moving.addSubnode(leaf)
    let host = CALayer()
    let external = CALayer()
    host.addSublayer(external)
    let renderer = LayerRenderer()

    commitFrames(
        root,
        [
            (root, LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 300, height: 200)),
            (first, LayoutFrame(origin: LayoutPoint(x: 30, y: 40), width: 100, height: 80)),
            (second, LayoutFrame(origin: LayoutPoint(x: 150, y: 40), width: 100, height: 80)),
            (moving, LayoutFrame(origin: LayoutPoint(x: 50, y: 60), width: 40, height: 30)),
            (leaf, LayoutFrame(origin: LayoutPoint(x: 55, y: 65), width: 10, height: 10)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let rootLayer = try #require(renderer.layer(for: root.id))
    let firstLayer = try #require(renderer.layer(for: first.id))
    let secondLayer = try #require(renderer.layer(for: second.id))
    let movingLayer = try #require(renderer.layer(for: moving.id))
    let leafLayer = try #require(renderer.layer(for: leaf.id))
    #expect(external.superlayer === host)
    #expect(rootLayer.position == CGPoint(x: 160, y: 120))
    #expect(movingLayer.position == CGPoint(x: 40, y: 35))
    #expect(leafLayer.position == CGPoint(x: 10, y: 10))
    #expect(movingLayer.superlayer === firstLayer)

    second.addSubnode(moving)
    root.moveSubnode(from: 0, to: 1)
    commitFrames(
        root,
        [
            (root, LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 300, height: 200)),
            (second, LayoutFrame(origin: LayoutPoint(x: 150, y: 40), width: 100, height: 80)),
            (moving, LayoutFrame(origin: LayoutPoint(x: 170, y: 50), width: 40, height: 30)),
            (leaf, LayoutFrame(origin: LayoutPoint(x: 175, y: 55), width: 10, height: 10)),
            (first, LayoutFrame(origin: LayoutPoint(x: 30, y: 40), width: 100, height: 80)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    #expect(renderer.layer(for: moving.id) === movingLayer)
    #expect(movingLayer.superlayer === secondLayer)
    #expect(rootLayer.sublayers?.first === secondLayer)
    #expect(rootLayer.sublayers?.last === firstLayer)
}

@Test
@MainActor
func test_layerRenderer_appliesVisualStyleScaleAndRemovesOnlyOwnedStaleLayers() throws {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    root.appearance = VisualStyle(
        background: .theme(.accent),
        border: Border(color: ThemeColor(red: 1, green: 0, blue: 0), width: 3),
        cornerRadius: 8,
        shadow: Shadow(
            color: ThemeColor(red: 0, green: 0, blue: 0),
            opacity: 0.5,
            radius: 4,
            offset: LayoutPoint(x: 2, y: 3)
        )
    )
    root.style.visual = LayoutVisualProperties(
        zIndex: 7,
        overflow: .scroll,
        opacity: 0.25,
        transform: LayoutTransform(translationX: 4, translationY: 5)
    )
    let theme = Theme(
        id: "test",
        colors: ThemeColors(
            background: ThemeColor(red: 0, green: 0, blue: 0),
            surface: ThemeColor(red: 0, green: 0, blue: 0),
            primary: ThemeColor(red: 0, green: 0, blue: 0),
            secondary: ThemeColor(red: 0, green: 0, blue: 0),
            accent: ThemeColor(red: 0.2, green: 0.4, blue: 0.6),
            text: ThemeColor(red: 0, green: 0, blue: 0),
            textSecondary: ThemeColor(red: 0, green: 0, blue: 0),
            border: ThemeColor(red: 0, green: 0, blue: 0),
            error: ThemeColor(red: 0, green: 0, blue: 0),
            success: ThemeColor(red: 0, green: 0, blue: 0),
            warning: ThemeColor(red: 0, green: 0, blue: 0)
        )
    )
    root.setEnvironment(ThemeKey.self, to: theme)
    let host = CALayer()
    let external = CALayer()
    host.addSublayer(external)
    let renderer = LayerRenderer()

    commitFrames(
        root,
        [
            (root, LayoutFrame(width: 100, height: 80)),
            (child, LayoutFrame(origin: LayoutPoint(x: 10, y: 10), width: 20, height: 20)),
        ]
    )
    renderer.applyCommitted(root: root, on: host, request: rendererRequest(scale: 2))

    let rootLayer = try #require(renderer.layer(for: root.id))
    #expect(rootLayer.contentsScale == 2)
    #expect(rootLayer.masksToBounds)
    #expect(rootLayer.opacity == 0.25)
    #expect(rootLayer.zPosition == 7)
    #expect(rootLayer.affineTransform().tx == 4)
    #expect(rootLayer.backgroundColor == CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    #expect(rootLayer.borderWidth == 3)
    #expect(rootLayer.cornerRadius == 8)
    #expect(rootLayer.shadowOpacity == 0.5)

    root.appearance.background = .color(ThemeColor(red: 0.9, green: 0.8, blue: 0.7))
    renderer.applyAppearance(of: root)
    #expect(rootLayer.backgroundColor == CGColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1))

    child.removeFromSupernode()
    commitFrames(root, [(root, LayoutFrame(width: 100, height: 80))])
    renderer.applyCommitted(root: root, on: host, request: rendererRequest(scale: 3))

    #expect(rootLayer.contentsScale == 3)
    #expect(renderer.layer(for: child.id) == nil)
    #expect(external.superlayer === host)
}

@Test
@MainActor
func test_layerRenderer_transformPivotMatchesLayoutTransformCenterContract() throws {
    // Defect #30 / D17: what CALayer draws (default anchorPoint 0.5/0.5) and what
    // `LayoutTransform.applying(_:in:)` computes must be the same mapping, corner for corner,
    // under rotation and non-uniform scale — hit-testing relies on the core math.
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let transform = LayoutTransform(
        scaleX: 2,
        scaleY: 0.5,
        rotationRadians: .pi / 3,
        translationX: 7,
        translationY: -3
    )
    child.style.visual = LayoutVisualProperties(transform: transform)
    let host = CALayer()
    let renderer = LayerRenderer()
    let frame = LayoutFrame(origin: LayoutPoint(x: 30, y: 40), width: 100, height: 50)

    commitFrames(root, [(root, LayoutFrame(width: 400, height: 400)), (child, frame)])
    renderer.applyCommitted(root: root, on: host, request: rendererRequest())

    let rootLayer = try #require(renderer.layer(for: root.id))
    let childLayer = try #require(renderer.layer(for: child.id))
    let locals = [
        CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50),
        CGPoint(x: 37, y: 11), CGPoint(x: 50, y: 25),
    ]
    for local in locals {
        let drawn = childLayer.convert(local, to: rootLayer)
        let computed = transform.applying(
            LayoutPoint(x: frame.origin.x + local.x, y: frame.origin.y + local.y),
            in: frame
        )
        #expect(abs(drawn.x - computed.x) < 1e-6, "x at \(local)")
        #expect(abs(drawn.y - computed.y) < 1e-6, "y at \(local)")
    }
}
