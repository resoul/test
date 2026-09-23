import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

/// C30: a card with two nested implicit wrappers — `Column { Row { Column { a; b }; c } }` — the shape
/// the experiment is about.
@MainActor
private final class Card: Node {
    let a = Node()
    let b = Node()
    let c = Node()
    init() {
        super.init()
        style.width = 200
        style.height = 100
        appearance.background = .color(ThemeColor(red: 0.1, green: 0.1, blue: 0.1))
        for leaf in [a, b, c] {
            leaf.style.width = 20
            leaf.style.height = 10
        }
    }
    // The root container is the card itself; the two implicit wrappers are the nested
    // `Row` and `Column`.
    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(padding: DirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)) {
            Row(spacing: 4) {
                Column(spacing: 2) {
                    Leaf(a)
                    Leaf(b)
                }
                Leaf(c)
            }
        }
    }
}

@MainActor
private final class Fixture {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let card = Card()
    init(skipWrappers: Bool) {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        bridge.skipsLayoutOnlyWrappers = skipWrappers
        root.style.flexDirection = .column
        root.addSubnode(card)
    }
    func attachAndCommit() async {
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))
        await waitForCommits(1)
    }
    func waitForCommits(_ count: Int) async {
        for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
    }
    var rowWrapper: Node { card.subnodes[0] }
    var columnWrapper: Node { rowWrapper.subnodes[0] }
}

@Test @MainActor
func test_layoutOnlyWrappers_sameGeometryFewerLayersChildrenUnderPaintingAncestor() async throws {
    let with = Fixture(skipWrappers: false)
    let without = Fixture(skipWrappers: true)
    await with.attachAndCommit()
    await without.attachAndCommit()

    // Identical geometry, wrapper or not.
    for (x, y) in [
        (with.card.a, without.card.a), (with.card.b, without.card.b), (with.card.c, without.card.c),
        (with.rowWrapper, without.rowWrapper),
    ] {
        #expect(x.calculatedFrame == y.calculatedFrame)
    }
    #expect(with.card.a.calculatedFrame?.origin == LayoutPoint(x: 6, y: 6))
    #expect(with.card.c.calculatedFrame?.origin == LayoutPoint(x: 30, y: 6))

    // Two wrappers, two fewer layers.
    #expect(with.bridge.materializedLayerCount == 7)
    #expect(without.bridge.materializedLayerCount == 5)
    #expect(without.bridge.layer(for: without.rowWrapper.id) == nil)
    #expect(without.bridge.layer(for: without.columnWrapper.id) == nil)

    // Leaves hang off the card's layer, positioned against the card's frame.
    let cardLayer = try #require(without.bridge.layer(for: without.card.id))
    let aLayer = try #require(without.bridge.layer(for: without.card.a.id))
    let bLayer = try #require(without.bridge.layer(for: without.card.b.id))
    let cLayer = try #require(without.bridge.layer(for: without.card.c.id))
    #expect(
        aLayer.superlayer === cardLayer && bLayer.superlayer === cardLayer
            && cLayer.superlayer === cardLayer
    )
    #expect(aLayer.frame.origin == CGPoint(x: 6, y: 6))
    #expect(bLayer.frame.origin == CGPoint(x: 6, y: 18))
    #expect(cLayer.frame.origin == CGPoint(x: 30, y: 6))
    // Pre-order preserved among the flattened sublayers.
    let ordered = (cardLayer.sublayers ?? []).filter { [aLayer, bLayer, cLayer].contains($0) }
    #expect(ordered.elementsEqual([aLayer, bLayer, cLayer], by: ===))
}

@Test @MainActor
func test_layoutOnlyWrappers_togglingReparentsAtNextCommitAndOverlayStillShowsThem() async throws {
    let f = Fixture(skipWrappers: false)
    await f.attachAndCommit()
    let rowLayer = try #require(f.bridge.layer(for: f.rowWrapper.id))
    let aLayer = try #require(f.bridge.layer(for: f.card.a.id))
    #expect(aLayer.superlayer !== f.bridge.layer(for: f.card.id))

    f.bridge.skipsLayoutOnlyWrappers = true
    f.card.a.style.width = 22  // any commit
    await f.waitForCommits(2)
    #expect(f.bridge.layer(for: f.rowWrapper.id) == nil)
    #expect(rowLayer.superlayer == nil)
    #expect(aLayer.superlayer === f.bridge.layer(for: f.card.id))
    #expect(f.bridge.materializedLayerCount == 5)

    // The logical containers are still visible to diagnostics: the overlay reads frames.
    f.bridge.isDebugOverlayEnabled = true
    #expect(f.bridge.debugOverlayRenderer.outlinedCount == 7)

    f.bridge.skipsLayoutOnlyWrappers = false
    f.card.a.style.width = 24
    await f.waitForCommits(3)
    let newRowLayer = try #require(f.bridge.layer(for: f.rowWrapper.id))
    #expect(aLayer.superlayer !== f.bridge.layer(for: f.card.id))
    #expect(newRowLayer.superlayer === f.bridge.layer(for: f.card.id))
    #expect(f.bridge.materializedLayerCount == 7)
}

@Test @MainActor
func test_layoutOnlyWrappers_groupEffectsKeepALayer() async throws {
    let f = Fixture(skipWrappers: true)
    await f.attachAndCommit()
    #expect(f.bridge.layer(for: f.rowWrapper.id) == nil)

    // Clipping needs a layer; the wrapper materializes even with the experiment on.
    f.rowWrapper.style.visual = LayoutVisualProperties(overflow: .hidden)
    await f.waitForCommits(2)
    let rowLayer = try #require(f.bridge.layer(for: f.rowWrapper.id))
    #expect(rowLayer.masksToBounds)
    let aLayer = try #require(f.bridge.layer(for: f.card.a.id))
    #expect(aLayer.superlayer !== f.bridge.layer(for: f.card.id))

    // So does paint.
    f.rowWrapper.style.visual = LayoutVisualProperties()
    f.columnWrapper.appearance.background = .color(ThemeColor(red: 1, green: 0, blue: 0))
    await f.waitForCommits(3)
    #expect(f.bridge.layer(for: f.rowWrapper.id) == nil)
    #expect(f.bridge.layer(for: f.columnWrapper.id) != nil)
}
