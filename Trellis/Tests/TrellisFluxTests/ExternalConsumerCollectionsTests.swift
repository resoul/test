import QuartzCore
import Testing
import TrellisCore
import TrellisFlux
import TrellisRender

// R12 (`implementation-plan-6.md`, P6.10/P6.11): an external consumer of ListNode, GridNode and
// TableNode through public API only — no `@testable`. A Flux model publishes snapshots, the
// page wires hooks and events, the mounted host owns delivery. Checks: the same dataset and
// results for all three containers, one binding per mount, one request per data generation,
// no repeated request on remount, a late answer for a replaced source is ignored, closure-only,
// delegate-only and mixed event dispatch, and release of the weak delegate and the model.

private struct FileItem: Sendable, Equatable {
    let name: String
}

@MainActor
private final class FileRowProvider: ItemProvider {
    private(set) var made = 0

    func makeNode(for item: FileItem, id: Int) -> Node {
        MainActor.assertIsolated()
        made += 1
        let node = Node()
        node.style.height = 10
        node.accessibility.isElement = true
        node.accessibility.label = item.name
        node.accessibility.identifier = "file-\(id)"
        return node
    }

    func update(_ node: Node, with item: FileItem, id: Int) {
        MainActor.assertIsolated()
        node.accessibility.label = item.name
    }
}

/// The model: a Flux `CurrentValue` is the published state; the MainActor mirror is what the
/// model itself builds the next page from. Requests go to a slow fake API.
@MainActor
private final class FilesModel {
    private let state: CurrentValue<CollectionSnapshot<Int, FileItem>>
    private(set) var published: CollectionSnapshot<Int, FileItem>
    private(set) var requests: [CollectionLoadContext] = []
    var total = 80
    var delay: Duration = .milliseconds(5)

    init(dataKey: String = "files") {
        let initial = CollectionSnapshot<Int, FileItem>.initial(dataKey: dataKey)
        published = initial
        state = CurrentValue(initial)
    }

    var files: Flux<CollectionSnapshot<Int, FileItem>> { state.flux }

    func load(
        _ context: CollectionLoadContext,
        isCurrent: @MainActor (CollectionLoadContext) -> Bool
    ) async -> CollectionLoadResult {
        requests.append(context)
        try? await Task.sleep(for: delay)
        guard isCurrent(context), context.dataKey == published.dataKey else { return .completed }

        let start = published.count
        let end = min(total, start + (context.pageSize ?? 20))
        let page = (start..<end).map {
            CollectionItem(id: $0, value: FileItem(name: "\(context.dataKey) \($0)"))
        }
        await publish(
            CollectionSnapshot(
                dataKey: published.dataKey,
                revision: published.revision + 1,
                items: published.items + page,
                loadState: CollectionLoadState(phase: .loaded, endReached: end >= total)
            )
        )
        return .completed
    }

    func show(_ dataKey: String) async {
        await publish(.initial(dataKey: dataKey))
    }

    private func publish(_ snapshot: CollectionSnapshot<Int, FileItem>) async {
        published = snapshot
        await state.set(snapshot)
    }
}

@MainActor
private final class Coordinator: CollectionDelegate {
    var selected: [Int] = []
    var visibleChanges = 0

    func collectionDidSelect(_ id: Int) { selected.append(id) }
    func collectionVisibleItemsDidChange(_ ids: [Int]) { visibleChanges += 1 }
}

@MainActor
private final class Backing: NativeScrollBacking {
    let containerLayer = CALayer()
    var contentOffset = LayoutPoint(x: 0, y: 0)

    var viewportSize: MeasuredSize {
        MeasuredSize(
            width: Double(containerLayer.bounds.width),
            height: Double(containerLayer.bounds.height)
        )
    }

    var contentOriginInHost: LayoutPoint {
        LayoutPoint(x: Double(containerLayer.position.x), y: Double(containerLayer.position.y))
    }

    func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
        containerLayer.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        containerLayer.position = CGPoint(x: frame.origin.x, y: frame.origin.y)
    }

    func setContentSize(_ size: MeasuredSize) {}
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
}

private enum Kind: CaseIterable {
    case list, grid, table
}

/// One mounted page: the container, its provider and the Flux binding the consumer created.
@MainActor
private final class Page {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let container: Node
    let source: StateSubject<CollectionSnapshot<Int, FileItem>>
    let loader: CollectionLoader<Int, FileItem>
    let events: CollectionEventDispatcher<Int>
    let provider = FileRowProvider()
    let count: @MainActor () -> Int
    let scrollTo: @MainActor (Int, @escaping @MainActor (CollectionScrollResult) -> Void) -> Void
    private var feed: FluxStateBinding<CollectionSnapshot<Int, FileItem>>?

    init(_ kind: Kind, model: FilesModel) {
        var style = LayoutStyle()
        style.width = 320
        style.height = 400
        bridge = NodeHostBridge(hostLayer: hostLayer)
        let source = StateSubject(model.published)
        self.source = source
        switch kind {
        case .list:
            let list = ListNode(source: source, provider: provider, style: style)
            (container, loader, events) = (list, list.loader, list.events)
            count = { list.window.snapshot.count }
            scrollTo = { list.scrollTo($0, completion: $1) }
        case .grid:
            let grid = GridNode(
                source: source,
                provider: provider,
                layout: GridLayout(columns: .fixed(1)),
                estimatedRowHeight: 10,
                style: style
            )
            (container, loader, events) = (grid, grid.loader, grid.events)
            count = { grid.window.snapshot.count }
            scrollTo = { grid.scrollTo($0, completion: $1) }
        case .table:
            let table = TableNode(source: source, provider: provider, style: style)
            (container, loader, events) = (table, table.loader, table.events)
            count = { table.window.snapshot.count }
            scrollTo = { table.scrollTo($0, completion: $1) }
        }
        let loader = loader
        loader.onLoad = { [weak model] context in
            await model?.load(context, isCurrent: { loader.isCurrent($0) }) ?? .completed
        }
        loader.onLoadMore = loader.onLoad
        root.addSubnode(container)
        _ = model
    }

