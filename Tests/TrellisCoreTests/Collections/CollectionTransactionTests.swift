import Testing

@testable import TrellisCore

// R11 (`implementation-plan-6.md`, ADR 0030): ID-based deltas, diff, anchor preservation for
// prepend/delete/reorder/height changes, follow-bottom, clamping, and the worker queue under
// stale base, resize, detach and viewport movement between preparation and commit.

private struct Row: Sendable, Equatable {
    var height: Double = 20
}

@MainActor
private final class RowProvider: ItemProvider {
    func makeNode(for item: Row, id: Int) -> Node {
        let node = Node()
        node.style.height = .points(item.height)
        return node
    }

    func update(_ node: Node, with item: Row, id: Int) {
        node.style.height = .points(item.height)
    }
}

private typealias Snapshot = CollectionSnapshot<Int, Row>

private func rows(_ ids: [Int], height: Double = 20) -> [CollectionItem<Int, Row>] {
    ids.map { CollectionItem(id: $0, value: Row(height: height)) }
}

private func snapshot(_ ids: [Int], revision: UInt64, key: String = "feed") -> Snapshot {
    Snapshot(dataKey: key, revision: revision, items: rows(ids))
}

/// 100 rows of 20 pt (estimate 20), viewport 200 pt at `offset`.
@MainActor
private func makeWindow(offset: Double = 1_000, count: Int = 100) -> MaterializationWindow<
    RowProvider
> {
    let window = MaterializationWindow(
        provider: RowProvider(),
        estimatedLength: 20,
        ranges: PreparationRanges(displayLeading: 1, displayTrailing: 0.5),
        maximumMaterializedCount: 200,
        dataKey: "feed"
    )
    window.apply(snapshot(Array(0..<count), revision: 1))
    window.updateViewport(offset: offset, length: 200, crossExtent: 320)
    return window
}

/// Position of `id`'s top inside the viewport.
@MainActor
private func viewportPosition(of id: Int, in window: MaterializationWindow<RowProvider>) -> Double?
{
    guard let index = window.snapshot.index(of: id) else { return nil }

    return window.extents.offset(of: index) - window.offset
}

/// Lays out `content` with a real flexbox solve and feeds measurements back until stable.
@MainActor
@discardableResult
private func settleMeasurements(_ window: MaterializationWindow<RowProvider>) throws
    -> [CollectionAdjustment<Int>]
{
    var adjustments: [CollectionAdjustment<Int>] = []
    for _ in 0..<6 {
        let height = window.extents.totalExtent
        let input = window.content.makeLayoutInputSnapshot(
            constraint: SizeConstraint(width: .exact(320), height: .exact(height))
        )
        let frame = LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 320, height: height)
        _ = window.content.applyLayoutResult(
            try FlexboxEngine.layoutContainer(input: input, frame: frame)
        )
        guard let adjustment = window.recordMeasurements() else { return adjustments }

        adjustments.append(adjustment)
    }
    return adjustments
}

// MARK: - Delta and diff

@Test
func test_delta_appliesIDBasedChangesOnMatchingBase() throws {
    let base = snapshot([1, 2, 3, 4], revision: 7)
    let delta = CollectionDelta<Int, Row>(
        dataKey: "feed",
        baseRevision: 7,
        revision: 8,
        changes: [
            .insert(CollectionItem(id: 0, value: Row()), after: nil, section: ""),
            .insert(CollectionItem(id: 5, value: Row()), after: 4, section: ""),
            .insert(CollectionItem(id: 2, value: Row(height: 99)), after: 1, section: ""),
            .delete(3),
            .delete(42),
            .move(1, after: 4, section: ""),
            .update(CollectionItem(id: 4, value: Row(height: 44))),
        ]
    )

    let result = try delta.apply(to: base)

    #expect(result.items.map(\.id) == [0, 2, 4, 1, 5])
    #expect(result.revision == 8)
    #expect(result.items[1].value.height == 20)
    #expect(result.items[2].value.height == 44)
}

@Test
func test_delta_rejectsStaleBaseAndOtherKey() {
    let base = snapshot([1, 2], revision: 3)
    let stale = CollectionDelta<Int, Row>(
        dataKey: "feed",
        baseRevision: 2,
        revision: 3,
        changes: [.delete(1)]
    )
    let otherKey = CollectionDelta<Int, Row>(
        dataKey: "other",
        baseRevision: 3,
        revision: 4,
        changes: []
    )

    #expect(throws: CollectionDeltaRejection.staleBase(expected: 2, actual: 3)) {
        try stale.apply(to: base)
    }
    #expect(throws: CollectionDeltaRejection.dataKey) {
        try otherKey.apply(to: base)
    }
}

