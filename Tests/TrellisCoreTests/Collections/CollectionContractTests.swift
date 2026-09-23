import Testing

@testable import TrellisCore

// R10 (`implementation-plan-6.md`, ADR 0030): pure value contracts of the collection data
// layer. Cases re-state Weave's `CollectionsTests.swift` (window bounds, duplicate IDs,
// variable heights) against Trellis types, plus the pagination and measurement rules of
// P6.8/P6.9 that Weave did not have.

private typealias Snapshot = CollectionSnapshot<Int, String>

private func items(_ ids: Range<Int>) -> [CollectionItem<Int, String>] {
    ids.map { CollectionItem(id: $0, value: "item \($0)") }
}

// MARK: - Snapshot

@Test
func test_snapshot_dropsDuplicateIDsFirstWinsAcrossSections() {
    let snapshot = Snapshot(
        dataKey: "feed",
        revision: 1,
        sections: [
            CollectionSection(
                id: "a",
                items: [
                    CollectionItem(id: 1, value: "first"),
                    CollectionItem(id: 2, value: "two"),
                    CollectionItem(id: 1, value: "duplicate in section"),
                ]
            ),
            CollectionSection(id: "b", items: [CollectionItem(id: 2, value: "duplicate across")]),
        ]
    )

    #expect(snapshot.items.map(\.id) == [1, 2])
    #expect(snapshot.items.first?.value == "first")
    #expect(snapshot.droppedDuplicateCount == 2)
    #expect(snapshot.sections.map(\.items.count) == [2, 0])
    #expect(snapshot.index(of: 2) == 1)
    #expect(snapshot.index(of: 3) == nil)
}

@Test
func test_snapshot_equalityIncludesRevisionAndLoadState() {
    let base = Snapshot(dataKey: "feed", revision: 1, items: items(0..<3))
    let loadingMore = Snapshot(
        dataKey: "feed",
        revision: 1,
        items: items(0..<3),
        loadState: CollectionLoadState(phase: .loaded, isLoadingMore: true)
    )

    #expect(base == Snapshot(dataKey: "feed", revision: 1, items: items(0..<3)))
    #expect(base != Snapshot(dataKey: "feed", revision: 2, items: items(0..<3)))
    #expect(base != loadingMore)
}

// MARK: - Extents and window

@Test
func test_extentIndex_usesMeasuredLengthsForOffsetsAndLookup() {
    let extents = ItemExtentIndex(lengths: [200, 50, 50, 50], spacing: 10)

    #expect(extents.offset(of: 1) == 210)
    #expect(extents.offset(of: 3) == 330)
    #expect(extents.totalExtent == 380)
    #expect(extents.length(of: 0) == 200)
    #expect(extents.length(of: 3) == 50)
    #expect(extents.index(at: 150) == 0)
    #expect(extents.index(at: 205) == 0)
    #expect(extents.index(at: 210) == 1)
    #expect(extents.range(from: 150, to: 250) == 0..<2)
}

@Test
func test_window_tenThousandUniformItemsKeepsDisplayBounded() {
    let extents = ItemExtentIndex(lengths: Array(repeating: 20, count: 10_000))
    let window = VirtualizationWindow.compute(
        extents: extents,
        viewportOffset: 1_000,
        viewportLength: 100,
        ranges: PreparationRanges(displayLeading: 1, displayTrailing: 0.5)
    )

    #expect(window.visible == 50..<55)
    #expect(window.display == 47..<60)
    #expect(window.preload.contains(window.display.lowerBound))
    #expect(window.preload.contains(window.display.upperBound - 1))
}

@Test
func test_window_leadingSideFollowsDirection() {
    let extents = ItemExtentIndex(lengths: Array(repeating: 10, count: 100))
    let ranges = PreparationRanges(displayLeading: 2, displayTrailing: 0)

    let forward = VirtualizationWindow.compute(
        extents: extents,
        viewportOffset: 500,
        viewportLength: 50,
        direction: .forward,
        ranges: ranges
    )
    let backward = VirtualizationWindow.compute(
        extents: extents,
        viewportOffset: 500,
        viewportLength: 50,
        direction: .backward,
        ranges: ranges
    )

    #expect(forward.display == 50..<65)
    #expect(backward.display == 40..<55)
}

@Test
func test_window_capKeepsVisibleItemsFirst() {
    let extents = ItemExtentIndex(lengths: Array(repeating: 10, count: 1_000))
    let window = VirtualizationWindow.compute(
        extents: extents,
        viewportOffset: 1_000,
        viewportLength: 100,
        ranges: PreparationRanges(displayLeading: 3, displayTrailing: 3),
        maximumDisplayCount: 14
    )

    #expect(window.visible == 100..<110)
    #expect(window.display.count == 14)
    #expect(window.display.contains(100))
    #expect(window.display.contains(109))
}

@Test
func test_window_emptyViewportYieldsEmptyRanges() {
    let window = VirtualizationWindow.compute(
        extents: ItemExtentIndex(lengths: [10, 10]),
        viewportOffset: 0,
        viewportLength: 0
    )

    #expect(window.visible.isEmpty && window.display.isEmpty && window.preload.isEmpty)
}

