import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T10, D58 gap: D58 says "`dispose()` текстовой ноды отменяет её задачу в scheduler по
// `nodeID`" — but nothing ever called `DisplayScheduler.cancel(nodeID:)` for a node removed
// mid-mount; only a full `detach()`/`replaceRoot` disposed the *whole* scheduler
// (`t06_detachDuringPendingDisplayWorkNeverLeavesAStaleArtifactReachable`,
// `Display/TextDisplayIntegrationTests.swift`). A `TextNode` removed from a still-attached tree
// (structural edit, or `dispose()`) kept its committed artifact — and, if a job was still in
// flight, its active/pending job — in `DisplayScheduler` forever: a real leak, and a violation
// of the "queues empty after teardown" contract this card is about, even though the node's own
// `CALayer`s were correctly cleaned up by `LayerRenderer.removeStaleLayers` the whole time.
//
// Fixed by `LayerRenderer.onNodeRemoved`, wired in `NodeHostBridge.attach` to
// `displayScheduler.cancel(nodeID:)` — the same tree-wide "no longer active" diff
// `removeStaleLayers` already computes for layers is now also the trigger for purging the
// display queue.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func waitForArtifact(_ bridge: NodeHostBridge, _ id: NodeID) async {
    for _ in 0..<20_000 where bridge.displayArtifact(for: id) == nil { await Task.yield() }
}

@Test @MainActor
func t10_removingATextNodeFromALiveTreePurgesItsCommittedArtifact() async {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    await waitForArtifact(bridge, label.id)
    #expect(bridge.displayArtifact(for: label.id) != nil)

    label.removeFromSupernode()
    await waitForCommits(bridge, 2)

    #expect(bridge.displayArtifact(for: label.id) == nil)
    #expect(bridge.layer(for: label.id) == nil)
}

@Test @MainActor
func t10_disposingATextNodeWithAnInFlightRasterJobCancelsItRatherThanLeakingIt() async {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    await waitForArtifact(bridge, label.id)

    // Change the text (schedules a fresh raster job) and dispose the node in the same beat, so
    // the job is very likely still in flight — the same "in flight at teardown" shape as
    // `t06_detachDuringPendingDisplayWorkNeverLeavesAStaleArtifactReachable`, except the node is
    // disposed out of a live mount instead of the whole bridge being detached.
    label.text = "Disposed before its new raster ever lands"
    label.dispose()
    await waitForCommits(bridge, 2)

    #expect(bridge.displayArtifact(for: label.id) == nil)
    #expect(bridge.layer(for: label.id) == nil)
}