@Test
func test_prepare_diffCountsInsertRemoveUpdateMove() throws {
    let base = snapshot([1, 2, 3, 4, 5], revision: 1)
    var items = rows([6, 1, 3, 2, 5])
    items[4] = CollectionItem(id: 5, value: Row(height: 30))
    let target = Snapshot(dataKey: "feed", revision: 2, items: items)
    let input = CollectionPreparationInput(
        base: base,
        target: target,
        cache: ItemMeasurementCache(),
        key: PreparationKey(
            commitGeneration: 0,
            cacheVersion: 0,
            metrics: CollectionMetrics(
                crossExtent: 320,
                grid: nil,
                estimatedLength: 20,
                spacing: 0,
                environmentRevision: 0
            )
        )
    )

    let prepared = try #require(PreparedCollection.prepare(input, cancellable: false))

    #expect(prepared.diff == CollectionDiff(inserted: 1, removed: 1, updated: 1, moved: 1))
    #expect(prepared.geometry.rows.totalExtent == 100)
}

// MARK: - Anchor

@MainActor
@Test
func test_anchor_prependKeepsReadingRow() throws {
    let window = makeWindow()
    #expect(viewportPosition(of: 50, in: window) == 0)

    let adjustment = try #require(window.apply(snapshot(Array(-5..<100), revision: 2)))

    #expect(adjustment.anchor == .preserved(50))
    #expect(adjustment.offset == 1_100)
    #expect(adjustment.offsetChanged)
    #expect(viewportPosition(of: 50, in: window) == 0)
}

@MainActor
@Test
func test_anchor_prependAtTopKeepsFirstRowInsteadOfJumping() throws {
    let window = makeWindow(offset: 0)

    let adjustment = try #require(window.apply(snapshot(Array(-3..<100), revision: 2)))

    #expect(adjustment.anchor == .preserved(0))
    #expect(adjustment.offset == 60)
}

@MainActor
@Test
func test_anchor_deleteAboveMovesOffsetBack() throws {
    let window = makeWindow()
    let ids = Array(0..<100).filter { !(10..<20).contains($0) }

    let adjustment = try #require(window.apply(snapshot(ids, revision: 2)))

    #expect(adjustment.anchor == .preserved(50))
    #expect(adjustment.offset == 800)
}

@MainActor
@Test
func test_anchor_deletedAnchorFallsBackToNearestSurvivor() throws {
    let window = makeWindow(offset: 1_010)  // item 50 top is 10 pt above the viewport
    let ids = Array(0..<100).filter { $0 != 50 }

    let adjustment = try #require(window.apply(snapshot(ids, revision: 2)))

    #expect(adjustment.anchor == .neighbour(51))
    #expect(viewportPosition(of: 51, in: window) == 10)
}

@MainActor
@Test
func test_anchor_reorderFollowsTheAnchorItem() throws {
    let window = makeWindow()
    var ids = Array(0..<100)
    ids.removeAll { $0 == 50 }
    ids.insert(50, at: 5)

    let adjustment = try #require(window.apply(snapshot(ids, revision: 2)))

    #expect(adjustment.anchor == .preserved(50))
    #expect(viewportPosition(of: 50, in: window) == 0)
    #expect(window.materializedIDs.contains(50))
}

@MainActor
@Test
func test_anchor_measuredHeightsAboveViewportDoNotMoveReadingRow() throws {
    let window = makeWindow()
    var items = rows(Array(0..<100))
    for id in 45..<50 {
        items[id] = CollectionItem(id: id, value: Row(height: 60))
    }
    window.apply(Snapshot(dataKey: "feed", revision: 2, items: items))
    #expect(viewportPosition(of: 50, in: window) == 0)

    let adjustments = try settleMeasurements(window)

    #expect(adjustments.contains { $0.offsetChanged })
    #expect(window.extents.offset(of: 50) == 1_000 + 5 * 40)
    #expect(viewportPosition(of: 50, in: window) == 0)
}

@MainActor
@Test
func test_anchor_followBottomIsOptIn() throws {
    let reading = makeWindow(offset: 1_800)  // at the end: 2000 − 200
    reading.apply(snapshot(Array(0..<110), revision: 2))
    #expect(reading.offset == 1_800)

    let following = makeWindow(offset: 1_800)
    following.followsBottom = true
    let adjustment = try #require(following.apply(snapshot(Array(0..<110), revision: 2)))
    #expect(adjustment.anchor == .followedBottom)
    #expect(following.offset == 2_000)

    // Not at the bottom: follow-bottom does not pull the reader down.
    let midway = makeWindow(offset: 1_000)
    midway.followsBottom = true
    midway.apply(snapshot(Array(0..<110), revision: 2))
    #expect(midway.offset == 1_000)
}