// MARK: - Pagination

private struct PageFixture {
    var gate = PaginationGate()
    let viewportLength = 100.0

    mutating func evaluate(_ snapshot: Snapshot, offset: Double) -> PaginationDecision {
        let extents = ItemExtentIndex(lengths: Array(repeating: 20, count: snapshot.count))
        let visible = extents.range(from: offset, to: offset + viewportLength)
        return gate.evaluate(
            snapshot: snapshot,
            extents: extents,
            visible: visible,
            viewportOffset: offset,
            viewportLength: viewportLength
        )
    }
}

@Test
func test_pagination_defaultTriggerIsTwoViewportLengths() {
    #expect(PaginationPolicy().trigger == .remainingViewportLengths(2))

    var fixture = PageFixture()
    let page = Snapshot(dataKey: "feed", revision: 1, items: items(0..<20))

    // 20 × 20 = 400 content; viewport end at 100 leaves 300 > 200.
    #expect(fixture.evaluate(page, offset: 0) == .notNeeded)
    // End at 200 leaves 200 ≤ 2 × 100.
    #expect(fixture.evaluate(page, offset: 100) == .request(baseRevision: 1))
}

@Test
func test_pagination_raisesOneRequestPerRevisionAndRearmsAfterGrowth() {
    var fixture = PageFixture()
    let first = Snapshot(dataKey: "feed", revision: 1, items: items(0..<20))

    #expect(fixture.evaluate(first, offset: 200) == .request(baseRevision: 1))
    #expect(fixture.evaluate(first, offset: 220) == .duplicate)

    let second = Snapshot(dataKey: "feed", revision: 2, items: items(0..<40))
    fixture.gate.complete(with: second)

    #expect(fixture.evaluate(second, offset: 200) == .notNeeded)
    #expect(fixture.evaluate(second, offset: 600) == .request(baseRevision: 2))
}

@Test
func test_pagination_noProgressStallsUntilUserScrolls() {
    var fixture = PageFixture()
    let page = Snapshot(dataKey: "feed", revision: 1, items: items(0..<5))

    #expect(fixture.evaluate(page, offset: 0) == .request(baseRevision: 1))
    fixture.gate.complete(with: Snapshot(dataKey: "feed", revision: 2, items: items(0..<5)))

    let unchanged = Snapshot(dataKey: "feed", revision: 2, items: items(0..<5))
    #expect(fixture.evaluate(unchanged, offset: 0) == .noProgress)

    fixture.gate.userDidScroll()
    #expect(fixture.evaluate(unchanged, offset: 0) == .request(baseRevision: 2))
}

/// #88: a Flux model publishes after its hook returned, so completion sees the old snapshot.
/// The page that arrives later is progress and re-arms the gate without user scrolling.
@Test
func test_pagination_pagePublishedAfterCompletionEndsTheStall() {
    var fixture = PageFixture()
    let first = Snapshot(dataKey: "feed", revision: 1, items: items(0..<5))

    #expect(fixture.evaluate(first, offset: 0) == .request(baseRevision: 1))
    fixture.gate.complete(with: first)
    #expect(fixture.evaluate(first, offset: 0) == .duplicate)
    #expect(
        fixture.evaluate(Snapshot(dataKey: "feed", revision: 2, items: items(0..<5)), offset: 0)
            == .noProgress
    )

    let late = Snapshot(dataKey: "feed", revision: 2, items: items(0..<10))
    #expect(fixture.evaluate(late, offset: 0) == .request(baseRevision: 2))
}

@Test
func test_pagination_shortContentFillStopsAtAutomaticLimit() {
    var fixture = PageFixture()
    fixture.gate = PaginationGate(policy: PaginationPolicy(maximumAutomaticPages: 2))
    var count = 2
    var revision: UInt64 = 1
    var decisions: [PaginationDecision] = []
    for _ in 0..<4 {
        let snapshot = Snapshot(dataKey: "feed", revision: revision, items: items(0..<count))
        let decision = fixture.evaluate(snapshot, offset: 0)
        decisions.append(decision)
        guard case .request = decision else { break }

        count += 1
        revision += 1
        fixture.gate.complete(
            with: Snapshot(dataKey: "feed", revision: revision, items: items(0..<count))
        )
    }

    #expect(decisions == [.request(baseRevision: 1), .request(baseRevision: 2), .automaticLimit])
}

@Test
func test_pagination_failureWaitsForExplicitRetry() {
    var fixture = PageFixture()
    let page = Snapshot(dataKey: "feed", revision: 1, items: items(0..<5))

    #expect(fixture.evaluate(page, offset: 0) == .request(baseRevision: 1))
    fixture.gate.fail()
    #expect(fixture.evaluate(page, offset: 0) == .awaitingRetry)

    fixture.gate.retry()
    #expect(fixture.evaluate(page, offset: 0) == .request(baseRevision: 1))
}

@Test
func test_pagination_cancelledRequestMayBeRepeated() {
    var fixture = PageFixture()
    let page = Snapshot(dataKey: "feed", revision: 1, items: items(0..<5))

    #expect(fixture.evaluate(page, offset: 0) == .request(baseRevision: 1))
    fixture.gate.cancelInFlight()
    #expect(!fixture.gate.isRequestInFlight)
    #expect(fixture.evaluate(page, offset: 0) == .request(baseRevision: 1))
}

