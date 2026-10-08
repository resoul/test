import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// R12 (`implementation-plan-6.md`, closing result C): ListNode, GridNode and TableNode mounted
// in a real `NodeHostBridge` — reveal of known virtualized items (P6.9) with the same dataset
// and results for all three, focus and accessibility without duplicates, a 10 000-model consumer
// with prepend/delete/load-more while scrolling, transient state after eviction and 100
// open/close cycles.

@MainActor
private final class Backing: NativeScrollBacking {
    let nodeID: NodeID
    weak var delegate: (any NativeScrollBackingDelegate)?
    let containerLayer = CALayer()
    var contentOffset = LayoutPoint(x: 0, y: 0)
    private(set) var contentSize = MeasuredSize(width: 0, height: 0)

    init(nodeID: NodeID, delegate: any NativeScrollBackingDelegate) {
        self.nodeID = nodeID
        self.delegate = delegate
    }

    var viewportSize: MeasuredSize {
        MeasuredSize(
            width: Double(containerLayer.bounds.width),
            height: Double(containerLayer.bounds.height)
        )
    }

    func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
        containerLayer.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        containerLayer.position = CGPoint(x: frame.origin.x, y: frame.origin.y)
    }

    var contentOriginInHost: LayoutPoint {
        LayoutPoint(x: Double(containerLayer.position.x), y: Double(containerLayer.position.y))
    }

    func setContentSize(_ size: MeasuredSize) { contentSize = size }
    func setInsets(_ insets: DirectionalEdgeInsets) {}
    func apply(configuration: ScrollConfiguration) {}
    func installContentLayer(_ layer: CALayer) { containerLayer.addSublayer(layer) }
    func removeContentLayer() {}
    func dispose() {}

    func scroll(
        to offset: LayoutPoint,
        animated: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        contentOffset = offset
        completion(true)
    }

    func drag(to y: Double, phase: ScrollPhase = .dragging) {
        contentOffset = LayoutPoint(x: 0, y: y)
        delegate?.scrollBacking(for: nodeID, didChangeOffset: contentOffset, phase: phase)
    }
}

@MainActor
private final class Host {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    var backings: [NodeID: Backing] = [:]

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
    }

    @discardableResult
    func attach(_ root: Node) -> Bool {
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 400),
            scale: 1,
            scrollBackingFactory: { [weak self] id, delegate in
                let backing = Backing(nodeID: id, delegate: delegate)
                self?.backings[id] = backing
                return backing
            }
        )
    }

    func backing<P, S>(of container: CollectionNode<P, S>) -> Backing? {
        backings[container.scrollNode.id]
    }

    /// Waits until a few consecutive rounds bring no new commit.
    func settle() async {
        for _ in 0..<8 {
            let committed = bridge.committedCount
            for _ in 0..<500 where bridge.committedCount == committed {
                await Task.yield()
            }
            if bridge.committedCount == committed { return }
        }
    }

    /// Every accessibility element with an identifier, flattened.
    func accessibilityIdentifiers() -> [String] {
        var result: [String] = []
        func visit(_ element: AccessibilityElement) {
            if element.isElement, let identifier = element.identifier {
                result.append(identifier)
            }
            element.children.forEach(visit)
        }
        bridge.accessibilityTree?.elements.forEach(visit)
        return result
    }
}

private struct Row: Sendable, Equatable {
    let height: Double

    static func height(_ id: Int) -> Double { Double(30 + (id * 37) % 50) }
}

/// Variable-height, focusable, accessible rows. Heights differ from every estimate, so a reveal
/// must measure before it settles.
@MainActor
private final class RowProvider: ItemProvider {
    private(set) var made = 0

    func makeNode(for item: Row, id: Int) -> Node {
        made += 1
        let node = Node()
        node.focus.isFocusable = true
        node.accessibility.isElement = true
        node.accessibility.label = "Row \(id)"
        node.accessibility.identifier = "item-\(id)"
        update(node, with: item, id: id)
        return node
    }

    func update(_ node: Node, with item: Row, id: Int) {
        node.style.height = .points(item.height)
    }
}