@MainActor
@Test
func test_anchor_shrinkingContentClamps() throws {
    let window = makeWindow(offset: 1_800)

    let adjustment = try #require(window.apply(snapshot(Array(0..<60), revision: 2)))

    #expect(adjustment.clamped)
    #expect(window.offset == 1_000)
}

@MainActor
@Test
func test_anchor_resizeKeepsReadingRow() throws {
    let window = makeWindow()
    try settleMeasurements(window)
    // A new estimate moves unmeasured rows above; the reading row stays.
    window.estimatedLength = 30
    #expect(viewportPosition(of: 50, in: window) == 0)

    // A width change invalidates measurements: every row is estimated again.
    let adjustment = window.updateViewport(offset: window.offset, length: 200, crossExtent: 280)

    #expect(adjustment?.anchor == .preserved(50))
    #expect(viewportPosition(of: 50, in: window) == 0)
    #expect(window.offset == 1_500)
}

@MainActor
@Test
func test_anchor_newDataKeyStartsAtTop() throws {
    let window = makeWindow()

    let adjustment = try #require(window.apply(snapshot(Array(0..<100), revision: 1, key: "other")))

    #expect(adjustment.anchor == .none)
    #expect(window.offset == 0)
}

@MainActor
@Test
func test_anchor_adjustmentCallbackFiresOnlyWhenOffsetMoves() {
    let window = makeWindow()
    var received: [CollectionAdjustment<Int>] = []
    window.onOffsetAdjustment = { received.append($0) }

    window.apply(snapshot(Array(0..<120), revision: 2))  // append: offset unchanged
    window.apply(snapshot(Array(-2..<120), revision: 3))  // prepend: offset moves

    #expect(received.map(\.offset) == [1_040])
}

// MARK: - Queue

@MainActor
@Test
func test_queue_preparesOnWorkerAndCommitsLatest() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    var commits: [UInt64] = []
    queue.onCommit = { _ in commits.append(window.snapshot.revision) }

    queue.submit(snapshot(Array(0..<100), revision: 2))
    queue.submit(snapshot(Array(0..<110), revision: 3))
    queue.submit(snapshot(Array(-5..<110), revision: 4))
    await queue.drain()

    #expect(commits == [2, 4])
    #expect(queue.supersededCount == 1)
    #expect(window.snapshot.revision == 4)
    #expect(viewportPosition(of: 50, in: window) == 0)
    #expect(!queue.hasWork)
}

@MainActor
@Test
func test_queue_staleBaseIsPreparedAgain() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    var injected = false
    queue.beforeCommit = {
        guard !injected else { return }

        injected = true
        window.apply(snapshot(Array(-10..<100), revision: 2))
    }

    queue.submit(snapshot(Array(-10..<100).filter { $0 != 3 }, revision: 3))
    await queue.drain()

    #expect(queue.rejectedCount == 1)
    #expect(queue.committedCount == 1)
    #expect(window.snapshot.revision == 3)
    #expect(!window.snapshot.contains(3))
    #expect(viewportPosition(of: 50, in: window) == 0)
}

@MainActor
@Test
func test_queue_resizeBetweenPrepareAndCommitIsPreparedAgain() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    var injected = false
    queue.beforeCommit = {
        guard !injected else { return }

        injected = true
        window.updateViewport(offset: window.offset, length: 200, crossExtent: 300)
    }

    queue.submit(snapshot(Array(-5..<100), revision: 2))
    await queue.drain()

    #expect(queue.rejectedCount == 1)
    #expect(window.snapshot.revision == 2)
    #expect(viewportPosition(of: 50, in: window) == 0)
}

@MainActor
@Test
func test_queue_detachKeepsSnapshotUntilAttach() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    queue.beforeCommit = { queue.detach() }

    queue.submit(snapshot(Array(-5..<100), revision: 2))
    await queue.drain()
    #expect(window.snapshot.revision == 1)
    #expect(queue.hasWork)

    queue.beforeCommit = nil
    queue.attach()
    await queue.drain()
    #expect(window.snapshot.revision == 2)
    #expect(viewportPosition(of: 50, in: window) == 0)
}

@MainActor
@Test
func test_queue_viewportMovedDuringPreparationKeepsTheRowUnderTheReader() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    queue.beforeCommit = {
        // The user kept dragging while the worker prepared the update.
        window.updateViewport(offset: 1_230, length: 200, crossExtent: 320)
    }

    queue.submit(snapshot(Array(-5..<100), revision: 2))
    await queue.drain()

    // Item 61 had its top 10 pt above the viewport at commit time; it stays there.
    #expect(viewportPosition(of: 61, in: window) == -10)
    #expect(window.offset == 1_330)
}

