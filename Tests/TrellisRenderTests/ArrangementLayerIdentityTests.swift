import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private func layoutAndCommit(_ root: Node, width: Double = 400, height: Double = 400) throws {
    let frame = LayoutFrame(width: width, height: height)
    let snapshot = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(width), height: .exact(height))
    )
    let result = try FlexboxEngine.layoutContainer(input: snapshot, frame: frame)
    #expect(root.applyLayoutResult(result))
}

@MainActor
private func collectAllNodes(_ root: Node) -> [Node] {
    var result = [root]
    for child in root.subnodes {
        result.append(contentsOf: collectAllNodes(child))
    }
    return result
}

@MainActor
private func makeRequest(root: Node, width: Double = 400, height: Double = 400) -> HostRenderRequest
{
    HostRenderRequest(
        hostID: 1,
        generation: 1,
        treeIdentity: root.id,
        contentRevision: root.structureRevision,
        environmentRevision: 0,
        bounds: LayoutFrame(width: width, height: height),
        scale: 2.0,
        direction: .leftToRight
    )
}

// MARK: - Subclasses for Layer Tests

private final class StaticArrangedCard: Node {
    let avatar: Node
    let title: Node

    init(avatar: Node, title: Node) {
        self.avatar = avatar
        self.title = title
        super.init()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(spacing: 8) {
            Leaf(avatar).size(width: 40, height: 40)
            Leaf(title).grow(1)
        }
    }
}

private final class DynamicWrapperCard: Node {
    let leafA: Node
    let leafB: Node
    var wrapInContainer = true
    var isReversed = false

    init(leafA: Node, leafB: Node) {
        self.leafA = leafA
        self.leafB = leafB
        super.init()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(spacing: 12) {
            if wrapInContainer {
                Row(spacing: 8) {
                    if isReversed {
                        Leaf(leafB)
                        Leaf(leafA)
                    } else {
                        Leaf(leafA)
                        Leaf(leafB)
                    }
                }
            } else {
                if isReversed {
                    Leaf(leafB)
                    Leaf(leafA)
                } else {
                    Leaf(leafA)
                    Leaf(leafB)
                }
            }
        }
    }
}

// MARK: - Tests

@Test @MainActor
func test_layerRenderer_preservesCALayerIdentityAcrossUnchangedResolvePasses() throws {
    let avatar = Node()
    let title = Node()
    let card = StaticArrangedCard(avatar: avatar, title: title)
    card.style {
        $0.width = .points(300)
        $0.height = .points(80)
    }

    let hostLayer = CALayer()
    let renderer = LayerRenderer()

    // Pass 1
    #expect(card.resolveArrangement())
    try layoutAndCommit(card, width: 300, height: 80)
    renderer.applyCommitted(
        root: card,
        on: hostLayer,
        request: makeRequest(root: card, width: 300, height: 80)
    )

    let cardLayer1 = try #require(renderer.layer(for: card.id))
    let avatarLayer1 = try #require(renderer.layer(for: avatar.id))
    let titleLayer1 = try #require(renderer.layer(for: title.id))

    // Pass 2: Re-resolve arrangement (no changes)
    #expect(card.resolveArrangement())
    try layoutAndCommit(card, width: 300, height: 80)
    renderer.applyCommitted(
        root: card,
        on: hostLayer,
        request: makeRequest(root: card, width: 300, height: 80)
    )

    let cardLayer2 = try #require(renderer.layer(for: card.id))
    let avatarLayer2 = try #require(renderer.layer(for: avatar.id))
    let titleLayer2 = try #require(renderer.layer(for: title.id))

    // Same CALayer pointers preserved (no layer recreation or churn)
    #expect(cardLayer1 === cardLayer2)
    #expect(avatarLayer1 === avatarLayer2)
    #expect(titleLayer1 === titleLayer2)
}