    /// Mounts the page and connects the model's Flux stream to the container's source — the
    /// single integration point (ADR 0030): one Flux binding, one container binding.
    func mount(model: FilesModel) {
        let attached = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 400),
            scale: 1,
            scrollBackingFactory: { _, _ in Backing() }
        )
        #expect(attached)
        let source = source
        feed = bridge.bindFlux(model.files, initial: model.published) { snapshot, _ in
            source.send(snapshot)
        }
    }

    func unmount() {
        feed?.cancel()
        feed = nil
        bridge.detach()
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }

        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

@MainActor
@Test(arguments: Kind.allCases)
fileprivate func test_consumer_fluxModelFillsTheViewportAndPaginatesWithoutUserScroll(kind: Kind)
    async
{
    let model = FilesModel()
    let page = Page(kind, model: model)
    #expect(model.requests.isEmpty)  // registering hooks before mount does not load

    page.mount(model: model)
    // Rows are 10 pt, the viewport 400 pt: the container keeps asking for pages until two
    // viewport lengths remain or the data ends — Flux delivers each page after the hook
    // returned, so progress must be recognised when it arrives.
    let filled = await waitUntil { page.count() == 80 }
    #expect(
        filled,
        "\(kind) count=\(page.count()) requests=\(model.requests.map(\.reason)) bindings=\(page.bridge.bindingCount) src=\(page.source.current.count) pub=\(model.published.count)"
    )
    #expect(model.requests.map(\.reason) == [.initial, .loadMore, .loadMore, .loadMore])
    #expect(Set(model.requests.map(\.baseRevision)).count == model.requests.count)
    #expect(page.bridge.bindingCount == 2)  // the Flux feed and the container
    page.unmount()
}

@MainActor
@Test(arguments: Kind.allCases)
fileprivate func test_consumer_remountAndSourceReplacementKeepOneRequestPerGeneration(kind: Kind)
    async
{
    let model = FilesModel()
    model.total = 20
    let page = Page(kind, model: model)
    page.mount(model: model)
    #expect(await waitUntil { page.count() == 20 })
    #expect(model.requests.count == 1)

    // Remount: loaded data is not requested again.
    page.unmount()
    #expect(page.loader.runningCount == 0)
    page.mount(model: model)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(model.requests.count == 1)
    #expect(page.count() == 20)

    // Replace the source generation twice; the first new generation's answer arrives late and
    // must not land in the second.
    model.delay = .milliseconds(40)
    await model.show("files-a")
    #expect(await waitUntil { model.requests.count == 2 })
    model.delay = .milliseconds(1)
    await model.show("files-b")
    #expect(await waitUntil { page.count() == 20 && model.requests.count == 3 })
    try? await Task.sleep(for: .milliseconds(60))
    #expect(model.requests.map(\.dataKey) == ["files", "files-a", "files-b"])
    #expect(page.source.current.dataKey == "files-b")
    #expect(page.source.current.items.allSatisfy { $0.value.name.hasPrefix("files-b ") })
    #expect(page.bridge.bindingCount == 2)

    // Reveal through the public API: known → completed, unknown → notFound.
    var known: CollectionScrollResult?
    var unknown: CollectionScrollResult?
    page.scrollTo(19) { known = $0 }
    page.scrollTo(500) { unknown = $0 }
    #expect(unknown == .notFound)
    #expect(known == .cancelled || known == .completed)
    page.unmount()
}

@MainActor
@Test
func test_consumer_eventsClosureOnlyDelegateOnlyAndMixedCallExactlyOne() {
    let events = CollectionEventDispatcher<Int>()
    var closure: [Int] = []

    // Closure only.
    events.onSelect = { closure.append($0) }
    events.select(1)
    #expect(closure == [1])

    // Delegate only.
    events.onSelect = nil
    var coordinator: Coordinator? = Coordinator()
    events.delegate = coordinator
    events.select(2)
    #expect(coordinator?.selected == [2])

    // Mixed: the closure wins, the delegate is not called for the same event; removing the
    // closure restores the delegate.
    events.onSelect = { closure.append($0) }
    events.select(3)
    #expect(closure == [1, 3])
    #expect(coordinator?.selected == [2])
    events.onSelect = nil
    events.select(4)
    #expect(coordinator?.selected == [2, 4])

    // The dispatcher does not own the delegate.
    weak let released = coordinator
    coordinator = nil
    #expect(released == nil)
    #expect(events.delegate == nil)
    events.select(5)
    #expect(closure == [1, 3])
}

@MainActor
@Test(arguments: Kind.allCases)
fileprivate func test_consumer_unmountedPageAndModelAreReleased(kind: Kind) async {
    weak var releasedModel: FilesModel?
    weak var releasedContainer: Node?
    do {
        let model = FilesModel()
        model.total = 20
        let page = Page(kind, model: model)
        page.mount(model: model)
        #expect(await waitUntil { page.count() == 20 })
        #expect(page.provider.made > 0 && page.provider.made <= 20)
        page.unmount()
        page.root.dispose()
        releasedModel = model
        releasedContainer = page.container
    }
    #expect(await waitUntil { releasedModel == nil && releasedContainer == nil })
}
