import Testing

@testable import TrellisCore

// R10 prototype acceptance (`implementation-plan-6.md`): 10 000 models create a bounded
// number of nodes, items that stay in the window keep their node identity, and nodes of items
// that leave it are released (checked through weak references). Measurements come from a real
// flexbox solve, not hand-written placements.

private struct Row: Sendable, Equatable {
    var height: Double
    var kind = "text"
}

@MainActor
private final class RowNode: Node {
    var updates = 0
}

@MainActor
private final class RowProvider: ItemProvider {
    var made = 0

    func makeNode(for item: Row, id: Int) -> RowNode {
        made += 1
        let node = RowNode()
        node.style.height = .points(item.height)
        return node
    }

    func update(_ node: RowNode, with item: Row, id: Int) {
        node.updates += 1
        node.style.height = .points(item.height)
    }

    func canUpdate(_ node: RowNode, to item: Row) -> Bool {
        item.kind == "text"
    }
}

private func rows(_ ids: Range<Int>, height: Double = 20) -> [CollectionItem<Int, Row>] {
    ids.map { CollectionItem(id: $0, value: Row(height: height)) }
}

@MainActor
private func makeWindow(
    provider: RowProvider = RowProvider(),
    count: Int = 10_000,
    maximum: Int = 64
) -> MaterializationWindow<RowProvider> {
    let window = MaterializationWindow(
        provider: provider,
        estimatedLength: 20,
        ranges: PreparationRanges(displayLeading: 1, displayTrailing: 0.5),
        maximumMaterializedCount: maximum,
        dataKey: "feed"
    )
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 1, items: rows(0..<count)))
    window.updateViewport(offset: 0, length: 200, crossExtent: 320)
    return window
}

@MainActor
private func layOut(_ window: MaterializationWindow<RowProvider>) throws {
    let content = window.content
    let width = window.extents.totalExtent
    let snapshot = content.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(320), height: .exact(width))
    )
    let frame = LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 320, height: width)
    let result = try FlexboxEngine.layoutContainer(input: snapshot, frame: frame)
    _ = content.applyLayoutResult(result)
}

@MainActor
@Test
func test_materialization_tenThousandModelsCreateBoundedNodes() {
    let provider = RowProvider()
    let window = makeWindow(provider: provider)

    // Viewport 0..<200 = items 0..<10, plus 1 × 200 leading = 20 items.
    #expect(window.window.visible == 0..<10)
    #expect(window.materializedIDs == Array(0..<20))
    #expect(window.content.subnodes.count == 20)
    #expect(window.extents.totalExtent == 200_000)
    #expect(window.content.style.height == .points(200_000))

    window.updateViewport(offset: 100_000, length: 200, crossExtent: 320)
    #expect(window.content.subnodes.count <= 64)
    #expect(window.materializedIDs.first == 4_995)
    #expect(provider.made <= 60)
}

@MainActor
@Test
func test_materialization_capBoundsLiveNodesForHugeViewport() {
    let window = makeWindow(maximum: 16)
    window.updateViewport(offset: 0, length: 5_000, crossExtent: 320)

    #expect(window.content.subnodes.count == 16)
    #expect(window.window.visible.count > 16)
}

@MainActor
@Test
func test_materialization_keepsIdentityInWindowAndReleasesLeftNodes() {
    let window = makeWindow()
    let kept = window.node(for: 15)
    weak let left = window.node(for: 0)
    #expect(left != nil)

    window.updateViewport(offset: 200, length: 200, crossExtent: 320)

    #expect(window.node(for: 15) === kept)
    #expect(window.node(for: 0) == nil)
    #expect(left == nil)
    #expect(
        window.content.subnodes.map { ObjectIdentifier($0) }
            == window.materializedIDs.map { ObjectIdentifier(window.node(for: $0)!) }
    )
}

@MainActor
@Test
func test_materialization_updatesChangedModelAndReplacesIncompatibleNode() {
    let window = makeWindow(count: 30)
    let updated = window.node(for: 1)
    let replaced = window.node(for: 2)
    let untouched = window.node(for: 3)

    var items = rows(0..<30)
    items[1] = CollectionItem(id: 1, value: Row(height: 44))
    items[2] = CollectionItem(id: 2, value: Row(height: 20, kind: "media"))
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 2, items: items))

    #expect(window.node(for: 1) === updated)
    #expect(updated?.updates == 1)
    #expect(window.node(for: 2) !== replaced)
    #expect(replaced?.isDisposed == true)
    #expect(window.node(for: 3) === untouched)
    #expect(untouched?.updates == 0)
}

@MainActor
@Test
func test_materialization_removedItemIsDisposedAndMeasurementPruned() throws {
    let window = makeWindow(count: 30)
    try layOut(window)
    _ = window.recordMeasurements()
    #expect(window.measurementCount == 20)
    let removed = window.node(for: 5)

    let remaining = rows(0..<30).filter { $0.id != 5 }
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 2, items: remaining))

    #expect(removed?.isDisposed == true)
    #expect(window.node(for: 5) == nil)
    #expect(window.measurementCount == 19)
}

@MainActor
@Test
func test_materialization_newDataKeyDropsLiveNodesAndMeasurements() throws {
    let window = makeWindow(count: 30)
    try layOut(window)
    _ = window.recordMeasurements()
    let old = window.node(for: 0)

    window.apply(CollectionSnapshot(dataKey: "other", revision: 1, items: rows(0..<30)))

    #expect(old?.isDisposed == true)
    #expect(window.node(for: 0) !== old)
    #expect(window.measurementCount == 0)
}

@MainActor
@Test
func test_materialization_measuredLengthsRepositionItems() throws {
    let window = makeWindow(count: 100)
    var items = rows(0..<100)
    items[0] = CollectionItem(id: 0, value: Row(height: 120))
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 2, items: items))
    // The estimate is still 20 before a layout pass.
    #expect(window.extents.offset(of: 1) == 20)

    try layOut(window)
    #expect(window.recordMeasurements() != nil)

    #expect(window.extents.offset(of: 1) == 120)
    #expect(window.node(for: 1)?.style.offsets.top == 120)
    #expect(window.extents.totalExtent == 120 + 99 * 20)
    // A second pass with the same lengths is stable.
    try layOut(window)
    #expect(window.recordMeasurements() == nil)
}

@MainActor
@Test
func test_materialization_crossExtentChangeInvalidatesMeasurements() throws {
    let window = makeWindow(count: 30)
    try layOut(window)
    _ = window.recordMeasurements()
    #expect(window.extents.length(of: 0) == 20)

    window.estimatedLength = 50
    // Same width: measured lengths still apply.
    #expect(window.extents.length(of: 0) == 20)

    window.updateViewport(offset: 0, length: 200, crossExtent: 300)
    // New width: the estimate applies until the next measurement.
    #expect(window.extents.length(of: 0) == 50)
}

@MainActor
@Test
func test_materialization_disposeReleasesEverything() {
    let window = makeWindow(count: 100)
    weak let row = window.node(for: 0)

    window.dispose()

    #expect(row == nil)
    #expect(window.content.isDisposed)
    #expect(window.materializedIDs.isEmpty)
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 9, items: rows(0..<5)))
    #expect(window.materializedIDs.isEmpty)
}
