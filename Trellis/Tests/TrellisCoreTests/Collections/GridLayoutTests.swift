import Testing

@testable import TrellisCore

// R12b (`implementation-plan-6.md`, ADR 0033): the grid is the same materialization window
// with rows of cells as its scrolled unit. Columns, spacing, cell sizes, visible range, column
// and width changes with anchor preservation, and bounded live nodes.

private struct Cell: Sendable, Equatable {
    var height: Double = 100
}

@MainActor
private final class CellProvider: ItemProvider {
    func makeNode(for item: Cell, id: Int) -> Node {
        let node = Node()
        node.style.height = .points(item.height)
        return node
    }

    func update(_ node: Node, with item: Cell, id: Int) {
        node.style.height = .points(item.height)
    }
}

private func cells(_ count: Int, height: (Int) -> Double = { _ in 100 }) -> [CollectionItem<
    Int, Cell
>] {
    (0..<count).map { CollectionItem(id: $0, value: Cell(height: height($0))) }
}

@MainActor
private func makeGrid(
    _ layout: GridLayout,
    count: Int = 100,
    width: Double = 320,
    offset: Double = 0,
    rowSpacing: Double = 0,
    height: @escaping (Int) -> Double = { _ in 100 }
) -> MaterializationWindow<CellProvider> {
    let window = MaterializationWindow(
        provider: CellProvider(),
        estimatedLength: 100,
        spacing: rowSpacing,
        ranges: PreparationRanges(displayLeading: 1, displayTrailing: 0),
        maximumMaterializedCount: 200,
        dataKey: "grid"
    )
    window.grid = layout
    window.apply(
        CollectionSnapshot(dataKey: "grid", revision: 1, items: cells(count, height: height))
    )
    window.updateViewport(offset: offset, length: 400, crossExtent: width)
    return window
}

@MainActor
private func layOut(_ window: MaterializationWindow<CellProvider>, width: Double) throws {
    for _ in 0..<4 {
        let height = window.extents.totalExtent
        let input = window.content.makeLayoutInputSnapshot(
            constraint: SizeConstraint(width: .exact(width), height: .exact(height))
        )
        let frame = LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: width, height: height)
        _ = window.content.applyLayoutResult(
            try FlexboxEngine.layoutContainer(input: input, frame: frame)
        )
        guard window.recordMeasurements() != nil else { return }
    }
}

@Test
func test_gridLayout_columnCountAndCellWidth() {
    let fixed = GridLayout(columns: .fixed(3), columnSpacing: 10)
    #expect(fixed.columnCount(for: 320) == 3)
    #expect(fixed.cellWidth(for: 320, columns: 3) == 100)

    let adaptive = GridLayout(columns: .adaptive(minimumWidth: 100), columnSpacing: 8)
    #expect(adaptive.columnCount(for: 400) == 3)
    #expect(adaptive.columnCount(for: 250) == 2)
    #expect(adaptive.columnCount(for: 50) == 1)
    #expect(GridLayout(columns: .fixed(0)).columnCount(for: 300) == 1)
}

@MainActor
@Test
func test_grid_placesCellsInColumnsWithSpacing() throws {
    let window = makeGrid(GridLayout(columns: .fixed(3), columnSpacing: 10), rowSpacing: 6)
    try layOut(window, width: 320)

    #expect(window.columnCount == 3)
    #expect(window.extents.count == 34)  // ceil(100 / 3)
    let frames = (0..<4).compactMap { window.node(for: $0)?.calculatedFrame }
    #expect(frames.map(\.origin.x) == [0, 110, 220, 0])
    #expect(frames.map(\.origin.y) == [0, 0, 0, 106])
    #expect(frames.allSatisfy { $0.width == 100 })
    #expect(window.itemOffset(at: 5) == 106)
    #expect(window.itemIndex(at: 110) == 3)
}

