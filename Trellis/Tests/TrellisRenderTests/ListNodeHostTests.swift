import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// R12a (`implementation-plan-6.md`, ADR 0032): `ListNode` mounted in a real `NodeHostBridge`
// with a test-double native scroll backing. Consumer "20 + 20" with a slow controllable API,
// prefetch by viewport distance, remount and data key changes without repeated or stale
// requests, anchor preservation while the user drags, bounded live nodes and release on detach.

@MainActor
private final class ListBacking: NativeScrollBacking {
    let nodeID: NodeID
    weak var delegate: (any NativeScrollBackingDelegate)?
    let containerLayer = CALayer()
    var contentOffset = LayoutPoint(x: 0, y: 0)
    private(set) var contentSize = MeasuredSize(width: 0, height: 0)
    private(set) var programmaticScrolls = 0

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
        programmaticScrolls += 1
        contentOffset = offset
        completion(true)
    }

    /// A native drag/deceleration tick.
    func drag(to y: Double, phase: ScrollPhase = .dragging) {
        contentOffset = LayoutPoint(x: 0, y: y)
        delegate?.scrollBacking(for: nodeID, didChangeOffset: contentOffset, phase: phase)
    }
}

@MainActor
private final class ListHost {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    var backings: [NodeID: ListBacking] = [:]

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
    }

    func attach(_ root: Node) -> Bool {
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 400),
            scale: 1,
            scrollBackingFactory: { [weak self] id, delegate in
                let backing = ListBacking(nodeID: id, delegate: delegate)
                self?.backings[id] = backing
                return backing
            }
        )
    }

    func backing(of list: CollectionNode<FeedProvider, Post>) -> ListBacking? {
        backings[list.scrollNode.id]
    }
}

private struct Post: Sendable, Equatable {
    let height: Double
}

@MainActor
private final class FeedProvider: ItemProvider {
    private(set) var made = 0

    func makeNode(for item: Post, id: Int) -> Node {
        made += 1
        let node = Node()
        node.style.height = .points(item.height)
        return node
    }

    func update(_ node: Node, with item: Post, id: Int) {
        node.style.height = .points(item.height)
    }
}

/// A slow API: each request waits until the test resolves it; the model publishes pages of 20
/// with variable heights and checks request currency after the await.
@MainActor
private final class FeedModel {
    let source = StateSubject(CollectionSnapshot<Int, Post>.initial(dataKey: "feed"))
    weak var loader: CollectionLoader<Int, Post>?
    private(set) var requests: [CollectionLoadContext] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var inFlight: Int { waiting.count }

    static func height(_ id: Int) -> Double { Double(30 + (id * 37) % 50) }

    func load(_ context: CollectionLoadContext) async -> CollectionLoadResult {
        requests.append(context)
        await withCheckedContinuation { waiting.append($0) }
        guard let loader, loader.isCurrent(context) else { return .completed }

        let current = source.current
        let start = current.count
        let page = (start..<start + (context.pageSize ?? 20)).map {
            CollectionItem(id: $0, value: Post(height: Self.height($0)))
        }
        source.send(
            CollectionSnapshot(
                dataKey: context.dataKey,
                revision: current.revision + 1,
                items: current.items + page
            )
        )
        return .completed
    }

    func resolve() {
        guard !waiting.isEmpty else { return }

        waiting.removeFirst().resume()
    }

