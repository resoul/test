import Testing

@testable import TrellisCore

// R10 (`implementation-plan-6.md` P6.9 «Планирование», P6.12, ADR 0030): the shared host
// preparation budget, diagnostic correlation, geometry-neutral environment changes and the
// horizontal right-to-left mapping.

private struct Cell: Sendable, Equatable {
    var length: Double = 20
}

@MainActor
private final class CellProvider: ItemProvider {
    var made = 0

    func makeNode(for item: Cell, id: Int) -> Node {
        made += 1
        return Node()
    }

    func update(_ node: Node, with item: Cell, id: Int) {}
}

private func cells(_ count: Int) -> [CollectionItem<Int, Cell>] {
    (0..<count).map { CollectionItem(id: $0, value: Cell()) }
}

/// 100 items of 20 pt; a 200 pt viewport shows 10, display adds 10 leading (1 × viewport).
@MainActor
private func makeWindow(
    budget: MaterializationBudget? = nil,
    priority: MaterializationPriority = .active,
    axis: ScrollAxis = .vertical,
    offset: Double = 0
) -> MaterializationWindow<CellProvider> {
    let window = MaterializationWindow(
        provider: CellProvider(),
        axis: axis,
        estimatedLength: 20,
        ranges: PreparationRanges(displayLeading: 1, displayTrailing: 0),
        dataKey: "feed"
    )
    window.priority = priority
    window.budget = budget
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 1, items: cells(100)))
    window.updateViewport(offset: offset, length: 200, crossExtent: 320)
    return window
}

// MARK: - Budget

@MainActor
@Test
func test_budget_visibleAlwaysMaterializesAndMarginWaitsForCreations() {
    let budget = MaterializationBudget(creationsPerPass: 4, maximumLiveNodes: 256)
    let window = makeWindow(budget: budget)

    // 10 visible exceed the 4 tokens but are never refused; no margin this pass.
    #expect(window.materializedIDs == Array(0..<10))
    #expect(budget.pendingCount == 1)

    budget.beginPass()
    #expect(window.materializedIDs == Array(0..<14))

    budget.beginPass()
    budget.beginPass()
    #expect(window.materializedIDs == Array(0..<20))
    #expect(budget.pendingCount == 0)
}

@MainActor
@Test
func test_budget_activeWindowIsServedBeforeAdjacent() {
    let budget = MaterializationBudget(creationsPerPass: 0, maximumLiveNodes: 256)
    let adjacent = makeWindow(budget: budget, priority: .adjacent)
    let active = makeWindow(budget: budget, priority: .active)
    #expect(budget.pendingCount == 2)

    budget.creationsPerPass = 6
    budget.beginPass()

    #expect(active.materializedIDs.count == 16)
    #expect(adjacent.materializedIDs.count == 10)
    // Both still miss margin items: the active one 4, the adjacent one all 10.
    #expect(budget.pendingCount == 2)
}

@MainActor
@Test
func test_budget_liveLimitPrefersMoreUrgentWindow() {
    let budget = MaterializationBudget(creationsPerPass: 100, maximumLiveNodes: 30)
    let active = makeWindow(budget: budget, priority: .active)
    let adjacent = makeWindow(budget: budget, priority: .adjacent)

    #expect(active.materializedIDs.count == 20)
    // 30 − 20 held by the active window leaves only the 10 visible items.
    #expect(adjacent.materializedIDs.count == 10)
    #expect(budget.liveNodeCount == 30)
}

@MainActor
@Test
func test_budget_loweringLimitTrimsMarginsAtNextPassButKeepsVisible() {
    let budget = MaterializationBudget(creationsPerPass: 100, maximumLiveNodes: 256)
    let active = makeWindow(budget: budget, priority: .active)
    let adjacent = makeWindow(budget: budget, priority: .adjacent)
    weak let margin = adjacent.node(for: 15)
    #expect(margin != nil)

    // 24 − the adjacent window's 10 visible items leaves the active window 14 live nodes.
    budget.maximumLiveNodes = 24
    budget.beginPass()

    #expect(active.materializedIDs == Array(0..<14))
    #expect(adjacent.materializedIDs == Array(0..<10))
    #expect(margin == nil)
}

