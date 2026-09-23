import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// A03 — the bridge publishes one consistent semantic snapshot per commit, republishes
// metadata-only without a layout pass (D41), and never lets a live mutation between commits
// leak into the published tree (D36). Acceptance list of implementation-plan-3 §5 A03.

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
    let card = ControlNode()
    let label = Node()
    let hostLayer = CALayer()
    let bridge: NodeHostBridge

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        root.style.flexDirection = .column
        card.style.width = 200
        card.style.height = 60
        label.style.width = 100
        label.style.height = 20
        root.addSubnode(card)
        card.addSubnode(label)
        card.accessibility = AccessibilityProperties(isElement: true, label: "Card")
    }

    func attach(bounds: LayoutFrame = LayoutFrame(width: 320, height: 240)) async {
        #expect(bridge.attach(root: root, bounds: bounds, scale: 1))
        await waitForCommits(bridge, 1)
    }
}

@Test @MainActor
func a03_commitPublishesSnapshotBeforeExternalCallbacks() async throws {
    let mount = Mount()
    var seenAtPublish: [UInt64] = []
    mount.bridge.onSemanticsPublished = { snapshot in seenAtPublish.append(snapshot.revision) }
    await mount.attach()

    let snapshot = try #require(mount.bridge.semanticSnapshot)
    #expect(snapshot.order == [mount.root.id, mount.card.id, mount.label.id])
    #expect(snapshot.record(for: mount.card.id)?.accessibility.label == "Card")
    #expect(
        snapshot.record(for: mount.card.id)?.visibleBounds == LayoutFrame(width: 200, height: 60)
    )
    #expect(snapshot.mountEpoch == mount.bridge.mountEpoch)
    #expect(snapshot.geometryGeneration == mount.bridge.statistics.committed)
    #expect(mount.bridge.semanticPublishCount == 1)
    #expect(mount.bridge.metadataOnlyPublishCount == 0)
    #expect(seenAtPublish == [1])
}

@Test @MainActor
func a03_labelBurstIsOneMetadataOnlyPublishWithNoLayoutWork() async throws {
    let mount = Mount()
    await mount.attach()
    let requestedBefore = mount.bridge.statistics.requested
    let snapshotsBefore = mount.bridge.layoutSnapshotCount
    var published = 0
    mount.bridge.onSemanticsPublished = { _ in published += 1 }

    for index in 0..<100 {
        mount.card.accessibility.label = "Card \(index)"
        mount.card.focus.priority = index
    }
    await settle()

    #expect(mount.bridge.statistics.requested == requestedBefore)
    #expect(mount.bridge.layoutSnapshotCount == snapshotsBefore)
    #expect(mount.bridge.statistics.committed == 1)
    #expect(mount.bridge.semanticPublishCount == 2)
    #expect(mount.bridge.metadataOnlyPublishCount == 1)
    #expect(published == 1)
    let snapshot = try #require(mount.bridge.semanticSnapshot)
    #expect(snapshot.record(for: mount.card.id)?.accessibility.label == "Card 99")
    #expect(snapshot.record(for: mount.card.id)?.focus.priority == 99)
    #expect(snapshot.geometryGeneration == 1)
    #expect(snapshot.revision == 2)
}

@Test @MainActor
func a03_sameValueIsZeroWork() async {
    let mount = Mount()
    await mount.attach()
    let statsBefore = mount.bridge.statistics

    mount.card.accessibility.label = "Card"  // already "Card"
    mount.card.focus = mount.card.focus
    mount.card.isEnabled = true
    await settle()

    #expect(mount.bridge.statistics == statsBefore)
    #expect(mount.bridge.semanticPublishCount == 1)
    #expect(mount.bridge.metadataOnlyPublishCount == 0)
}