private func rows(_ ids: some Sequence<Int>) -> [CollectionItem<Int, Row>] {
    ids.map { CollectionItem(id: $0, value: Row(height: Row.height($0))) }
}

@MainActor
private func source(_ ids: some Sequence<Int>) -> StateSubject<CollectionSnapshot<Int, Row>> {
    StateSubject(CollectionSnapshot(dataKey: "rows", revision: 1, items: rows(ids)))
}

private func frameStyle() -> LayoutStyle {
    var style = LayoutStyle()
    style.width = 320
    style.height = 400
    return style
}

@MainActor
private func makeList(_ ids: some Sequence<Int>, maximum: Int = 64) -> ListNode<RowProvider> {
    ListNode(
        source: source(ids),
        provider: RowProvider(),
        maximumMaterializedCount: maximum,
        style: frameStyle()
    )
}

@MainActor
private func makeGrid(_ ids: some Sequence<Int>) -> GridNode<RowProvider> {
    GridNode(
        source: source(ids),
        provider: RowProvider(),
        layout: GridLayout(columns: .fixed(3), columnSpacing: 4),
        rowSpacing: 4,
        estimatedRowHeight: 60,
        style: frameStyle()
    )
}

@MainActor
private func makeTable(_ ids: some Sequence<Int>) -> TableNode<RowProvider> {
    TableNode(source: source(ids), provider: RowProvider(), style: frameStyle())
}

@MainActor
private func mount(_ container: Node, in host: Host) async -> Node {
    let root = Node()
    root.addSubnode(container)
    #expect(host.attach(root))
    // The first commit sizes the viewport; items materialize from it and commit in the next.
    for _ in 0..<20_000 where host.bridge.committedCount < 2 {
        await Task.yield()
    }
    await host.settle()
    return root
}

/// Reveals `id` and waits for the result.
@MainActor
private func reveal<P, S>(
    _ id: Int,
    in container: CollectionNode<P, S>,
    host: Host,
    alignment: ScrollAlignment = .start
) async -> CollectionScrollResult? where P.ItemID == Int {
    var result: CollectionScrollResult?
    container.scrollTo(id, alignment: alignment) { result = $0 }
    for _ in 0..<20 where result == nil {
        await host.settle()
    }
    await host.settle()
    return result
}

/// Distance of `id`'s committed frame from the top of the viewport.
@MainActor
private func viewportTop<P, S>(of id: Int, in container: CollectionNode<P, S>, host: Host)
    -> Double? where P.ItemID == Int
{
    guard let frame = container.window.node(for: id)?.calculatedFrame,
        let backing = host.backing(of: container)
    else { return nil }

    return frame.origin.y - backing.contentOffset.y
}

// MARK: - Reveal of known virtualized items (P6.9)

@MainActor
@Test
func test_resultC_revealOfAVirtualizedItemSettlesAtItsMeasuredFrameInAllThreeContainers()
    async
{
    let target = 7_321
    let list = makeList(0..<10_000)
    let grid = makeGrid(0..<10_000)
    let table = makeTable(0..<10_000)

    for container in [list as Node, grid, table] {
        let host = Host()
        _ = await mount(container, in: host)
        let result: CollectionScrollResult?
        let top: Double?
        let window: (count: Int, materialized: Int)
        switch container {
        case let list as ListNode<RowProvider>:
            #expect(list.window.node(for: target) == nil)
            result = await reveal(target, in: list, host: host)
            top = viewportTop(of: target, in: list, host: host)
            window = (list.window.snapshot.count, list.window.materializedIDs.count)
        case let grid as GridNode<RowProvider>:
            #expect(grid.window.node(for: target) == nil)
            result = await reveal(target, in: grid, host: host)
            top = viewportTop(of: target, in: grid, host: host)
            window = (grid.window.snapshot.count, grid.window.materializedIDs.count)
        case let table as TableNode<RowProvider>:
            #expect(table.window.node(for: target) == nil)
            result = await reveal(target, in: table, host: host)
            top = viewportTop(of: target, in: table, host: host)
            window = (table.window.snapshot.count, table.window.materializedIDs.count)
        default:
            Issue.record("unexpected container")
            return
        }

        #expect(result == .completed)
        #expect(
            top.map { abs($0) <= 0.5 } == true,
            "\(type(of: container)) top=\(String(describing: top))"
        )
        #expect(window.count == 10_000)
        #expect(window.materialized <= 96)
        // Accessibility: the revealed item is present exactly once, and no identifier repeats.
        let identifiers = host.accessibilityIdentifiers()
        #expect(identifiers.filter { $0 == "item-\(target)" }.count == 1)
        #expect(Set(identifiers).count == identifiers.count)
        host.bridge.detach()
    }
}