@Test
func test_pagination_endReachedAndNewDataKey() {
    var fixture = PageFixture()
    let ended = Snapshot(
        dataKey: "feed",
        revision: 3,
        items: items(0..<5),
        loadState: CollectionLoadState(phase: .loaded, endReached: true)
    )
    #expect(fixture.evaluate(ended, offset: 0) == .endReached)

    let first = Snapshot(dataKey: "feed", revision: 4, items: items(0..<5))
    #expect(fixture.evaluate(first, offset: 0) == .request(baseRevision: 4))

    // A new data key starts a new generation: the in-flight request of "feed" is forgotten.
    let other = Snapshot(dataKey: "filter", revision: 1, items: items(0..<5))
    #expect(fixture.evaluate(other, offset: 0) == .request(baseRevision: 1))
}

@Test
func test_pagination_remainingItemsCountsFromLastVisible() {
    var fixture = PageFixture()
    fixture.gate = PaginationGate(policy: PaginationPolicy(trigger: .remainingItems(5)))
    let page = Snapshot(dataKey: "feed", revision: 1, items: items(0..<20))

    // Viewport 0..<100 shows items 0...4; 15 remain.
    #expect(fixture.evaluate(page, offset: 0) == .notNeeded)
    // Viewport 200..<300 shows items 10...14; 5 remain.
    #expect(fixture.evaluate(page, offset: 200) == .request(baseRevision: 1))
}

// MARK: - Measurement cache

@Test
func test_measurementCache_missReasonsAndPrune() {
    var cache = ItemMeasurementCache<Int, String>()
    cache.record(40, for: 1, item: "a", crossExtent: 320, environmentRevision: 7)
    cache.record(60, for: 2, item: "b", crossExtent: 320, environmentRevision: 7)

    #expect(
        cache.length(for: 1, item: "a", crossExtent: 320, environmentRevision: 7) == .success(40)
    )
    #expect(
        cache.length(for: 1, item: "a2", crossExtent: 320, environmentRevision: 7)
            == .failure(MeasurementMiss(reason: .content))
    )
    #expect(
        cache.length(for: 1, item: "a", crossExtent: 300, environmentRevision: 7)
            == .failure(MeasurementMiss(reason: .crossExtent))
    )
    #expect(
        cache.length(for: 1, item: "a", crossExtent: 320, environmentRevision: 8)
            == .failure(MeasurementMiss(reason: .environment))
    )
    #expect(
        cache.length(for: 3, item: "c", crossExtent: 320, environmentRevision: 7)
            == .failure(MeasurementMiss(reason: .absent))
    )

    cache.prune(
        keeping: Snapshot(dataKey: "k", revision: 1, items: [CollectionItem(id: 2, value: "b")])
    )
    #expect(cache.count == 1)
}

// MARK: - Event dispatcher

@MainActor
private final class RecordingDelegate: CollectionDelegate {
    var selected: [Int] = []
    var visible: [[Int]] = []
    var phases: [ScrollPhase] = []

    func collectionDidSelect(_ id: Int) { selected.append(id) }
    func collectionVisibleItemsDidChange(_ ids: [Int]) { visible.append(ids) }
    func collectionScrollPhaseDidChange(_ phase: ScrollPhase) { phases.append(phase) }
}

@MainActor
@Test
func test_dispatcher_closureWinsAndClearingRestoresDelegate() {
    let dispatcher = CollectionEventDispatcher<Int>()
    let delegate = RecordingDelegate()
    dispatcher.delegate = delegate
    var closureSelections: [Int] = []

    dispatcher.select(1)
    dispatcher.onSelect = { closureSelections.append($0) }
    dispatcher.select(2)
    dispatcher.onSelect = nil
    dispatcher.select(3)

    #expect(delegate.selected == [1, 3])
    #expect(closureSelections == [2])
}

@MainActor
@Test
func test_dispatcher_coalescesEqualVisibleItemsAndPhases() {
    let dispatcher = CollectionEventDispatcher<Int>()
    let delegate = RecordingDelegate()
    dispatcher.delegate = delegate

    dispatcher.visibleItemsChanged([1, 2])
    dispatcher.visibleItemsChanged([1, 2])
    dispatcher.visibleItemsChanged([2, 3])
    dispatcher.scrollPhaseChanged(.dragging)
    dispatcher.scrollPhaseChanged(.dragging)
    dispatcher.scrollPhaseChanged(.idle)

    #expect(delegate.visible == [[1, 2], [2, 3]])
    #expect(delegate.phases == [.dragging, .idle])
}

@MainActor
@Test
func test_dispatcher_holdsDelegateWeakly() {
    let dispatcher = CollectionEventDispatcher<Int>()
    weak var released: RecordingDelegate?
    do {
        let delegate = RecordingDelegate()
        released = delegate
        dispatcher.delegate = delegate
    }

    #expect(released == nil)
    #expect(dispatcher.delegate == nil)
}