@Test @MainActor
func a03_semanticUpdateDuringSolveIsNotLostAndDoesNotCancelTheSolver() async throws {
    let mount = Mount()
    await mount.attach()

    // A layout change starts a solve; catch the window while it is in flight. On a slow
    // machine the solve may already have committed by the time the request is observed —
    // then the label change is an ordinary metadata-only publish, which is also correct.
    mount.card.style.width = 240
    for _ in 0..<10_000 where mount.bridge.statistics.requested < 2 { await Task.yield() }
    let inFlight = mount.bridge.statistics.committed == 1
    mount.card.accessibility.label = "During solve"
    await waitForCommits(mount.bridge, 2)
    await settle()

    #expect(mount.bridge.statistics.cancelled == 0)
    #expect(mount.bridge.statistics.stale == 0)
    #expect(mount.bridge.statistics.committed == 2)
    let snapshot = try #require(mount.bridge.semanticSnapshot)
    #expect(snapshot.record(for: mount.card.id)?.accessibility.label == "During solve")
    #expect(snapshot.record(for: mount.card.id)?.frame.width == 240)
    if inFlight {
        // The commit already read the new label, so the trailing semantic-only flush found
        // nothing to change: one geometry publish, no extra metadata-only one.
        #expect(mount.bridge.semanticPublishCount == 2)
        #expect(mount.bridge.metadataOnlyPublishCount == 0)
    } else {
        #expect(mount.bridge.semanticPublishCount == 3)
        #expect(mount.bridge.metadataOnlyPublishCount == 1)
    }
}

@Test @MainActor
func a03_mutationBetweenCommitsNeverPublishesAnUncommittedChild() async throws {
    let mount = Mount()
    await mount.attach()
    let generationBefore = mount.bridge.semanticSnapshot?.geometryGeneration

    let late = ControlNode()
    late.style.width = 50
    late.style.height = 50
    late.accessibility.label = "Late"
    mount.root.addSubnode(late)
    // Before the next commit: the structure change is pending, the published tree is the
    // committed one — no record with an old or missing frame for `late`.
    #expect(mount.bridge.semanticSnapshot?.record(for: late.id) == nil)
    #expect(mount.bridge.semanticSnapshot?.geometryGeneration == generationBefore)

    await waitForCommits(mount.bridge, 2)
    let snapshot = try #require(mount.bridge.semanticSnapshot)
    #expect(snapshot.record(for: late.id)?.accessibility.label == "Late")
    #expect(
        snapshot.record(for: late.id)?.frame
            == LayoutFrame(
                origin: LayoutPoint(x: 0, y: 60),
                width: 50,
                height: 50
            )
    )
    #expect(snapshot.geometryGeneration == 2)
}

@Test @MainActor
func a03_paintOnlyDoesNotPublishSemanticsAndGeometryOnlyDoes() async throws {
    let mount = Mount()
    await mount.attach()

    mount.card.appearance.cornerRadius = 8
    await settle()
    #expect(mount.bridge.statistics.committed == 1)
    #expect(mount.bridge.statistics.coalesced == 1)
    #expect(mount.bridge.semanticPublishCount == 1)

    mount.card.style.height = 80
    await waitForCommits(mount.bridge, 2)
    let snapshot = try #require(mount.bridge.semanticSnapshot)
    #expect(snapshot.record(for: mount.card.id)?.visibleBounds?.height == 80)
    #expect(snapshot.geometryGeneration == 2)
    #expect(mount.bridge.semanticPublishCount == 2)
    #expect(mount.bridge.metadataOnlyPublishCount == 0)

    // Both reasons in one window: one paint-only and one semantic-only delivery, no solve.
    mount.card.appearance.cornerRadius = 12
    mount.card.accessibility.value = "1"
    await settle()
    #expect(mount.bridge.statistics.committed == 2)
    #expect(mount.bridge.semanticPublishCount == 3)
    #expect(mount.bridge.metadataOnlyPublishCount == 1)
    #expect(mount.bridge.semanticSnapshot?.record(for: mount.card.id)?.accessibility.value == "1")
}

@Test @MainActor
func a03_suspendHoldsMetadataUntilResumeAndResizeRepublishesFrames() async throws {
    let mount = Mount()
    await mount.attach()

    mount.bridge.suspend()
    mount.card.accessibility.label = "Suspended"
    await settle()
    #expect(
        mount.bridge.semanticSnapshot?.record(for: mount.card.id)?.accessibility.label == "Card"
    )
    #expect(mount.bridge.semanticPublishCount == 1)

    mount.bridge.resume()
    await settle()
    #expect(
        mount.bridge.semanticSnapshot?.record(for: mount.card.id)?.accessibility.label
            == "Suspended"
    )
    #expect(mount.bridge.semanticPublishCount == 2)
    #expect(mount.bridge.metadataOnlyPublishCount == 1)

    mount.bridge.updateBounds(LayoutFrame(width: 640, height: 480), scale: 2)
    await waitForCommits(mount.bridge, 2)
    let snapshot = try #require(mount.bridge.semanticSnapshot)
    #expect(snapshot.bounds == LayoutFrame(width: 640, height: 480))
    #expect(snapshot.record(for: mount.card.id)?.accessibility.label == "Suspended")
    #expect(mount.bridge.metadataOnlyPublishCount == 1)
}