@MainActor
@Test
func test_resultC_revealAlignmentsEndAndCenterUseTheMeasuredLength() async {
    let host = Host()
    let list = makeList(0..<2_000)
    _ = await mount(list, in: host)

    #expect(await reveal(1_500, in: list, host: host, alignment: .end) == .completed)
    let frame = list.window.node(for: 1_500)?.calculatedFrame
    let offset = host.backing(of: list)!.contentOffset.y
    #expect(frame?.height == Row.height(1_500))
    #expect(frame.map { abs($0.origin.y + $0.height - offset - 400) <= 0.5 } == true)

    #expect(await reveal(900, in: list, host: host, alignment: .center) == .completed)
    let centered = list.window.node(for: 900)!.calculatedFrame!
    let middle = centered.origin.y + centered.height / 2 - host.backing(of: list)!.contentOffset.y
    #expect(abs(middle - 200) <= 0.5)
}

@MainActor
@Test
func test_resultC_revealReportsNotFoundNotAttachedCancelledAndRemoved() async {
    let list = makeList(0..<5_000)
    var early: CollectionScrollResult?
    list.scrollTo(10) { early = $0 }
    #expect(early == .notAttached)

    let host = Host()
    _ = await mount(list, in: host)

    // Unknown ID: an explicit notFound, the viewport does not move.
    var unknown: CollectionScrollResult?
    list.scrollTo(99_999) { unknown = $0 }
    #expect(unknown == .notFound)
    #expect(host.backing(of: list)?.contentOffset.y == 0)

    // A newer reveal replaces the pending one; the late result of the old one never moves the
    // viewport.
    var first: CollectionScrollResult?
    var second: CollectionScrollResult?
    list.scrollTo(3_000) { first = $0 }
    list.scrollTo(4_000) { second = $0 }
    #expect(first == .cancelled)
    for _ in 0..<20 where second == nil { await host.settle() }
    #expect(second == .completed)
    #expect(viewportTop(of: 4_000, in: list, host: host).map { abs($0) <= 0.5 } == true)

    // User scrolling cancels a pending reveal.
    var interrupted: CollectionScrollResult?
    list.scrollTo(100) { interrupted = $0 }
    if interrupted == nil {
        host.backing(of: list)?.drag(to: list.window.offset + 5)
    }
    #expect(interrupted == .cancelled || interrupted == .completed)

    // The target disappears from the data before the reveal finished.
    var removed: CollectionScrollResult?
    list.scrollTo(2_500) { removed = $0 }
    if removed == nil {
        list.source.send(
            CollectionSnapshot(
                dataKey: "rows",
                revision: 2,
                items: rows((0..<5_000).filter { $0 != 2_500 })
            )
        )
        for _ in 0..<20 where removed == nil { await host.settle() }
        #expect(removed == .notFound)
    }

    host.bridge.detach()
    var detached: CollectionScrollResult?
    list.scrollTo(1) { detached = $0 }
    #expect(detached == .notAttached)
}

// MARK: - Focus and accessibility

@MainActor
@Test
func test_resultC_focusTraversalReachesVirtualizedRowsInOrderWithoutDuplicates() async {
    let host = Host()
    let list = makeList(0..<1_000)
    _ = await mount(list, in: host)
    let first = list.window.node(for: 0)!
    #expect(host.bridge.focus(first.id) != .unavailable)

    var visited: [Int] = [0]
    for _ in 0..<60 {
        _ = host.bridge.moveFocus(.down)
        await host.settle()
        guard let focused = host.bridge.focusedID,
            let id = list.window.materializedIDs.first(where: {
                list.window.node(for: $0)?.id == focused
            })
        else { break }
        visited.append(id)
    }

    #expect(visited == Array(0...60))
    #expect(list.window.node(for: 0) == nil)  // evicted behind the focus
    let identifiers = host.accessibilityIdentifiers()
    #expect(Set(identifiers).count == identifiers.count)
    #expect(identifiers.contains("item-60"))
}