@MainActor
@Test
func test_budget_deferredDemandFollowsMovedViewport() {
    let budget = MaterializationBudget(creationsPerPass: 0, maximumLiveNodes: 256)
    let window = makeWindow(budget: budget)
    #expect(window.node(for: 0) != nil)

    // The user moves on before the margin of items 10..<20 is ever created.
    window.updateViewport(offset: 1_000, length: 200, crossExtent: 320)
    budget.creationsPerPass = 100
    budget.beginPass()

    #expect(window.materializedIDs == Array(50..<70))
    #expect(window.node(for: 15) == nil)
}

@MainActor
@Test
func test_budget_equalPrioritiesRotate() {
    let budget = MaterializationBudget(creationsPerPass: 0, maximumLiveNodes: 256)
    let first = makeWindow(budget: budget)
    let second = makeWindow(budget: budget)

    budget.creationsPerPass = 3
    budget.beginPass()
    let firstAfterOne = first.materializedIDs.count
    let secondAfterOne = second.materializedIDs.count
    budget.beginPass()

    #expect(firstAfterOne + secondAfterOne == 23)
    #expect(first.materializedIDs.count == 13 || second.materializedIDs.count == 13)
    #expect(first.materializedIDs.count + second.materializedIDs.count == 26)
    #expect(abs(first.materializedIDs.count - second.materializedIDs.count) <= 3)
}

@MainActor
@Test
func test_budget_disposedWindowUnregistersAndHostsAreIndependent() {
    let hostA = MaterializationBudget(creationsPerPass: 100, maximumLiveNodes: 20)
    let hostB = MaterializationBudget(creationsPerPass: 100, maximumLiveNodes: 20)
    let a = makeWindow(budget: hostA)
    let b = makeWindow(budget: hostB)

    #expect(a.materializedIDs.count == 20)
    #expect(b.materializedIDs.count == 20)

    a.dispose()
    #expect(hostA.liveNodeCount == 0)
    #expect(hostB.liveNodeCount == 20)
}

// MARK: - Diagnostics correlation (P6.12)

@MainActor
@Test
func test_diagnostics_twoHostsAndNoneBeforeMount() {
    var lines: [String] = []
    let unmounted = MaterializationWindow(provider: CellProvider(), estimatedLength: 20)
    unmounted.diagnosticSink = { lines.append($0) }
    unmounted.apply(CollectionSnapshot(dataKey: "feed", revision: 3, items: cells(5)))

    let first = MaterializationWindow(provider: CellProvider(), estimatedLength: 20)
    first.correlation = CollectionCorrelation(host: 1, generation: 7)
    first.diagnosticSink = { lines.append($0) }
    first.apply(CollectionSnapshot(dataKey: "feed", revision: 3, items: cells(5)))

    let second = MaterializationWindow(provider: CellProvider(), estimatedLength: 20)
    second.correlation = CollectionCorrelation(host: 2, generation: 7)
    second.diagnosticSink = { lines.append($0) }
    second.apply(CollectionSnapshot(dataKey: "feed", revision: 3, items: cells(5)))

    let applied = lines.filter { $0.contains("dataset-applied") }
    #expect(
        applied == [
            "[trellis.commit] dataset-applied host=none gen=none \(unmounted.content.id) "
                + "parent=#none dataKey=feed dataRevision=3 items=5 droppedDuplicates=0 "
                + "inserted=5 removed=0 updated=0 moved=0 measureHit=0",
            "[trellis.commit] dataset-applied host=1 gen=7 \(first.content.id) "
                + "parent=#none dataKey=feed dataRevision=3 items=5 droppedDuplicates=0 "
                + "inserted=5 removed=0 updated=0 moved=0 measureHit=0",
            "[trellis.commit] dataset-applied host=2 gen=7 \(second.content.id) "
                + "parent=#none dataKey=feed dataRevision=3 items=5 droppedDuplicates=0 "
                + "inserted=5 removed=0 updated=0 moved=0 measureHit=0",
        ]
    )
}