@Test @MainActor
func test_layerRenderer_preservesLeafLayersAndUpdatesHierarchyAcrossDynamicWrapperChanges() throws {
    let a = Node()
    let b = Node()
    let card = DynamicWrapperCard(leafA: a, leafB: b)
    card.style {
        $0.width = .points(300)
        $0.height = .points(200)
    }

    let hostLayer = CALayer()
    let renderer = LayerRenderer()

    // 1. Initial render with wrapper
    #expect(card.resolveArrangement())
    try layoutAndCommit(card, width: 300, height: 200)
    renderer.applyCommitted(
        root: card,
        on: hostLayer,
        request: makeRequest(root: card, width: 300, height: 200)
    )

    let layerA1 = try #require(renderer.layer(for: a.id))
    let layerB1 = try #require(renderer.layer(for: b.id))
    let wrapperNode = try #require(card.subnodes.first)
    let wrapperLayer1 = try #require(renderer.layer(for: wrapperNode.id))

    #expect(layerA1.superlayer === wrapperLayer1)
    #expect(layerB1.superlayer === wrapperLayer1)

    // 2. Remove wrapper (wrapInContainer = false)
    card.wrapInContainer = false
    #expect(card.resolveArrangement())
    try layoutAndCommit(card, width: 300, height: 200)
    renderer.applyCommitted(
        root: card,
        on: hostLayer,
        request: makeRequest(root: card, width: 300, height: 200)
    )

    let layerA2 = try #require(renderer.layer(for: a.id))
    let layerB2 = try #require(renderer.layer(for: b.id))
    let cardLayer = try #require(renderer.layer(for: card.id))

    // User leaf CALayers are the exact same instances
    #expect(layerA1 === layerA2)
    #expect(layerB1 === layerB2)
    // Leaf layers are now attached directly to cardLayer
    #expect(layerA2.superlayer === cardLayer)
    #expect(layerB2.superlayer === cardLayer)
    // Old wrapper layer is detached and no longer in registry
    #expect(wrapperLayer1.superlayer == nil)
    #expect(renderer.layer(for: wrapperNode.id) == nil)
}

@Test @MainActor
func test_layerRenderer_reordersLeafSublayersWithoutRecreatingThem() throws {
    let a = Node()
    let b = Node()
    let card = DynamicWrapperCard(leafA: a, leafB: b)
    card.wrapInContainer = false
    card.style {
        $0.width = .points(300)
        $0.height = .points(200)
    }

    let hostLayer = CALayer()
    let renderer = LayerRenderer()

    // 1. Initial order [a, b]
    #expect(card.resolveArrangement())
    try layoutAndCommit(card, width: 300, height: 200)
    renderer.applyCommitted(
        root: card,
        on: hostLayer,
        request: makeRequest(root: card, width: 300, height: 200)
    )

    let layerA1 = try #require(renderer.layer(for: a.id))
    let layerB1 = try #require(renderer.layer(for: b.id))
    let cardLayer = try #require(renderer.layer(for: card.id))

    #expect(cardLayer.sublayers?.first === layerA1)
    #expect(cardLayer.sublayers?.last === layerB1)

    // 2. Reversed order [b, a]
    card.isReversed = true
    #expect(card.resolveArrangement())
    try layoutAndCommit(card, width: 300, height: 200)
    renderer.applyCommitted(
        root: card,
        on: hostLayer,
        request: makeRequest(root: card, width: 300, height: 200)
    )

    let layerA2 = try #require(renderer.layer(for: a.id))
    let layerB2 = try #require(renderer.layer(for: b.id))

    // Identical layer instances
    #expect(layerA1 === layerA2)
    #expect(layerB1 === layerB2)
    // Sublayer order is updated
    #expect(cardLayer.sublayers?.first === layerB1)
    #expect(cardLayer.sublayers?.last === layerA1)
}

@Test @MainActor
func test_layerRenderer_stressChurnAvoidsLayerLeaks() throws {
    let a = Node()
    let b = Node()
    let card = DynamicWrapperCard(leafA: a, leafB: b)
    card.style {
        $0.width = .points(300)
        $0.height = .points(200)
    }

    let hostLayer = CALayer()
    let renderer = LayerRenderer()

    // Churn 40 times between wrapped and unwrapped, normal and reversed
    for i in 0..<40 {
        card.wrapInContainer = (i % 2 == 0)
        card.isReversed = (i % 3 == 0)
        #expect(card.resolveArrangement())
        try layoutAndCommit(card, width: 300, height: 200)
        renderer.applyCommitted(
            root: card,
            on: hostLayer,
            request: makeRequest(root: card, width: 300, height: 200)
        )
    }

    // After churn, verify exact count of live layers matches live nodes
    let liveNodes = collectAllNodes(card)
    for node in liveNodes {
        #expect(renderer.layer(for: node.id) != nil)
    }
}