// MARK: - 10 000-model consumer

@MainActor
@Test
func test_resultC_tenThousandModelsPrependDeleteAndLoadMoreWhileScrolling() async {
    let host = Host()
    let list = makeList(0..<10_000, maximum: 48)
    var requests = 0
    list.loader.onLoadMore = { [weak list] _ in
        requests += 1
        guard let list else { return .completed }

        let current = list.source.current
        let last = current.items.last?.id ?? 0
        list.source.send(
            CollectionSnapshot(
                dataKey: current.dataKey,
                revision: current.revision + 1,
                items: current.items + rows(last + 1...last + 20)
            )
        )
        return .completed
    }
    _ = await mount(list, in: host)
    let backing = host.backing(of: list)!
    var nextPrepend = -1
    var generator = SystemRandomNumberGenerator()

    for step in 0..<40 {
        let total = list.window.extents.totalExtent
        let target = Double(step % 5) / 4 * max(0, total - 400)
        backing.drag(to: target)
        backing.drag(to: target + 30)
        let current = list.source.current
        var items = current.items
        switch step % 3 {
        case 0:
            items = rows(nextPrepend - 9...nextPrepend) + items
            nextPrepend -= 10
        case 1:
            let victims = Set(
                (0..<20).map { _ in items[Int.random(in: 0..<items.count, using: &generator)].id }
            )
            items.removeAll { victims.contains($0.id) }
        default:
            items = items.map {
                $0.id % 7 == step % 7
                    ? CollectionItem(id: $0.id, value: Row(height: $0.value.height + 3)) : $0
            }
        }
        list.source.send(
            CollectionSnapshot(
                dataKey: current.dataKey,
                revision: current.revision + 1,
                items: items
            )
        )
        await host.settle()

        let materialized = list.window.materializedIDs
        #expect(Set(materialized).count == materialized.count)
        #expect(materialized.allSatisfy { list.window.snapshot.contains($0) })
        #expect(materialized.count <= 48)
        #expect(list.window.content.subnodes.count == materialized.count)
        #expect(list.window.snapshot.revision == list.source.current.revision)
    }
    backing.drag(to: max(0, list.window.extents.totalExtent - 400))
    await host.settle()
    #expect(requests >= 1)
    #expect(host.bridge.materializationBudget.liveNodeCount <= 48)
}

@MainActor
@Test
func test_resultC_liveUIForOneAndTenThousandModelsIsBoundedByTheSameWindow() async {
    var live: [Int] = []
    var made: [Int] = []
    for count in [1_000, 10_000] {
        let host = Host()
        let provider = RowProvider()
        let list = ListNode(
            source: source(0..<count),
            provider: provider,
            maximumMaterializedCount: 48,
            style: frameStyle()
        )
        _ = await mount(list, in: host)
        host.backing(of: list)!.drag(to: 12_000, phase: .idle)
        await host.settle()
        // Deferred creations finish in later budget passes; drain them before counting.
        for _ in 0..<5 {
            host.bridge.materializationBudget.beginPass()
            await host.settle()
        }
        live.append(list.window.materializedIDs.count)
        made.append(provider.made)
        host.bridge.detach()
    }

    #expect(live[0] == live[1])
    // Creations depend on how many intermediate passes ran, not on the model count: both stay
    // within two windows (the start and the target).
    #expect(made.allSatisfy { $0 <= 2 * 48 }, "made=\(made)")
}

// MARK: - P6.9 state after eviction