@Test @MainActor
func a03_rotationAndNestedClipReachThePublishedVisibleBounds() async throws {
    let mount = Mount()
    mount.card.style.visual = LayoutVisualProperties(overflow: .hidden)
    mount.label.style {
        $0.positionType = .absolute
        $0.offsets = DirectionalEdgeOffsets(top: 40, leading: 180)
    }
    await mount.attach()

    let snapshot = try #require(mount.bridge.semanticSnapshot)
    // The label (100×20 at 180, 40 inside a 200×60 clipping card) is cut to 20×20.
    #expect(
        snapshot.record(for: mount.label.id)?.visibleBounds
            == LayoutFrame(
                origin: LayoutPoint(x: 180, y: 40),
                width: 20,
                height: 20
            )
    )

    mount.card.style.visual = LayoutVisualProperties(
        overflow: .hidden,
        transform: LayoutTransform(rotationRadians: .pi / 2)
    )
    await waitForCommits(mount.bridge, 2)
    let rotated = try #require(mount.bridge.semanticSnapshot?.record(for: mount.card.id))
    // 200×60 rotated by π/2 around (100, 30): image spans x ∈ [70, 130], y ∈ [-70, 130],
    // cut by the host bounds to y ∈ [0, 130].
    #expect(
        rotated.visibleBounds
            == LayoutFrame(origin: LayoutPoint(x: 70, y: 0), width: 60, height: 130)
    )
}

@Test @MainActor
func a03_detachClearsAndWrapperlessModePublishesNothing() async {
    let mount = Mount()
    await mount.attach()
    #expect(mount.bridge.semanticSnapshot != nil)

    mount.bridge.detach()
    #expect(mount.bridge.semanticSnapshot == nil)

    mount.bridge.skipsLayoutOnlyWrappers = true
    await mount.attach()
    #expect(mount.bridge.semanticSnapshot == nil)
    #expect(mount.bridge.semanticPublishCount == 1)
}

// MARK: - A06: the accessibility tree follows publishes and the focus scope

@Test @MainActor
func a06_bridgePublishesTheTreeOnCommitScopeChangeAndMetadataOnlyButNotOnEqualContent() async throws
{
    let mount = Mount()
    var trees: [AccessibilityTree] = []
    mount.bridge.onAccessibilityTreeChanged = { trees.append($0) }
    await mount.attach()

    let tree = try #require(mount.bridge.accessibilityTree)
    #expect(tree.readingOrder == [mount.card.id])
    #expect(tree.element(for: mount.card.id)?.label == "Card")
    #expect(tree.mountEpoch == mount.bridge.mountEpoch)
    #expect(trees.count == 1)

    // Metadata-only: the value changes, the tree is republished once.
    mount.card.accessibility.value = "3"
    await settle()
    #expect(mount.bridge.accessibilityTree?.element(for: mount.card.id)?.value == "3")
    #expect(trees.count == 2)

    // A geometry commit that leaves every element's frame and content alone: no tree change.
    mount.root.style.padding = DirectionalEdgeInsets()  // already zero: no-op at all
    mount.label.appearance.cornerRadius = 2  // paint-only
    await settle()
    #expect(trees.count == 2)

    // Scope: the tree is confined to the card's subtree (the card is the only element there).
    mount.label.accessibility = AccessibilityProperties(isElement: true, label: "Label")
    await settle()
    #expect(trees.count == 3)
    // The card became a labelled group (A01 §3.2): only the label is a leaf now.
    #expect(mount.bridge.accessibilityTree?.readingOrder == [mount.label.id])
    #expect(mount.bridge.accessibilityTree?.element(for: mount.card.id)?.isElement == false)
    mount.bridge.setFocusScope(mount.label.id)
    #expect(mount.bridge.accessibilityTree?.readingOrder == [mount.label.id])
    #expect(mount.bridge.accessibilityTree?.scope == mount.label.id)
    #expect(trees.count == 4)
    mount.bridge.setFocusScope(mount.label.id)  // same scope: nothing published
    #expect(trees.count == 4)
    mount.bridge.setFocusScope(nil)
    #expect(mount.bridge.accessibilityTree?.element(for: mount.card.id)?.label == "Card")
    #expect(mount.bridge.accessibilityTree?.scope == nil)
    #expect(trees.count == 5)

    mount.bridge.detach()
    #expect(mount.bridge.accessibilityTree == nil)
}
