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
func test_nodeHostBridge_buildsHitTestSnapshotOnlyAtCommit() async throws {
    let root = Node()
    let child = Node()
    child.style.width = 100
    child.style.height = 40
    root.addSubnode(child)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.hitTestSnapshot == nil)
    #expect(bridge.mountEpoch == 0)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    // Attached, but nothing committed yet — nothing is on screen, nothing to hit (D25).
    #expect(bridge.hitTestSnapshot == nil)
    #expect(bridge.mountEpoch == 1)
    await waitForBridgeCommits(bridge, 1)

    let snapshot = try #require(bridge.hitTestSnapshot)
    #expect(snapshot.root == root.id)
    #expect(snapshot.mountEpoch == 1)
    #expect(snapshot.bounds == LayoutFrame(width: 400, height: 400))
    #expect(try #require(snapshot.record(for: child.id)).frame == child.calculatedFrame)
    #expect(try #require(snapshot.record(for: child.id)).frame.width == 100)
    #expect(try #require(snapshot.record(for: root.id)).children == [child.id])
}

@Test
@MainActor
func test_nodeHostBridge_hitTestSnapshotIgnoresLiveMutationsUntilNextCommit() async throws {
    let root = Node()
    let child = Node()
    let sibling = Node()
    child.style.width = 100
    child.style.height = 40
    sibling.style.width = 10
    sibling.style.height = 10
    root.addSubnode(child)
    root.addSubnode(sibling)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    await waitForBridgeCommits(bridge, 1)
    let before = try #require(bridge.hitTestSnapshot)

    // T01: the live tree changes now; the screen still shows the first commit.
    child.style.width = 300
    child.style.visual = LayoutVisualProperties(zIndex: 5, opacity: 0)
    sibling.removeFromSupernode()
    let added = Node()
    added.style.width = 20
    added.style.height = 20
    root.addSubnode(added)

    let stillBefore = try #require(bridge.hitTestSnapshot)
    #expect(try #require(stillBefore.record(for: child.id)).frame.width == 100)
    #expect(try #require(stillBefore.record(for: child.id)).visual == LayoutVisualProperties())
    #expect(stillBefore.record(for: sibling.id) != nil)
    #expect(stillBefore.record(for: added.id) == nil)
    #expect(try #require(stillBefore.record(for: root.id)).children == [child.id, sibling.id])
    #expect(stillBefore.count == before.count)

    await waitForBridgeCommits(bridge, 2)
    let after = try #require(bridge.hitTestSnapshot)
    #expect(try #require(after.record(for: child.id)).frame.width == 300)
    #expect(try #require(after.record(for: child.id)).visual.zIndex == 5)
    #expect(try #require(after.record(for: child.id)).visual.opacity == 0)
    #expect(after.record(for: sibling.id) == nil)
    #expect(try #require(after.record(for: added.id)).frame.width == 20)
    #expect(try #require(after.record(for: root.id)).children == [child.id, added.id])
    #expect(after.mountEpoch == 1)
}

@Test
@MainActor
func test_nodeHostBridge_detachClearsHitTestSnapshotAndReattachBumpsMountEpoch() async throws {
    let root = Node()
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    await waitForBridgeCommits(bridge, 1)
    #expect(bridge.hitTestSnapshot?.mountEpoch == 1)

    bridge.detach()
    #expect(bridge.hitTestSnapshot == nil)

    // Same root, new mount: a snapshot (or a session) from the old mount must not pass as the
    // current one (D21).
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    #expect(bridge.hitTestSnapshot == nil)
    #expect(bridge.mountEpoch == 2)
    await waitForBridgeCommits(bridge, 1)
    #expect(bridge.hitTestSnapshot?.mountEpoch == 2)
    #expect(bridge.hitTestSnapshot?.root == root.id)
}

@Test
@MainActor
func test_nodeHostBridge_hitTestUsesLastCommitAndRefusesFlattenedWrappers() async throws {
    let root = Node()
    let child = Node()
    child.style.width = 100
    child.style.height = 40
    root.addSubnode(child)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.hitTest(LayoutPoint(x: 5, y: 5)) == nil)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    #expect(bridge.hitTest(LayoutPoint(x: 5, y: 5)) == nil)  // attached, not yet committed
    await waitForBridgeCommits(bridge, 1)

    #expect(bridge.hitTest(LayoutPoint(x: 5, y: 5)) == child.id)
    #expect(bridge.hitTest(LayoutPoint(x: 300, y: 300)) == root.id)
    #expect(bridge.hitTest(LayoutPoint(x: 400, y: 5)) == nil)

    // D32: with wrapper layers flattened the layer stacking is not what the snapshot describes,
    // so the bridge answers nothing rather than something plausible.
    bridge.skipsLayoutOnlyWrappers = true
    #expect(bridge.hitTest(LayoutPoint(x: 5, y: 5)) == nil)
    bridge.skipsLayoutOnlyWrappers = false
    #expect(bridge.hitTest(LayoutPoint(x: 5, y: 5)) == child.id)

    bridge.detach()
    #expect(bridge.hitTest(LayoutPoint(x: 5, y: 5)) == nil)
}
