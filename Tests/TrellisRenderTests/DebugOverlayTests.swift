import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func makeTree() -> (root: Node, column: Node, leaf: Node) {
    let root = Node()
    let column = Node()
    let leaf = Node()
    root.style.flexDirection = .column
    column.style.width = 120
    column.style.height = 80
    leaf.style.width = 40
    leaf.style.height = 20
    root.addSubnode(column)
    column.addSubnode(leaf)
    return (root, column, leaf)
}

@MainActor
private func overlayOutlines(on host: CALayer) -> [CALayer] {
    (host.sublayers ?? [])
        .filter { $0.name == "trellis.debug-overlay" }
        .flatMap { $0.sublayers ?? [] }
        .filter { $0.name == "trellis.debug-outline" }
}

@Test
@MainActor
func test_debugOverlay_outlinesEveryCommittedFrameWithoutChangingLayout() async throws {
    let (root, column, leaf) = makeTree()
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 160), scale: 2))
    await waitForCommits(bridge, 1)
    let framesBefore = [root, column, leaf].map(\.calculatedFrame)
    let layerFramesBefore = try [root, column, leaf].map {
        try #require(bridge.layer(for: $0.id)).frame
    }

    bridge.isDebugOverlayEnabled = true

    // No new render pass was needed or requested.
    #expect(bridge.committedCount == 1)
    #expect([root, column, leaf].map(\.calculatedFrame) == framesBefore)
    #expect(
        try [root, column, leaf].map { try #require(bridge.layer(for: $0.id)).frame }
            == layerFramesBefore
    )

    // One outline per node, positioned at the node's root-absolute frame, at host scale.
    let outlines = overlayOutlines(on: host)
    #expect(outlines.count == 3)
    #expect(bridge.debugOverlayRenderer.outlinedCount == 3)
    let leafFrame = try #require(leaf.calculatedFrame)
    #expect(
        outlines.contains {
            $0.frame == CGRect(x: leafFrame.origin.x, y: leafFrame.origin.y, width: 40, height: 20)
        }
    )
    #expect(outlines.allSatisfy { $0.contentsScale == 2 })
    #expect(outlines.allSatisfy { ($0.sublayers ?? []).contains { $0 is CATextLayer } })

    // The overlay container is a sibling of the rendered root layer, never inside it.
    let container = try #require(bridge.debugOverlayRenderer.mountedContainer)
    #expect(container.superlayer === host)
    let rootLayer = try #require(bridge.layer(for: root.id))
    #expect(container.zPosition > rootLayer.zPosition)
    #expect((rootLayer.sublayers ?? []).allSatisfy { $0.name != "trellis.debug-overlay" })
}

@Test
@MainActor
func test_debugOverlay_followsCommitsAndRemovesStaleOutlines() async throws {
    let (root, column, leaf) = makeTree()
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 160), scale: 1))
    await waitForCommits(bridge, 1)
    bridge.isDebugOverlayEnabled = true
    #expect(bridge.debugOverlayRenderer.outlinedCount == 3)

    leaf.removeFromSupernode()
    await waitForCommits(bridge, 2)
    #expect(bridge.debugOverlayRenderer.outlinedCount == 2)
    #expect(overlayOutlines(on: host).count == 2)

    column.style.width = 150
    await waitForCommits(bridge, 3)
    let columnFrame = try #require(column.calculatedFrame)
    #expect(columnFrame.width == 150)
    #expect(overlayOutlines(on: host).contains { $0.frame.width == 150 })
}

@Test
@MainActor
func test_debugOverlay_toggleAndDetachLeaveNoLayersBehind() async throws {
    let (root, _, _) = makeTree()
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 160), scale: 1))
    await waitForCommits(bridge, 1)
    let hostSublayersBefore = host.sublayers?.count ?? 0

    bridge.isDebugOverlayEnabled = true
    bridge.isDebugOverlayEnabled = false
    #expect(bridge.debugOverlayRenderer.mountedContainer == nil)
    #expect(overlayOutlines(on: host).isEmpty)
    #expect(host.sublayers?.count ?? 0 == hostSublayersBefore)

    // Re-enabling mounts exactly one container again, with no duplicates.
    bridge.isDebugOverlayEnabled = true
    bridge.isDebugOverlayEnabled = true
    #expect((host.sublayers ?? []).filter { $0.name == "trellis.debug-overlay" }.count == 1)
    #expect(overlayOutlines(on: host).count == 3)

    // Detach removes the overlay with the tree; the setting survives and re-attach restores it.
    bridge.detach()
    #expect(bridge.debugOverlayRenderer.mountedContainer == nil)
    #expect(host.sublayers?.isEmpty ?? true)
    #expect(bridge.isDebugOverlayEnabled)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 160), scale: 1))
    await waitForCommits(bridge, 1)
    #expect(overlayOutlines(on: host).count == 3)
}

@Test
@MainActor
func test_debugOverlay_distinguishesArrangementManagedNodes() async throws {
    final class Card: Node {
        let title = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row { Leaf(title).size(width: 40, height: 20) }
        }
    }
    let root = Node()
    let manual = Node()
    manual.style.width = 30
    manual.style.height = 30
    let card = Card()
    card.style.width = 100
    card.style.height = 50
    root.addSubnode(manual)
    root.addSubnode(card)
    #expect(card.resolveArrangement())

    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 160), scale: 1))
    await waitForCommits(bridge, 1)
    bridge.isDebugOverlayEnabled = true

    let outlines = overlayOutlines(on: host)
    let manualOutline = try #require(outlines.first { $0.frame.width == 30 })
    let titleOutline = try #require(outlines.first { $0.frame.width == 40 })
    let cardOutline = try #require(outlines.first { $0.frame.width == 100 })
    #expect(manualOutline.borderColor != nil)
    #expect(manualOutline.borderColor != titleOutline.borderColor)
    // The owner resolved a root container, so it is arranged too; the manual node is not.
    #expect(cardOutline.borderColor == titleOutline.borderColor)
}