// MARK: - Property test

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@MainActor
@Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
func test_property_orderIdentityAndAnchorMatchReferenceModel(seed: UInt64) throws {
    var random = SplitMix64(state: seed)
    var reference: [(id: Int, height: Double)] = (0..<60).map { ($0, 20) }
    var nextID = 1_000
    let window = MaterializationWindow(
        provider: RowProvider(),
        estimatedLength: 20,
        ranges: PreparationRanges(displayLeading: 1, displayTrailing: 0.5),
        maximumMaterializedCount: 200,
        dataKey: "feed"
    )
    func current(_ revision: UInt64) -> Snapshot {
        Snapshot(
            dataKey: "feed",
            revision: revision,
            items: reference.map { CollectionItem(id: $0.id, value: Row(height: $0.height)) }
        )
    }
    window.apply(current(1))
    window.updateViewport(offset: 400, length: 200, crossExtent: 320)
    try settleMeasurements(window)
    var anchorChecks = 0

    for step in 0..<120 {
        let revision = UInt64(step + 2)
        let anchorIndex = try #require(window.extents.index(at: window.offset))
        let anchorID = window.snapshot.items[anchorIndex].id
        let anchorPosition = try #require(viewportPosition(of: anchorID, in: window))

        switch random.next() % 5 {
        case 0:
            let count = Int(random.next() % 4) + 1
            let inserted = (0..<count).map { _ -> (Int, Double) in
                nextID += 1
                return (nextID, Double(10 + random.next() % 50))
            }
            reference.insert(contentsOf: inserted, at: 0)
        case 1:
            nextID += 1
            reference.append((nextID, Double(10 + random.next() % 50)))
        case 2 where reference.count > 10:
            reference.remove(at: Int(random.next() % UInt64(reference.count)))
        case 3 where reference.count > 2:
            let from = Int(random.next() % UInt64(reference.count))
            let element = reference.remove(at: from)
            reference.insert(element, at: Int(random.next() % UInt64(reference.count + 1)))
        default:
            let index = Int(random.next() % UInt64(reference.count))
            reference[index].height = Double(10 + random.next() % 50)
        }

        var clamped = window.apply(current(revision))?.clamped ?? false
        clamped = try settleMeasurements(window).contains { $0.clamped } || clamped

        // Order and identity follow the reference model.
        #expect(window.snapshot.items.map(\.id) == reference.map(\.id))
        // No partial commit: live nodes are exactly the committed window's, in order, showing
        // the committed models.
        let displayIDs = window.snapshot.items[window.window.display].map(\.id)
        #expect(Set(window.materializedIDs) == Set(displayIDs))
        #expect(
            window.content.subnodes.map(ObjectIdentifier.init)
                == window.materializedIDs.compactMap { window.node(for: $0) }.map(
                    ObjectIdentifier.init
                )
        )
        for id in window.materializedIDs {
            let expected = window.snapshot.items[window.snapshot.index(of: id)!].value.height
            #expect(window.node(for: id)?.style.height == .points(expected))
        }
        // The anchor keeps its viewport position within 0.5 pt unless clamped.
        if !clamped, let position = viewportPosition(of: anchorID, in: window) {
            anchorChecks += 1
            #expect(abs(position - anchorPosition) <= 0.5, "seed \(seed) step \(step)")
        }
    }
    // The invariant was exercised, not skipped by clamping or removed anchors.
    #expect(anchorChecks >= 80, "seed \(seed) checked \(anchorChecks)")
}

// MARK: - R12 (P6.9): environment change between preparation and commit

private enum RowFontScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

private enum RowTintKey: EnvironmentKey {
    static let defaultValue = 0
    static let affectsLayout = false
}

@MainActor
@Test
func test_queue_layoutEnvironmentChangeBetweenPrepareAndCommitIsPreparedAgain() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    var injected = false
    queue.beforeCommit = {
        guard !injected else { return }

        injected = true
        window.content.setEnvironment(RowFontScaleKey.self, to: 1.3)
        window.updateViewport(offset: window.offset, length: 200, crossExtent: 320)
    }

    queue.submit(snapshot(Array(-5..<100), revision: 2))
    await queue.drain()

    #expect(queue.rejectedCount == 1)
    #expect(window.snapshot.revision == 2)
    #expect(viewportPosition(of: 50, in: window) == 0)
}

@MainActor
@Test
func test_queue_paintOnlyEnvironmentChangeBetweenPrepareAndCommitKeepsThePreparation() async {
    let window = makeWindow()
    let queue = CollectionUpdateQueue(window: window)
    queue.beforeCommit = {
        window.content.setEnvironment(RowTintKey.self, to: 2)
        window.updateViewport(offset: window.offset, length: 200, crossExtent: 320)
    }

    queue.submit(snapshot(Array(-5..<100), revision: 2))
    await queue.drain()

    #expect(queue.rejectedCount == 0)
    #expect(window.snapshot.revision == 2)
    #expect(viewportPosition(of: 50, in: window) == 0)
}
