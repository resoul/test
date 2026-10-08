import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private func waitForBridgeCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@Test
@MainActor
func test_nodeHostBridge_runsNodeToCALayerPathWithInitialHostState() async throws {
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
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)

    #expect(
        bridge.attach(
            root: root,
            bounds: LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 200, height: 160),
            scale: 2,
            safeAreaInsets: DirectionalEdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 0),
            layoutDirection: .rightToLeft
        )
    )
    await waitForBridgeCommits(bridge, 1)

    let rootLayer = try #require(bridge.layer(for: root.id))
    let columnLayer = try #require(bridge.layer(for: column.id))
    let leafLayer = try #require(bridge.layer(for: leaf.id))
    #expect(
        root.calculatedFrame
            == LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 200, height: 160)
    )
    #expect(root.environment.layoutDirection == .rightToLeft)
    #expect(root.environment.safeAreaInsets.top == 8)
    #expect(rootLayer.superlayer === host)
    #expect(columnLayer.superlayer === rootLayer)
    #expect(leafLayer.superlayer === columnLayer)
    #expect(rootLayer.contentsScale == 2)

    bridge.updateSafeArea(DirectionalEdgeInsets(top: 12, leading: 6, bottom: 0, trailing: 0))
    bridge.updateLayoutDirection(.leftToRight)
    await waitForBridgeCommits(bridge, 2)
    #expect(bridge.committedCount == 2)
    #expect(root.environment.layoutDirection == .leftToRight)
    #expect(root.environment.safeAreaInsets.top == 12)
}

@Test
@MainActor
func test_nodeHostBridge_rejectsSecondOwnerAndSupportsReplacementDetachAndReattach() async {
    let firstHost = CALayer()
    let secondHost = CALayer()
    let root = Node()
    let replacement = Node()
    let first = NodeHostBridge(hostLayer: firstHost)
    let second = NodeHostBridge(hostLayer: secondHost)

    #expect(first.attach(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    await waitForBridgeCommits(first, 1)
    #expect(!second.attach(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    #expect(second.mountedRoot == nil)
    #expect(first.mountedRoot === root)

    #expect(first.attach(root: replacement, bounds: LayoutFrame(width: 150, height: 100), scale: 1))
    await waitForBridgeCommits(first, 1)
    #expect(first.layer(for: root.id) == nil)
    #expect(first.mountedRoot === replacement)

    first.detach()
    #expect(first.mountedRoot == nil)
    #expect(second.attach(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    await waitForBridgeCommits(second, 1)
    #expect(second.mountedRoot === root)
}

@Test
@MainActor
func test_nodeHostBridge_retainsRootUntilDetachAndResumesLatestSuspendedState() async throws {
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    weak var weakRoot: Node?
    var root: Node? = Node()
    let child = Node()
    child.style.width = 40
    child.style.height = 20
    root?.addSubnode(child)
    weakRoot = root

    do {
        let mountedRoot = try #require(root)
        #expect(
            bridge.attach(root: mountedRoot, bounds: LayoutFrame(width: 100, height: 100), scale: 1)
        )
    }
    root = nil
    await waitForBridgeCommits(bridge, 1)
    #expect(weakRoot != nil)

    bridge.suspend()
    child.style.width = 80
    bridge.updateBounds(LayoutFrame(width: 300, height: 200), scale: 3)
    for _ in 0..<300 { await Task.yield() }
    #expect(bridge.committedCount == 1)

    bridge.resume()
    await waitForBridgeCommits(bridge, 2)
    #expect(weakRoot?.calculatedFrame == LayoutFrame(width: 300, height: 200))
    #expect(bridge.layer(for: child.id)?.contentsScale == 3)

    bridge.detach()
    #expect(weakRoot == nil)
}