    func prepend(_ ids: [Int]) {
        let current = source.current
        let items = ids.map { CollectionItem(id: $0, value: Post(height: Self.height($0))) }
        source.send(
            CollectionSnapshot(
                dataKey: current.dataKey,
                revision: current.revision + 1,
                items: items + current.items
            )
        )
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<20_000 where !condition() {
        await Task.yield()
    }
}

@MainActor
private func makeFeed(
    maximum: Int = 64,
    pageSize: Int = 20
) -> (root: Node, list: ListNode<FeedProvider>, model: FeedModel) {
    let model = FeedModel()
    var style = LayoutStyle()
    style.width = 320
    style.height = 400
    let list = ListNode(
        source: model.source,
        provider: FeedProvider(),
        pagination: PaginationPolicy(pageSize: pageSize),
        maximumMaterializedCount: maximum,
        style: style
    )
    list.loader.onLoad = { [weak model] in await model?.load($0) ?? .completed }
    list.loader.onLoadMore = { [weak model] in await model?.load($0) ?? .completed }
    model.loader = list.loader
    let root = Node()
    root.addSubnode(list)
    return (root, list, model)
}

/// Waits for data and the commits that measure it to settle.
@MainActor
private func settle(_ host: ListHost) async {
    // Follow-up commits (measure → reposition) arrive within a few hundred yields; stop as
    // soon as one does not come instead of spinning the full budget five times.
    for _ in 0..<5 {
        let committed = host.bridge.committedCount
        for _ in 0..<500 where host.bridge.committedCount == committed {
            await Task.yield()
        }
        if host.bridge.committedCount == committed { return }
    }
}

@MainActor
@Test
func test_listNode_consumerTwentyPlusTwentyWithSlowAPI() async {
    let host = ListHost()
    let (root, list, model) = makeFeed()
    #expect(host.attach(root))

    await waitUntil { model.requests.count == 1 }
    #expect(model.requests.map(\.reason) == [.initial])
    model.resolve()
    await waitUntil { list.window.snapshot.count == 20 }
    await settle(host)

    let backing = host.backing(of: list)
    #expect(backing != nil)
    #expect(list.window.materializedIDs.count <= 20)
    // Two viewport lengths before the end: one next-page request, deduplicated across ticks.
    let end = list.window.extents.totalExtent
    backing?.drag(to: end - 400 - 700)
    backing?.drag(to: end - 400 - 600)
    backing?.drag(to: end - 400 - 500)
    await waitUntil { model.requests.count == 2 }
    #expect(model.requests.map(\.reason) == [.initial, .loadMore])
    #expect(model.requests.last?.pageSize == 20)
    #expect(model.inFlight == 1)

    // The slow API has not answered: more ticks do not duplicate the request.
    backing?.drag(to: end - 400 - 450)
    await settle(host)
    #expect(model.requests.count == 2)

    model.resolve()
    await waitUntil { list.window.snapshot.count == 40 }
    await settle(host)
    #expect(model.requests.count == 2)
    #expect(list.window.snapshot.items.map(\.id) == Array(0..<40))
}

@MainActor
@Test
func test_listNode_remountDoesNotRequestAgainAndDataKeyChangeIgnoresLateAnswer() async {
    let host = ListHost()
    // 60 rows are more than two viewports: no next-page demand muddles the request counts.
    let (root, list, model) = makeFeed(pageSize: 60)
    #expect(host.attach(root))
    await waitUntil { model.requests.count == 1 }
    model.resolve()
    await waitUntil { list.window.snapshot.count == 60 }
    await settle(host)
    #expect(model.requests.count == 1)

    host.bridge.detach()
    #expect(list.loader.runningCount == 0)
    #expect(host.attach(root))
    await settle(host)
    #expect(model.requests.count == 1)

    // A new filter: the old key's pending page (none here) and new initial.
    model.source.send(CollectionSnapshot.initial(dataKey: "filter"))
    await waitUntil { model.requests.count == 2 }
    #expect(model.requests.last?.dataKey == "filter")
    model.source.send(CollectionSnapshot.initial(dataKey: "feed-2"))
    await waitUntil { model.requests.count == 3 }

    model.resolve()  // late answer for "filter"
    await settle(host)
    #expect(list.window.snapshot.dataKey == "feed-2")
    #expect(list.window.snapshot.count == 0)

    model.resolve()
    await waitUntil { list.window.snapshot.count == 60 }
    #expect(list.window.snapshot.dataKey == "feed-2")
    #expect(model.requests.map(\.reason) == [.initial, .initial, .initial])
}

@MainActor
@Test
func test_listNode_prependWhileDraggingKeepsTheReadRowInTheSameGeometryCommit() async {
    let host = ListHost()
    let (root, list, model) = makeFeed()
    #expect(host.attach(root))
    await waitUntil { model.requests.count == 1 }
    model.resolve()
    await waitUntil { list.window.snapshot.count == 20 }
    await settle(host)
    let backing = host.backing(of: list)!

    backing.drag(to: 300)
    await settle(host)
    let anchorIndex = list.window.extents.index(at: backing.contentOffset.y)!
    let anchorID = list.window.snapshot.items[anchorIndex].id
    let before = list.window.extents.offset(of: anchorIndex) - backing.contentOffset.y

    model.prepend([-5, -4, -3, -2, -1])
    await waitUntil { list.window.snapshot.count == 25 }
    await settle(host)

    // Still dragging: the native offset moved by the inserted extent, the row did not.
    let index = list.window.snapshot.index(of: anchorID)!
    let after = list.window.extents.offset(of: index) - backing.contentOffset.y
    #expect(abs(after - before) <= 0.5)
    #expect(backing.contentOffset.y > 300)
    #expect(backing.contentOffset.y == list.window.offset)
    #expect(backing.programmaticScrolls == 0)
    #expect(host.bridge.pendingOffsetAdjustments.isEmpty)

    // The next drag tick continues from the adjusted offset.
    let adjusted = backing.contentOffset.y
    backing.drag(to: adjusted + 10)
    #expect(list.window.offset == adjusted + 10)
}

@MainActor
@Test
func test_listNode_tenThousandModelsKeepLiveNodesBounded() async {
    let host = ListHost()
    let (root, list, model) = makeFeed(maximum: 48)
    model.source.send(
        CollectionSnapshot(
            dataKey: "feed",
            revision: 1,
            items: (0..<10_000).map {
                CollectionItem(id: $0, value: Post(height: FeedModel.height($0)))
            }
        )
    )
    #expect(host.attach(root))
    await settle(host)
    let backing = host.backing(of: list)!

    backing.drag(to: 200_000)
    await settle(host)
    for _ in 0..<5 { host.bridge.materializationBudget.beginPass() }
    await settle(host)

    #expect(list.window.snapshot.count == 10_000)
    #expect(list.window.content.subnodes.count <= 48)
    #expect(list.window.materializedIDs.allSatisfy { list.window.snapshot.index(of: $0)! > 2_000 })
    // The data arrived loaded: no initial request, and the viewport is far from the end.
    #expect(model.requests.isEmpty)
}

@MainActor
@Test
func test_listNode_detachReleasesBindingLoadsAndBudget() async {
    let host = ListHost()
    let (root, list, model) = makeFeed()
    let baseline = host.bridge.bindingCount
    #expect(host.attach(root))
    await waitUntil { model.requests.count == 1 }
    #expect(host.bridge.bindingCount == baseline + 1)
    #expect(list.loader.runningCount == 1)

    host.bridge.detach()

    #expect(host.bridge.bindingCount == baseline)
    #expect(list.loader.runningCount == 0)
    #expect(host.bridge.materializationBudget.liveNodeCount == 0)
    model.resolve()
    await Task.yield()
    #expect(list.window.snapshot.count == 0)
}

@MainActor
@Test
func test_listNode_removedFromTreeIsDetachedAtNextCommit() async {
    let host = ListHost()
    let (root, list, model) = makeFeed()
    #expect(host.attach(root))
    await waitUntil { model.requests.count == 1 }

    list.removeFromSupernode()
    await settle(host)

    #expect(list.loader.runningCount == 0)
    #expect(host.bridge.hostedContainers.isEmpty)
}

// MARK: - R12b GridNode on the same runtime

@MainActor
private func makeGridFeed(
    width: Double = 320
) -> (root: Node, grid: GridNode<FeedProvider>, model: FeedModel) {
    let model = FeedModel()
    var style = LayoutStyle()
    style.width = .fraction(1)
    style.height = 400
    let grid = GridNode(
        source: model.source,
        provider: FeedProvider(),
        layout: GridLayout(columns: .adaptive(minimumWidth: 90), columnSpacing: 8),
        rowSpacing: 8,
        estimatedRowHeight: 60,
        pagination: PaginationPolicy(pageSize: 30),
        style: style
    )
    grid.loader.onLoad = { [weak model] in await model?.load($0) ?? .completed }
    grid.loader.onLoadMore = { [weak model] in await model?.load($0) ?? .completed }
    model.loader = grid.loader
    let root = Node()
    root.style.flexDirection = .column
    root.addSubnode(grid)
    return (root, grid, model)
}

@MainActor
@Test
func test_gridNode_loadsThroughTheSharedHooksAndPaginatesOnce() async {
    let host = ListHost()
    let (root, grid, model) = makeGridFeed()
    #expect(host.attach(root))
    await waitUntil { model.requests.count == 1 }
    model.resolve()
    await waitUntil { grid.window.snapshot.count == 30 }
    await settle(host)

    #expect(grid.window.columnCount == 3)
    let backing = host.backing(of: grid)!
    let end = grid.window.extents.totalExtent
    backing.drag(to: max(0, end - 400 - 300))
    backing.drag(to: max(0, end - 400 - 200))
    await waitUntil { model.requests.count == 2 }
    await settle(host)
    #expect(model.requests.map(\.reason) == [.initial, .loadMore])
    model.resolve()
    await waitUntil { grid.window.snapshot.count == 60 }
    #expect(grid.window.materializedIDs.count <= 96)
}

@MainActor
@Test
func test_gridNode_hostWidthChangeReflowsColumnsAndKeepsTheAnchorNatively() async {
    let host = ListHost()
    let (root, grid, model) = makeGridFeed()
    model.source.send(
        CollectionSnapshot(
            dataKey: "feed",
            revision: 1,
            items: (0..<300).map {
                CollectionItem(id: $0, value: Post(height: FeedModel.height($0)))
            }
        )
    )
    #expect(host.attach(root))
    await settle(host)
    let backing = host.backing(of: grid)!
    backing.drag(to: 1_500, phase: .idle)
    await settle(host)
    #expect(grid.window.columnCount == 3)
    let anchorIndex = grid.window.itemIndex(at: backing.contentOffset.y)!
    let anchorID = grid.window.snapshot.items[anchorIndex].id
    let before = grid.window.itemOffset(at: anchorIndex) - backing.contentOffset.y

    host.bridge.updateBounds(LayoutFrame(width: 200, height: 400), scale: 1)
    await settle(host)

    #expect(grid.window.columnCount == 2)
    let index = grid.window.snapshot.index(of: anchorID)!
    #expect(abs(grid.window.itemOffset(at: index) - backing.contentOffset.y - before) <= 0.5)
    #expect(backing.contentOffset.y == grid.window.offset)
}