@MainActor
@Test
func test_resultC_tableSelectionSurvivesEvictionAndSwipeProgressResets() async {
    let host = Host()
    let table = makeTable(0..<3_000)
    table.trailingActions = { _ in [RowAction(id: "archive", title: "Archive") { _ in .completed }]
    }
    _ = await mount(table, in: host)
    table.selection = [3]
    table.swipe.track(3, translation: -100, leadingCount: 0, trailingCount: 1, rowWidth: 320)
    _ = table.swipe.release(3, actionCount: 1, rowWidth: 320, allowsFullSwipe: false)
    #expect(table.swipe.openRow == 3)

    #expect(await reveal(2_000, in: table, host: host) == .completed)
    #expect(table.window.node(for: 3) == nil)
    #expect(table.swipe.openRow == nil)

    #expect(await reveal(3, in: table, host: host) == .completed)
    let cell = table.cell(for: 3)
    #expect(cell?.rowElement.accessibility.isSelected == true)
    #expect(table.swipe.offset(for: 3) == 0)
}

@MainActor
@Test
func test_resultC_twoContainersShareOneHostBudget() async {
    let host = Host()
    let root = Node()
    root.style.flexDirection = .row
    let left = makeList(0..<5_000, maximum: 40)
    let right = makeGrid(0..<5_000)
    root.addSubnode(left)
    root.addSubnode(right)
    #expect(host.attach(root))
    await host.settle()

    #expect(left.window.budget === right.window.budget)
    #expect(left.window.budget === host.bridge.materializationBudget)
    let live = left.window.materializedIDs.count + right.window.materializedIDs.count
    #expect(host.bridge.materializationBudget.liveNodeCount == live)
}

// MARK: - Open/close cycles

@MainActor
@Test
func test_resultC_hundredOpenCloseCyclesReleaseBindingsLoadsBudgetAndNodes() async {
    let host = Host()
    let baseline = host.bridge.bindingCount
    weak var released: TableNode<RowProvider>?
    var loads = 0
    do {
        let table = makeTable(0..<2_000)
        table.loader.onRefresh = { _ in
            loads += 1
            return .completed
        }
        released = table
        let root = Node()
        root.addSubnode(table)
        for cycle in 0..<100 {
            #expect(host.attach(root))
            for _ in 0..<20_000 where host.bridge.hostedContainers.isEmpty {
                await Task.yield()
            }
            await host.settle()
            if cycle % 10 == 0 {
                host.backing(of: table)?.drag(to: Double(cycle) * 40, phase: .idle)
                await host.settle()
            }
            #expect(host.bridge.bindingCount == baseline + 1)
            host.bridge.detach()
            #expect(host.bridge.bindingCount == baseline)
            #expect(host.bridge.materializationBudget.liveNodeCount == 0)
            #expect(table.loader.runningCount == 0)
            #expect(host.bridge.hostedContainers.isEmpty)
        }
        // Loaded data is not requested again by remounts.
        #expect(loads == 0)
        root.dispose()
    }
    await Task.yield()
    #expect(released == nil)
}

// MARK: - Table rows without a pointer (tvOS remote, keyboard)

@MainActor
@Test
func test_resultC_tableRowsTakeFocusBeyondTheViewportAndReturnSelects() async {
    let host = Host()
    let table = makeTable(0..<500)
    var selected: [Int] = []
    table.events.onSelect = { selected.append($0) }
    _ = await mount(table, in: host)
    let first = table.cell(for: 0)!.rowElement
    #expect(first.focus.isFocusable)
    #expect(host.bridge.focus(first.id) != .unavailable)

    var focusedRows: [Int] = [0]
    for _ in 0..<30 {
        _ = host.bridge.send(.keyDown, key: KeyData(key: .downArrow))
        _ = host.bridge.send(.keyUp, key: KeyData(key: .downArrow))
        await host.settle()
        guard let focused = host.bridge.focusedID,
            let id = table.window.materializedIDs.first(where: {
                table.cell(for: $0)?.rowElement.id == focused
            })
        else { break }
        focusedRows.append(id)
    }
    #expect(focusedRows == Array(0...30), "\(focusedRows) selected=\(selected)")
    #expect(host.backing(of: table)!.contentOffset.y > 0)

    _ = host.bridge.send(.keyDown, key: KeyData(key: .returnKey))
    _ = host.bridge.send(.keyUp, key: KeyData(key: .returnKey))
    await host.settle()
    #expect(selected == [30])
    #expect(table.selection == [30])
    #expect(table.cell(for: 30)?.rowElement.accessibility.isSelected == true)
}
