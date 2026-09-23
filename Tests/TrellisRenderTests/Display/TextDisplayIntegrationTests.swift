import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T06 acceptance, end to end through NodeHostBridge: `RenderCoordinator.onPostCommit`/
// `onDisplayOnly` (T04) feed `DisplayScheduler` via a tree scan (D53) — no CALayer application
// yet, that is T07's job; this only asserts a committed `DisplayArtifact` exists and tracks the
// right node.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func waitForArtifact(_ bridge: NodeHostBridge, _ id: NodeID) async {
    for _ in 0..<20_000 where bridge.displayArtifact(for: id) == nil { await Task.yield() }
}

@MainActor
private func settle() async {
    for _ in 0..<300 { await Task.yield() }
}

@MainActor
private struct Mount {
    let root = Node()
    let label = TextNode(text: "Hello")
    let hostLayer = CALayer()
    let bridge: NodeHostBridge

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        root.style.flexDirection = .column
        root.style.width = 120
        root.addSubnode(label)
    }

    func attach() async {
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
        await waitForCommits(bridge, 1)
    }
}

@Test @MainActor
func t06_initialCommitEventuallyProducesADisplayArtifactForTheTextNode() async {
    let mount = Mount()
    await mount.attach()
    await waitForArtifact(mount.bridge, mount.label.id)

    #expect(mount.bridge.displayArtifact(for: mount.label.id) != nil)
    #expect(mount.bridge.displayStatistics.completed >= 1)
}

@Test @MainActor
func t06_textChangeEventuallyReplacesTheCommittedArtifact() async {
    let mount = Mount()
    await mount.attach()
    await waitForArtifact(mount.bridge, mount.label.id)
    let keyBefore = mount.bridge.displayArtifact(for: mount.label.id).map { _ in true }
    #expect(keyBefore == true)
    let completedBefore = mount.bridge.displayStatistics.completed

    mount.label.text = "A longer string that changes the measured geometry considerably"
    await waitForCommits(mount.bridge, 2)
    for _ in 0..<20_000 where mount.bridge.displayStatistics.completed <= completedBefore {
        await Task.yield()
    }

    #expect(mount.bridge.displayStatistics.completed > completedBefore)
    #expect(mount.bridge.displayArtifact(for: mount.label.id) != nil)
}

@Test @MainActor
func t06_colorOnlyChangeStillSchedulesANewDisplayPassWithoutANewLayoutSnapshot() async {
    let mount = Mount()
    await mount.attach()
    await waitForArtifact(mount.bridge, mount.label.id)
    let snapshotsBefore = mount.bridge.layoutSnapshotCount
    let completedBefore = mount.bridge.displayStatistics.completed

    mount.label.textStyle.color = ThemeColor(red: 1, green: 0, blue: 0)
    for _ in 0..<20_000 where mount.bridge.displayStatistics.completed <= completedBefore {
        await Task.yield()
    }

    #expect(mount.bridge.layoutSnapshotCount == snapshotsBefore)
    #expect(mount.bridge.displayStatistics.completed > completedBefore)
}

@Test @MainActor
func t06_detachDuringPendingDisplayWorkNeverLeavesAStaleArtifactReachable() async {
    let mount = Mount()
    await mount.attach()
    await waitForArtifact(mount.bridge, mount.label.id)

    mount.label.text = "Changed right before detach so a raster job is still in flight"
    mount.bridge.detach()
    await settle()

    #expect(mount.bridge.displayArtifact(for: mount.label.id) == nil)
    #expect(mount.bridge.displayStatistics.completed == 0)
}

@Test @MainActor
func t06_nonTextNodesAreSkippedByTheDisplayScan() async {
    let mount = Mount()
    let plainChild = Node()
    plainChild.style.width = 10
    plainChild.style.height = 10
    mount.root.addSubnode(plainChild)
    await mount.attach()
    await waitForArtifact(mount.bridge, mount.label.id)

    #expect(mount.bridge.displayArtifact(for: plainChild.id) == nil)
}