@MainActor
@Test
func test_diagnostics_paginationLogsDecisionsButNotIdleTicks() {
    var lines: [String] = []
    let window = makeWindow()
    window.diagnosticSink = { lines.append($0) }
    var gate = PaginationGate()

    #expect(window.evaluatePagination(&gate) == .notNeeded)
    window.updateViewport(offset: 1_700, length: 200, crossExtent: 320)
    lines.removeAll()
    #expect(window.evaluatePagination(&gate) == .request(baseRevision: 1))
    #expect(window.evaluatePagination(&gate) == .duplicate)

    #expect(lines.count == 2)
    #expect(lines[0].contains("pagination-demand"))
    #expect(lines[0].contains("dataKey=feed dataRevision=1"))
}

// MARK: - Environment

@MainActor
@Test
func test_environment_themeChangeKeepsMeasurementsLayoutDirectionDropsThem() throws {
    let window = makeWindow()
    let host = Node()
    host.addSubnode(window.content)
    window.updateViewport(offset: 0, length: 200, crossExtent: 320)
    for id in window.materializedIDs {
        window.node(for: id)?.style.height = .points(30)
    }
    let snapshot = window.content.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(320), height: .exact(window.extents.totalExtent))
    )
    let frame = LayoutFrame(
        origin: LayoutPoint(x: 0, y: 0),
        width: 320,
        height: window.extents.totalExtent
    )
    _ = window.content.applyLayoutResult(
        try FlexboxEngine.layoutContainer(input: snapshot, frame: frame)
    )
    #expect(window.recordMeasurements() != nil)
    #expect(window.extents.length(of: 0) == 30)

    host.setEnvironment(
        ThemeKey.self,
        to: Theme(id: "dark", colors: Theme.defaultValue.colors)
    )
    window.updateViewport(offset: 0, length: 200, crossExtent: 320)
    #expect(window.extents.length(of: 0) == 30)

    host.setLayoutDirection(.rightToLeft)
    window.updateViewport(offset: 0, length: 200, crossExtent: 320)
    #expect(window.extents.length(of: 0) == 20)
}

@MainActor
@Test
func test_rightToLeftHorizontal_itemZeroAtTrailingEndAndViewportMapped() throws {
    let host = Node()
    host.setLayoutDirection(.rightToLeft)
    let window = MaterializationWindow(
        provider: CellProvider(),
        axis: .horizontal,
        estimatedLength: 20,
        ranges: .visibleOnly,
        dataKey: "feed"
    )
    host.addSubnode(window.content)
    window.apply(CollectionSnapshot(dataKey: "feed", revision: 1, items: cells(100)))

    // Physical offset at the right end (2000 − 200) shows logical items 0..<10.
    window.updateViewport(offset: 1_800, length: 200, crossExtent: 50)
    #expect(window.window.visible == 0..<10)
    // Physical offset 0 (left end) shows the last items.
    window.updateViewport(offset: 0, length: 200, crossExtent: 50)
    #expect(window.window.visible == 90..<100)
    window.updateViewport(offset: 1_800, length: 200, crossExtent: 50)
    for id in window.materializedIDs {
        window.node(for: id)?.style.width = .points(20)
    }

    let snapshot = window.content.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(2_000), height: .exact(50))
    )
    let frame = LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 2_000, height: 50)
    _ = window.content.applyLayoutResult(
        try FlexboxEngine.layoutContainer(input: snapshot, frame: frame)
    )
    #expect(window.node(for: 0)?.calculatedFrame?.origin.x == 1_980)
    #expect(window.node(for: 9)?.calculatedFrame?.origin.x == 1_800)
}
