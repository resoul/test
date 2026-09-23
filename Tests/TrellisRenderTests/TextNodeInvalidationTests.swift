import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T04 acceptance (implementation-plan-4.md §5): text change flushes exactly once and produces
// new geometry; the same text is zero work; a color-only style change never takes a layout
// snapshot. `PortableTextMeasurer` (D51/#40) is the fallback in play here — no host renderer is
// installed, matching a real "no TextRendererKey set yet" mount before T09.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
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
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 1))
        await waitForCommits(bridge, 1)
    }
}

@Test @MainActor
func t04_textChangeFlushesOnceAndProducesNewGeometry() async throws {
    let mount = Mount()
    await mount.attach()
    let committedBefore = mount.bridge.statistics.committed
    let frameBefore = try #require(mount.label.calculatedFrame)

    mount.label.text = "Hello, much longer text that should wrap across several lines"
    await waitForCommits(mount.bridge, committedBefore + 1)
    await settle()

    let frameAfter = try #require(mount.label.calculatedFrame)
    #expect(mount.bridge.statistics.committed == committedBefore + 1)
    #expect(frameAfter.height != frameBefore.height)
}

@Test @MainActor
func t04_sameTextIsZeroWork() async {
    let mount = Mount()
    await mount.attach()
    let requestedBefore = mount.bridge.statistics.requested
    let snapshotsBefore = mount.bridge.layoutSnapshotCount
    let geometryRevisionBefore = mount.label.geometryRevision

    mount.label.text = "Hello"
    await settle()

    #expect(mount.bridge.statistics.requested == requestedBefore)
    #expect(mount.bridge.layoutSnapshotCount == snapshotsBefore)
    #expect(mount.label.geometryRevision == geometryRevisionBefore)
}

@Test @MainActor
func t04_colorOnlyChangeTakesZeroLayoutSnapshots() async {
    let mount = Mount()
    await mount.attach()
    let snapshotsBefore = mount.bridge.layoutSnapshotCount
    let geometryRevisionBefore = mount.label.geometryRevision
    let displayRevisionBefore = mount.label.displayRevision
    let frameBefore = mount.label.calculatedFrame

    mount.label.textStyle.color = ThemeColor(red: 1, green: 0, blue: 0)
    await settle()

    #expect(mount.bridge.layoutSnapshotCount == snapshotsBefore)
    #expect(mount.label.geometryRevision == geometryRevisionBefore)
    #expect(mount.label.displayRevision == displayRevisionBefore + 1)
    #expect(mount.label.calculatedFrame == frameBefore)
}

@Test @MainActor
func t04_detachDuringPendingTextChangeCommitsNothingLate() async throws {
    let mount = Mount()
    await mount.attach()
    let frameBefore = try #require(mount.label.calculatedFrame)

    mount.label.text = "Changed right before detach — long enough that it would wrap and grow"
    mount.bridge.detach()
    await settle()

    // detach() drops the coordinator, so `statistics.committed` itself resets to 0 (`?? 0`) —
    // not useful as "no late commit" evidence on its own. The frame the pending text change
    // would have produced is the observable that matters: it never lands.
    #expect(mount.label.calculatedFrame == frameBefore)
    #expect(mount.bridge.statistics.committed == 0)
}

// T08 (implementation-plan-4.md §5, D57): a text change goes through measurement even when the
// final size happens to come out the same — the flush is driven by `geometryRevision`, not by
// comparing the resulting frame — and only an AX-only override (no `document`/`textStyle`/
// `maxLines`/`truncation` change) takes the existing semantics-only fast path.

@Test @MainActor
func t08_textChangeWithTheSameMeasuredSizeStillFlushes() async throws {
    let mount = Mount()
    await mount.attach()
    let committedBefore = mount.bridge.statistics.committed
    let geometryRevisionBefore = mount.label.geometryRevision
    let frameBefore = try #require(mount.label.calculatedFrame)

    // "World" has the same character count as "Hello" — `PortableTextMeasurer`'s deterministic
    // model (no host renderer installed on this mount) reports the identical size for both.
    mount.label.text = "World"
    await waitForCommits(mount.bridge, committedBefore + 1)
    await settle()

    #expect(mount.bridge.statistics.committed == committedBefore + 1)
    #expect(mount.label.geometryRevision == geometryRevisionBefore + 1)
    #expect(mount.label.calculatedFrame == frameBefore)
}

@Test @MainActor
func t08_axOnlyOverrideTakesTheSemanticsOnlyFastPathWithoutANewLayoutSnapshot() async {
    let mount = Mount()
    await mount.attach()
    let snapshotsBefore = mount.bridge.layoutSnapshotCount
    let geometryRevisionBefore = mount.label.geometryRevision
    let semanticPublishBefore = mount.bridge.semanticPublishCount

    mount.label.accessibility.label = "Custom label"
    await settle()

    #expect(mount.bridge.layoutSnapshotCount == snapshotsBefore)
    #expect(mount.label.geometryRevision == geometryRevisionBefore)
    #expect(mount.bridge.semanticPublishCount > semanticPublishBefore)
}