@MainActor
@Test
func test_grid_rowIsAsTallAsItsTallestMeasuredCell() throws {
    let window = makeGrid(GridLayout(columns: .fixed(2)), height: { $0 == 1 ? 180 : 60 })
    try layOut(window, width: 320)

    #expect(window.extents.length(of: 0) == 180)
    #expect(window.extents.length(of: 1) == 60)
    #expect(window.itemOffset(at: 2) == 180)
}

@MainActor
@Test
func test_grid_aspectRatioCellsNeedNoMeasurement() throws {
    let window = makeGrid(
        GridLayout(columns: .fixed(4), columnSpacing: 8, cellHeight: .aspectRatio(1.5))
    )

    // (320 − 3 × 8) / 4 = 74 wide, 111 tall; no layout pass needed for positions.
    #expect(window.extents.length(of: 0) == 111)
    // #87: the first width arrives after the snapshot; the grid stays at the top.
    #expect(window.offset == 0)
    #expect(window.node(for: 0)?.style.height == .points(111))
    try layOut(window, width: 320)
    #expect(window.recordMeasurements() == nil)
}

@MainActor
@Test
func test_grid_visibleRangeIsWholeRowsAndLiveNodesAreBounded() {
    let window = makeGrid(GridLayout(columns: .fixed(4)), count: 10_000, offset: 50_000)

    // Rows 500..<504 are visible (400 pt), 4 more lead: 8 rows × 4 cells.
    #expect(window.window.visible == 2_000..<2_016)
    #expect(window.materializedIDs.count == 32)
    #expect(window.content.subnodes.count == 32)
    #expect(window.visibleIDs.count % 4 == 0)
}

@MainActor
@Test
func test_grid_widthChangeReflowsColumnsAndKeepsAnchor() throws {
    let window = makeGrid(
        GridLayout(columns: .adaptive(minimumWidth: 100), columnSpacing: 8),
        width: 400,
        offset: 1_000
    )
    #expect(window.columnCount == 3)
    let anchorIndex = try #require(window.itemIndex(at: window.offset))
    let anchorID = window.snapshot.items[anchorIndex].id
    let before = window.itemOffset(at: anchorIndex) - window.offset

    let adjustment = window.updateViewport(offset: window.offset, length: 400, crossExtent: 250)

    #expect(window.columnCount == 2)
    #expect(adjustment?.anchor == .preserved(anchorID))
    let index = try #require(window.snapshot.index(of: anchorID))
    #expect(abs(window.itemOffset(at: index) - window.offset - before) <= 0.5)
}

@MainActor
@Test
func test_grid_layoutChangeKeepsAnchorAndPrependKeepsAnchor() throws {
    let window = makeGrid(GridLayout(columns: .fixed(2)), offset: 1_000)
    let anchorIndex = try #require(window.itemIndex(at: 1_000))
    let anchorID = window.snapshot.items[anchorIndex].id

    window.grid = GridLayout(columns: .fixed(5))
    let reflowed = try #require(window.snapshot.index(of: anchorID))
    #expect(window.itemOffset(at: reflowed) - window.offset == 0)

    let adjustment = window.apply(
        CollectionSnapshot(
            dataKey: "grid",
            revision: 2,
            items: cells(5).map { CollectionItem(id: -1 - $0.id, value: $0.value) } + cells(100)
        )
    )
    #expect(adjustment?.anchor == .preserved(anchorID))
    let shifted = try #require(window.snapshot.index(of: anchorID))
    #expect(window.itemOffset(at: shifted) - window.offset == 0)
}

@MainActor
@Test
func test_grid_paginationCountsItemsAfterTheLastVisibleRow() {
    let window = makeGrid(GridLayout(columns: .fixed(4)), count: 40, offset: 400)
    var gate = PaginationGate(policy: PaginationPolicy(trigger: .remainingItems(12)))

    // Visible rows 4..<8 → items 16..<32; 8 items remain.
    #expect(window.window.visible == 16..<32)
    #expect(window.evaluatePagination(&gate) == .request(baseRevision: 1))
}
