import LayoutCore
import StateCore
import Tracing

/// A column (or row) of nodes for `items` that lays out only the items near the part of it
/// that shows — on screen and about a screen before and after — however many items there
/// are. It goes inside a `Scroll`, alone or with other nodes around it:
///
///     private let rows = NodeCache<Post.ID, PostRow> { _ in PostRow() }
///     private lazy var posts = LazyStack(estimatedLength: 72) { [rows] post in
///         rows[post.id].showing(post)
///     }
///     private lazy var feed = Scroll(.vertical, content: posts)
///
///     override func update() {
///         posts.items = model.posts.value
///     }
///
/// `content` is asked for the node of an item when the item comes near the window, in the
/// layout pass; with a `NodeCache` the item keeps its node while it stays near, and the node
/// is released once the item is far away. Scrolling lays the tree out again only when the
/// window comes close to the end of what is laid out, not on every move.
///
/// Items not laid out take the length they had when they were last laid out at the stack's
/// present width, or `estimatedLength` before that: the stack keeps the space of the whole
/// list, and the scroll's range grows or shrinks as items get their real lengths. When items
/// before the window change length, or are added or removed, the scroll moves by as much, so
/// what shows stays where it is — except where the window shows the stack's start, which
/// then shows the new items.
///
/// Across its axis the stack is as wide (or tall) as its parent makes it, and each item is
/// stretched to it.
///
/// Ownership: the stack keeps `content` and the items; the nodes `content` returns are owned
/// by whoever made them, and by the stack while they are mounted. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public final class LazyStack<Item: Identifiable>: Node {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let axis: ScrollAxis

    /// The items, in order from the start.
    ///
    /// Ownership: the stack keeps them. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public var items: [Item] {
        didSet {
            itemsVersion &+= 1
            gate.itemsChanged(count: items.count)
            preparation?.itemsChanged(items)
            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// Called when a layout of the stack is mounted that placed the nodes of `items` as they
    /// are now, before it is drawn: what it changes is drawn with that layout. A layout
    /// made before `items` last changed does not call it.
    ///
    /// Ownership: the stack keeps the closure; it must not keep the stack. Isolation:
    /// MainActor. Errors: none. Cancellation: set to `nil`.
    public var onLayoutApplied: (@MainActor () -> Void)?

    /// Counts the changes of `items`, and the one the last `layoutSpec()` placed.
    private var itemsVersion = 0
    private var placedVersion = -1

    // MARK: - Prefetching

    /// How far from the window, in window lengths along the axis, an item counts as near
    /// enough to prepare its data — before its node exists: the start of a download, the
    /// decoding of a thumbnail. Two by default.
    ///
    /// An item that was told to ``prefetch`` is told to ``cancelPrefetch`` only once it is a
    /// window length farther than that, so that a scroll that wavers at the edge does not
    /// start and stop the same work again and again.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var prefetchDistance: Double = 2 {
        didSet { if prefetchDistance != oldValue { setNeedsLayout() } }
    }

    /// Called with the items that came within ``prefetchDistance`` of the window, once each
    /// until they leave it: a chance to start work whose result their nodes will use. The
    /// items already shown are included when the stack first learns where the window is.
    /// Items are passed in list order, on the main actor.
    ///
    /// Ownership: the stack keeps it; it must not keep the stack. Isolation: MainActor.
    /// Errors: none. Cancellation: see ``cancelPrefetch``.
    public var prefetch: (@MainActor ([Item]) -> Void)?

    /// Called with items that were prefetched and are now far from the window, or are gone
    /// from `items`, or whose stack left the screen: work started for them that nobody has
    /// asked for yet can stop. Work whose result is already in use is not this call's to
    /// stop; it does not know which that is.
    ///
    /// Ownership: the stack keeps it; it must not keep the stack. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public var cancelPrefetch: (@MainActor ([Item]) -> Void)?

    /// The items ``prefetch`` has been called with and ``cancelPrefetch`` has not, in list
    /// order of the moment they were told.
    private var prefetched: [Item.ID: Item] = [:]
    private var prefetchedWindow: (start: Double, end: Double, version: Int)?

    /// Tells ``prefetch`` and ``cancelPrefetch`` which items entered and left the zone around
    /// `span`, the part of the stack that shows.
    private func evaluatePrefetch(window span: (start: Double, end: Double)) {
        guard prefetch != nil || cancelPrefetch != nil else { return }

        let length = span.end - span.start
        guard length > 0 else { return }

        // A window that moved a fraction of its length lands in the same zone.
        if let last = prefetchedWindow, last.version == itemsVersion,
            abs(span.start - last.start) < length / 8, abs(span.end - last.end) < length / 8
        {
            return
        }
        prefetchedWindow = (span.start, span.end, itemsVersion)
        updateStarts()
        let total = self.length
        let reach = max(0, prefetchDistance) * length
        let near = lines(from: max(0, span.start - reach), to: min(total, span.end + reach))
        let keep = lines(
            from: max(0, span.start - reach - length),
            to: min(total, span.end + reach + length)
        )
        func items(in lines: Range<Int>) -> ArraySlice<Item> {
            guard !lines.isEmpty else { return [] }

            return self.items[
                lines.lowerBound * perLine..<min(self.items.count, lines.upperBound * perLine)
            ]
        }

        let staying = Set(items(in: keep).map(\.id))
        let left = prefetched.filter { !staying.contains($0.key) }.map(\.value)
        for item in left { prefetched[item.id] = nil }
        let entered = items(in: near).filter { prefetched[$0.id] == nil }
        for item in entered { prefetched[item.id] = item }
        if !left.isEmpty { cancelPrefetch?(left) }
        if !entered.isEmpty { prefetch?(Array(entered)) }
    }

    /// Cancels everything prefetched: the stack left the screen.
    private func cancelAllPrefetches() {
        prefetchedWindow = nil
        guard !prefetched.isEmpty else { return }

        let all = Array(prefetched.values)
        prefetched = [:]
        cancelPrefetch?(all)
    }

    // MARK: - Paging

    /// How the stack pages. Without it, or without ``loadMore``, the stack does not ask for
    /// more. Changing it starts paging over, as ``restartPagination()`` does, except that the
    /// end is not forgotten.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var pagination: PaginationPolicy? {
        didSet {
            guard pagination != oldValue else { return }

            cancelPageLoad()
            gate = PaginationGate(policy: pagination ?? PaginationPolicy())
            setNeedsLayout()
        }
    }

    /// Loads the next page, when the stack asks for one (``pagination``): the end of the list
    /// is within the policy's trigger distance of the window. It is called on the main actor
    /// and is expected to add the page to `items` before it returns; the stack asks again only
    /// after it has returned and only when the end is near once more. A page may also say
    /// that it was the last: set ``reachedEnd``.
    ///
    /// Throwing marks the page failed (``pageLoadState``, ``pageLoadError``): the stack does not
    /// ask again by itself, and ``retryLoadingPage()`` does. Cancelling the load — it is
    /// cancelled when the stack leaves the screen, and when paging is restarted — is not a
    /// failure: whatever it throws is dropped, and the stack asks again when it shows again.
    ///
    /// Ownership: the stack keeps it; it must not keep the stack. Isolation: MainActor.
    /// Errors: see above. Cancellation: see above.
    public var loadMore: (@MainActor (PageRequest) async throws -> Void)?

    /// Whether there are no more pages: the stack asks no more while it is `true`. Set it from
    /// ``loadMore`` when a page comes back short or says it is the last.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var reachedEnd: Bool {
        get { endState.value }
        set {
            guard newValue != untracked({ endState.value }) else { return }

            endState.value = newValue
            if !newValue { setNeedsLayout() }
        }
    }

    /// What the paging is doing, for a footer: reading it under tracking depends on it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var pageLoadState: PageLoadState {
        endState.value ? .endReached : loadState.value
    }

    /// Why the last page failed; `nil` unless ``pageLoadState`` is ``PageLoadState/failed``.
    ///
    /// Ownership: the stack keeps the error. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public private(set) var pageLoadError: (any Error)?

    /// Asks for the page that failed again, without waiting for the end of the list to come
    /// near: the person asked. Does nothing while a page is being loaded, when there are no more
    /// pages, or without ``pagination`` and ``loadMore``.
    public func retryLoadingPage() {
        guard pagination != nil, loadMore != nil, !reachedEnd, !gate.isRequestInFlight else {
            return
        }

        gate.retry(count: items.count, version: itemsVersion)
        startPageLoad(isRetry: true)
    }

    /// Starts paging over, for a list whose contents are another list now — a new search, a
    /// new filter: a page on its way is cancelled and forgotten, a failure and the end are
    /// forgotten, and the stack asks for the first page as soon as it is laid out. Set `items`
    /// to the new first items (or to none) as well; this does not touch them.
    public func restartPagination() {
        cancelPageLoad()
        gate = PaginationGate(policy: pagination ?? PaginationPolicy())
        endState.value = false
        loadState.value = .idle
        pageLoadError = nil
        setNeedsLayout()
    }

    private let endState = State(false)
    private let loadState = State(PageLoadState.idle)
    private var gate = PaginationGate()
    private var pageLoad: Task<Void, Never>?
    /// Which load the gate's in-flight page belongs to: a load that finishes after another
    /// began — or after the stack let it go — must not touch the gate.
    private var loadGeneration = 0
    private var lastShownStart: Double?

    /// Sets `items` leaving the scroll where it is: the items move under the window as the
    /// new ones have them, where setting `items` keeps what shows in place — so that a row
    /// dragged to a new place in the list takes its place without the list following it.
    ///
    /// Ownership: the stack keeps the items. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setItemsHoldingScroll(_ items: [Item]) {
        holdsScroll = true
        self.items = items
    }

    /// The next layout does not keep what shows in place.
    private var holdsScroll = false

    /// The length along `axis` taken by an item that was never laid out.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var estimatedLength: Double {
        didSet {
            guard estimatedLength != oldValue else { return }

            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// How many items stand side by side across `axis` — the columns of a vertical stack,
    /// the rows of a horizontal one. With more than one the stack is a grid: items take equal
    /// shares of the width (or height) in order, and a line is as long as its longest item.
    /// Values below 1 count as 1.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var lanes: Int {
        didSet {
            guard lanes != oldValue else { return }

            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// The space between neighboring items, along `axis` and across it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var spacing: Double {
        didSet {
            guard spacing != oldValue else { return }

            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// The indices of `items` whose nodes the last layout placed.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var laidOutItems: Range<Int> = 0..<0

    private let content: @MainActor (Item) -> Node
    private var preparation: (any ItemPreparing<Item>)?

    /// Counts in this stack's optional preparation budget, or zero for a synchronous stack.
    public var preparationProgress: ItemPreparationProgress {
        preparation?.progress ?? ItemPreparationProgress(running: 0, queued: 0, retained: 0)
    }

    /// Retries a retained failed item. Returns false if the item has no retained failure.
    /// The retry follows the same worker and queue limits as initial preparation.
    @discardableResult
    public func retryPreparation(for id: Item.ID) -> Bool { preparation?.retry(id) ?? false }

    /// Waits until the preparation workers and admitted queue drain, including jobs admitted
    /// while waiting. It does not run pending layouts or cancel work if the waiter is cancelled.
    /// A worker that ignores cancellation can delay this wait until it returns.
    public func preparationsFinished() async { await preparation?.finished() }

    /// Lengths along the axis of items laid out at `measuredAcross`.
    private var measured: [Item.ID: Double] = [:]
    private var measuredAcross: Double?
    /// Where each line of `lanes` items starts from the stack's start, with one more entry
    /// past the last: `starts[i + 1] - spacing` is where line `i` ends.
    private var starts: [Double] = [0]
    private var startsAreStale = true
    /// The items and nodes the last `layoutSpec()` placed, in order.
    private var placed: [(id: Item.ID, node: Node)] = []
    /// The last applied items, which remain authoritative while a newer pass is pending
    /// or rejected. Remembering the anchor from `placed` would lose it after such a pass.
    private var mountedItems: [(id: Item.ID, node: Node, index: Int)] = []
    /// The part of the stack, from its start, that the nodes placed cover once laid out;
    /// the ends are unbounded where the first or the last item is among them.
    private var covered: (start: Double, end: Double) = (.infinity, -.infinity)
    /// The part the mounted nodes cover — behind `covered` while a layout is solved in the
    /// background.
    private var mountedCover: (start: Double, end: Double) = (.infinity, -.infinity)
    /// An item that shows as a layout begins, and where it is then in `scroll`: the layout
    /// is followed by a scroll that puts it back there.
    private var anchor: Anchor?
    /// The item `scroll(to:at:)` moved to at once, where in the window, and the layouts
    /// left to put it there: the first layout there finds lengths it only guessed.
    private var scrolledTo: (id: Item.ID, alignment: ScrollAlignment, layouts: Int)?

    private struct Anchor {
        let id: Item.ID
        /// Where it is in the scroll, along the axis.
        let position: Double
        let scroll: Scroll
        /// Where it starts from the stack's start, and its index in `items`, as laid out.
        let start: Double
        let index: Int
    }

    /// A stack of the nodes `content` returns for `items`, along `axis`.
    ///
    /// Ownership: keeps `content`, which must not keep the stack. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(
        _ axis: ScrollAxis = .vertical,
        items: [Item] = [],
        lanes: Int = 1,
        estimatedLength: Double,
        spacing: Double = 0,
        content: @escaping @MainActor (Item) -> Node
    ) {
        self.axis = axis
        self.items = items
        self.lanes = lanes
        self.estimatedLength = estimatedLength
        self.spacing = spacing
        self.content = content
        super.init()
    }

    /// Creates a list that prepares model values before asking for their live nodes.
    ///
    /// `key` identifies every application input that changes a plan, including the item's
    /// revision. Identity, item cross-axis constraints, host size, scale, direction, resolved
    /// theme, and locale are added automatically. The key and factory run on the main actor;
    /// keep the key pure and the factory light. All three closures are retained and must
    /// not capture the stack strongly. Supply immutable model snapshots and replace `items`
    /// with a new revision when their preparation inputs change.
    ///
    /// `prepare` runs in a detached task within the per-list budget. It receives only
    /// Sendable values, must cooperate with cancellation, and owns any client waits it starts.
    /// It must not cancel resources shared with other clients. No network resource is required
    /// to finish before a placeholder is shown. Failures reach the factory without automatic
    /// retries. Additional environments such as a custom catalog revision belong in `key`.
    ///
    /// The factory receives pending, ready, or failed state for the current key. It creates
    /// or updates nodes on the main actor, including lightweight placeholders for cold or
    /// urgent entry. Preparation supplies measurement plans; data and drawing phases are
    /// still owned by the content. Plans outside the retained range or count limit are freed.
    public convenience init<Revision: Hashable & Sendable, Value: Sendable>(
        _ axis: ScrollAxis = .vertical,
        items: [Item] = [],
        lanes: Int = 1,
        estimatedLength: Double,
        spacing: Double = 0,
        preparation policy: ItemPreparationPolicy = ItemPreparationPolicy(),
        key: @escaping @MainActor (Item) -> Revision,
        prepare:
            @escaping @Sendable (Item, ItemPreparationContext) async throws -> PreparedItem<Value>,
        content: @escaping @MainActor (Item, PreparedItemState<Value>) -> Node
    ) where Item: Sendable, Item.ID: Sendable {
        let driver = PreparedItems(policy: policy, key: key, prepare: prepare, content: content)
        self.init(
            axis,
            items: items,
            lanes: lanes,
            estimatedLength: estimatedLength,
            spacing: spacing,
            content: { item in driver.node(for: item, context: nil) }
        )
        preparation = driver
        driver.contextIsCurrent = { [weak self] context in
            guard let self, self.isMounted, self.isShown, let host = self.host,
                !host.isInBackground, self.shownRect != nil
            else { return false }
            return self.preparationContext(in: host) == context
        }
        driver.onChange = { [weak self] in self?.setNeedsLayout() }
    }

    /// Ownership: returns a value borrowing the nodes of the items laid out. Isolation:
    /// MainActor. Errors: none. Cancellation: none.
    public override func layoutSpec() -> LayoutSpec? {
        updateStarts()
        let host = self.host ?? NodeHost.preparing
        // About a screen before and after the window, so that the next frames of a scroll
        // find their items laid out.
        let reach = host.map { along($0.size) } ?? 0
        // Where the scrolls around are is looked at, not depended on: the stack asks for a
        // layout itself when the window nears the end of what is laid out, not on every move.
        // Before the first layout its place is unknown: the start of the list, one screen of
        // it, and the reach after.
        var span = untracked { visibleSpan() } ?? (start: 0, end: reach)
        if holdsScroll {
            anchor = nil
        } else {
            untracked { rememberAnchor() }
        }
        let context = host.map { preparationContext(in: $0) }
        if let context, let preparation {
            for (id, length) in preparation.lengths(in: context) where measured[id] != length {
                measured[id] = length
                startsAreStale = true
            }
            updateStarts()
        }
        // Items added, removed or measured before what shows moved it along the stack, and
        // the scroll will follow it there: the window is where it will be then, however far.
        let moved = anchorMoved()
        span = (span.start + moved, span.end + moved)
        let lines = self.lines(from: span.start - reach, to: span.end + reach)
        let range =
            lines.isEmpty
            ? 0..<0 : lines.lowerBound * perLine..<min(items.count, lines.upperBound * perLine)

        placed = range.map { index in
            let item = items[index]
            return (item.id, preparation?.node(for: item, context: context) ?? content(item))
        }
        placedVersion = itemsVersion
        laidOutItems = range
        let total = length
        let before = lines.isEmpty ? total : starts[lines.lowerBound]
        let after = lines.isEmpty ? 0 : total - end(of: lines.upperBound - 1)
        covered =
            lines.isEmpty
            ? (.infinity, -.infinity)
            : (
                lines.lowerBound == 0 ? -.infinity : before,
                lines.upperBound == lineCount ? .infinity : total - after
            )

        let nodes = placed.map(\.node)
        let stack: LayoutSpec
        if perLine == 1 {
            stack = FlexContainer(axis == .vertical ? .column : .row) {
                for node in nodes {
                    node.flex(shrink: 0)
                }
            }
            .gap(spacing)
        } else {
            stack = FlexContainer(axis == .vertical ? .column : .row) {
                for start in stride(from: 0, to: nodes.count, by: perLine) {
                    line(Array(nodes[start..<min(start + perLine, nodes.count)]))
                }
            }
            .gap(spacing)
        }
        switch axis {
        case .vertical:
            return stack.padding(top: before, bottom: after)
        case .horizontal:
            return stack.padding(leading: before, trailing: after)
        }
    }

    /// One line of a grid: its items side by side in equal shares, and empty shares after
    /// the last items of a line that is not full, so they are as wide as the others.
    private func line(_ nodes: [Node]) -> LayoutSpec {
        let share = { (spec: LayoutSpec) -> LayoutSpec in
            switch self.axis {
            case .vertical:
                spec.flex(grow: 1, shrink: 1, basis: .points(0)).limits(minWidth: .points(0))
            case .horizontal:
                spec.flex(grow: 1, shrink: 1, basis: .points(0)).limits(minHeight: .points(0))
            }
        }
        let empty = perLine - nodes.count
        return FlexContainer(axis == .vertical ? .row : .column) {
            for node in nodes {
                share(node.asLayoutSpec)
            }
            for _ in 0..<empty {
                share(FlexContainer {})
            }
        }
        .gap(spacing)
        .flex(shrink: 0)
    }

    // MARK: - Lengths

    /// Items side by side in a line.
    private var perLine: Int { max(1, lanes) }

    private var lineCount: Int { (items.count + perLine - 1) / perLine }

    /// The length of all lines with the spaces between them.
    private var length: Double {
        items.isEmpty ? 0 : starts[lineCount] - spacing
    }

    private func end(of line: Int) -> Double {
        starts[line + 1] - spacing
    }

    private func updateStarts() {
        guard startsAreStale || starts.count != lineCount + 1 else { return }

        startsAreStale = false
        var starts: [Double] = []
        starts.reserveCapacity(lineCount + 1)
        var position = 0.0
        for first in stride(from: 0, to: items.count, by: perLine) {
            starts.append(position)
            var longest = 0.0
            for item in items[first..<min(first + perLine, items.count)] {
                longest = max(longest, measured[item.id] ?? estimatedLength)
            }
            position += longest + spacing
        }
        starts.append(position)
        self.starts = starts
    }

    /// The lines that take any of the part of the stack from `lower` to `upper`.
    private func lines(from lower: Double, to upper: Double) -> Range<Int> {
        let count = lineCount
        guard count > 0, upper > lower else { return 0..<0 }

        // The first line ending after `lower`, and the first starting at or after `upper`.
        let first = partition(count) { end(of: $0) > lower }
        let last = partition(count) { starts[$0] >= upper }
        return first < last ? first..<last : 0..<0
    }

    /// The first index below `count` for which `isPast` holds, or `count`; `isPast` must hold
    /// for every index after one it holds for.
    private func partition(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if isPast(middle) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    // MARK: - Asking for pages

    /// Asks the gate whether the end of the list is near enough, from where the window is.
    private func evaluatePagination(window span: (start: Double, end: Double)) {
        guard pagination != nil, loadMore != nil, isMounted else { return }

        // The window moving along the list is the person scrolling, for the gate: the pages the
        // list asked for on its own are counted from there.
        if let last = lastShownStart, abs(span.start - last) > 0.5 { gate.userDidScroll() }
        lastShownStart = span.start

        updateStarts()
        let total = length
        let shown = lines(from: max(0, span.start), to: min(total, span.end))
        let lastVisible = shown.isEmpty ? nil : min(items.count, shown.upperBound * perLine) - 1
        let metrics = PaginationMetrics(
            count: items.count,
            lastVisible: lastVisible,
            remainingLength: max(0, total - span.end),
            viewportLength: max(0, span.end - span.start)
        )
        if gate.evaluate(metrics, version: itemsVersion, reachedEnd: reachedEnd) == .request {
            startPageLoad(isRetry: false)
        }
    }

    /// Runs `loadMore` for a page the gate counts as in flight.
    private func startPageLoad(isRetry: Bool) {
        guard let load = loadMore else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        let request = PageRequest(
            pageSize: pagination?.pageSize,
            loadedCount: items.count,
            isRetry: isRetry
        )
        pageLoad = Task { [weak self] in
            // The state is written from the task, not from the layout pass that decided to ask.
            self?.loadState.value = .loading
            self?.pageLoadError = nil
            var failure: (any Error)?
            let interval = Trace.begin(
                .pageLoad,
                "loaded \(request.loadedCount)\(isRetry ? " retry" : "")"
            )
            do {
                try await load(request)
            } catch {
                failure = error
            }
            Trace.end(interval)
            guard let self, generation == self.loadGeneration else { return }

            if Task.isCancelled {
                self.gate.cancelInFlight()
                self.loadState.value = .idle
            } else if let failure {
                self.gate.fail()
                self.pageLoadError = failure
                self.loadState.value = .failed
            } else {
                self.gate.complete(count: self.items.count)
                self.loadState.value = .idle
            }
        }
    }

    /// Cancels the page on its way, and forgets it.
    private func cancelPageLoad() {
        loadGeneration &+= 1
        pageLoad?.cancel()
        pageLoad = nil
        if gate.isRequestInFlight {
            gate.cancelInFlight()
            loadState.value = .idle
        }
    }

    /// A page on its way does not outlast the stack's place on the screen: it is asked for
    /// again when the stack shows again, if the end is near.
    public override func mountedChanged(_ isMounted: Bool) {
        if !isMounted {
            preparation?.stop()
            mountedItems = []
            anchor = nil
            cancelPageLoad()
            cancelAllPrefetches()
        }
    }

    /// Suspends model preparation while the host is hidden; showing it refreshes demand.
    public override func shownChanged(_ isShown: Bool) {
        guard preparation != nil else { return }
        if isShown { setNeedsLayout() } else { preparation?.stop() }
    }

    /// Suspends model preparation in the background, without changing existing scroll physics.
    public override func backgroundChanged(_ isInBackground: Bool) {
        guard preparation != nil else { return }
        if isInBackground { preparation?.stop() } else { setNeedsLayout() }
    }

    private func preparationContext(in host: NodeHost) -> ItemPreparationContext {
        ItemPreparationContext(
            axis: axis,
            crossAxisLength: max(
                0,
                (across(frame.size) - Double(perLine - 1) * spacing) / Double(perLine)
            ),
            viewportSize: host.size,
            scale: host.scale,
            direction: host.direction,
            theme: theme,
            locale: locale
        )
    }

    private func updatePreparation() {
        guard let preparation else { return }
        guard isShown, let host, !host.isInBackground, let bounds = shownRect else {
            preparation.stop()
            return
        }
        let viewport = ContentViewport(bounds: bounds)
        let policy = preparation.policy.range
        let windowStart: Double
        let windowEnd: Double
        if isReversed {
            windowStart = frame.size.width - bounds.origin.x - bounds.size.width
            windowEnd = frame.size.width - bounds.origin.x
        } else {
            windowStart = along(bounds.origin)
            windowEnd = windowStart + along(bounds.size)
        }
        updateStarts()
        let reach = along(bounds.size) * policy.preloadRetentionDistance
        // Line lookup uses open intersections, while range thresholds include touching
        // their boundary. Include those candidates and let the range policy decide.
        let near = lines(
            from: max(0, windowStart - reach).nextDown,
            to: min(length, windowEnd + reach).nextUp
        )
        let context = preparationContext(in: host)
        var candidates: [(index: Int, demand: ContentDemand, distance: Double)] = []
        for index in near.lowerBound * perLine..<min(items.count, near.upperBound * perLine) {
            let line = index / perLine
            let itemLength = measured[items[index].id] ?? estimatedLength
            let crossStart = Double(index % perLine) * (context.crossAxisLength + spacing)
            let position = isReversed ? frame.size.width - starts[line] - itemLength : starts[line]
            let itemFrame =
                axis == .vertical
                ? LayoutRect(
                    x: crossStart,
                    y: position,
                    width: context.crossAxisLength,
                    height: itemLength
                )
                : LayoutRect(
                    x: position,
                    y: crossStart,
                    width: itemLength,
                    height: context.crossAxisLength
                )
            var demand = policy.demand(
                for: itemFrame,
                in: viewport,
                previous: preparation.demand(for: items[index].id)
            )
            guard !demand.isEmpty else { continue }
            // Known cross-axis constraints allow geometry preparation throughout preload,
            // independently of fetching bytes or producing the final drawing.
            demand.insert(.measure)
            let distance = max(0, starts[line] - windowEnd, windowStart - end(of: line))
            candidates.append((index, demand, distance))
        }
        func rank(_ demand: ContentDemand) -> Int {
            demand.contains(.visible) ? 0 : demand.contains(.display) ? 1 : 2
        }
        candidates.sort {
            if rank($0.demand) != rank($1.demand) { return rank($0.demand) < rank($1.demand) }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.index < $1.index
        }
        preparation.update(
            candidates.map { ItemPreparationCandidate(item: items[$0.index], demand: $0.demand) },
            context: context
        )
    }

    // MARK: - Where it shows

    private var isReversed: Bool {
        axis == .horizontal && (host ?? NodeHost.preparing)?.direction == .rightToLeft
    }

    private func along(_ point: LayoutPoint) -> Double {
        axis == .vertical ? point.y : point.x
    }

    private func along(_ size: LayoutSize) -> Double {
        axis == .vertical ? size.height : size.width
    }

    private func across(_ size: LayoutSize) -> Double {
        axis == .vertical ? size.width : size.height
    }

    /// The part of the stack that shows, from its start along `axis` — within every node
    /// around it that clips its content, and within the host's bounds; `start` is past `end`
    /// when none of it shows. `nil` before the stack is laid out.
    private func visibleSpan() -> (start: Double, end: Double)? {
        guard isMounted, let host else { return nil }

        var start = -Double.infinity
        var end = Double.infinity
        // Where the stack's box is in the box of `node`.
        var placement = Placement.identity
        /// Keeps to the part of the stack within a box `length` long it is placed in.
        func clip(to length: Double) {
            start = max(start, -along(placement.origin) / placement.scale)
            end = min(end, (length - along(placement.origin)) / placement.scale)
        }
        var node: Node = self
        while let supernode = node.supernode {
            placement = placement.moved(into: supernode, from: node.shownOrigin)
            if supernode.appearance.clipsContent {
                clip(to: along(supernode.frame.size))
            }
            node = supernode
        }
        placement.origin.x += node.frame.origin.x
        placement.origin.y += node.frame.origin.y
        clip(to: along(host.size))
        guard isReversed else { return (start, end) }

        // A row laid out from the right starts at its right edge.
        return (frame.size.width - end, frame.size.width - start)
    }

    /// Where `node`, placed by the stack, starts from the stack's start.
    private func start(of node: Node) -> Double {
        guard isReversed else { return along(node.frame.origin) }

        return frame.size.width - node.frame.origin.x - node.frame.size.width
    }

    /// Whether the stack's subnodes are the nodes its last `layoutSpec()` placed: that
    /// layout has been applied.
    private var placedAreMounted: Bool {
        placed.count == subnodes.count
            && zip(placed, subnodes).allSatisfy { $0.node === $1 && $1.supernode === self }
    }

    // MARK: - Scrolling to an item

    /// Scrolls the nearest scroll around the stack along its axis so that the item with
    /// `id` is where `alignment` puts it in the window — at its start by default, after the
    /// nodes sticking there, such as a section's title — as far as the scroll goes. Inside
    /// `withAnimation` it moves there with the animation — frame by frame when it is far —
    /// and ends on the item however long the items on the way turn out. Returns `false`,
    /// not moving, when no item has that `id` or the stack is not laid out in a scroll.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: another move of
    /// the scroll, or the platform moving it, stops the move.
    @discardableResult
    public func scroll(to id: Item.ID, at alignment: ScrollAlignment = .start) -> Bool {
        guard let scroll, let index = items.firstIndex(where: { $0.id == id }),
            let target = offset(showing: index, at: alignment, in: scroll)
        else { return false }

        scroll.scroll(to: target) { [weak self, weak scroll] in
            guard let self, let scroll,
                let index = self.items.firstIndex(where: { $0.id == id })
            else { return nil }

            return self.offset(showing: index, at: alignment, in: scroll)
        }
        scrolledTo = scroll.isMoving ? nil : (id, alignment, NodeHost.settlingPasses)
        return true
    }

    /// After a layout, puts the item `scroll(to:at:)` moved to back where it went in the
    /// window, if the items laid out around it moved it; returns whether it is still in
    /// charge of where the scroll is.
    private func keepScrolledTo() -> Bool {
        guard let target = scrolledTo, let scroll, !scroll.isMoving,
            let index = items.firstIndex(where: { $0.id == target.id }),
            let offset = offset(showing: index, at: target.alignment, in: scroll)
        else {
            scrolledTo = nil
            return false
        }

        let layouts = target.layouts - 1
        scrolledTo =
            layouts > 0 && scroll.offsetRange.clamp(offset) != scroll.contentOffset
            ? (target.id, target.alignment, layouts) : nil
        scroll.contentOffset = offset
        return true
    }

    /// The offset of `scroll` at which the item at `index` is where `alignment` puts it in
    /// the window, by where the item's line is now; `nil` when the stack is not laid out in
    /// it.
    private func offset(
        showing index: Int,
        at alignment: ScrollAlignment,
        in scroll: Scroll
    ) -> LayoutPoint? {
        guard isMounted, let placement = scroll.placement(of: self) else { return nil }

        updateStarts()
        let box = placement.rect(LayoutRect(origin: .zero, size: frame.size))
        // Where the line is along the stack, as drawn: zoomed, the offset is too.
        let line = index / perLine
        let start = starts[line] * placement.scale
        let length = (end(of: line) - starts[line]) * placement.scale
        let window = axis == .vertical ? scroll.frame.size.height : scroll.frame.size.width
        // How far into the window the line starts.
        func lead(covered: Double) -> Double {
            let fraction: Double
            switch alignment {
            case .start: fraction = 0
            case .center: fraction = 0.5
            case .end: fraction = 1
            }
            // Nodes sticking to the window's start cover that much of it: the line goes to
            // where it shows after them.
            return covered + (window - covered - length) * fraction
        }
        var offset = scroll.targetOffset
        func place(lead: Double) {
            switch axis {
            case .vertical:
                offset.y = box.origin.y + start - lead
            case .horizontal where isReversed:
                // The line's start is its right edge, and the window's start its right edge.
                offset.x = box.origin.x + box.size.width - start - window + lead
            case .horizontal:
                offset.x = box.origin.x + start - lead
            }
        }
        place(lead: lead(covered: 0))
        place(lead: lead(covered: scroll.stuckLength(at: offset)))
        return offset
    }

    // MARK: - Keeping what shows in place

    /// The nearest scroll around the stack along its axis.
    private var scroll: Scroll? {
        var node = supernode
        while let current = node {
            if let scroll = current as? Scroll, scroll.axis == axis { return scroll }

            node = current.supernode
        }
        return nil
    }

    private func rememberAnchor() {
        anchor = nil
        // Showing the start, the window shows what is added there.
        guard let span = visibleSpan(), span.start > 0, span.start < span.end,
            let scroll
        else { return }

        for (id, node, index) in mountedItems where node.isMounted && node.supernode === self {
            let start = start(of: node)
            guard start + along(node.frame.size) > span.start, start < span.end else { continue }

            if let rect = scroll.frame(of: node) {
                anchor = Anchor(
                    id: id,
                    position: along(rect.origin),
                    scroll: scroll,
                    start: start,
                    index: index
                )
            }
            return
        }
    }

    /// How far the anchor's item moved from where it was laid out to where its line starts
    /// now; 0 when there is none, or it is gone.
    private func anchorMoved() -> Double {
        guard let anchor else { return 0 }

        let index: Int
        if anchor.index < items.count, items[anchor.index].id == anchor.id {
            index = anchor.index
        } else if let found = items.firstIndex(where: { $0.id == anchor.id }) {
            // Only after items changed.
            index = found
        } else {
            return 0
        }
        return starts[index / perLine] - anchor.start
    }

    /// The layout that placed `placed` was applied: learns the items' lengths, puts what
    /// showed back in place, and asks for another layout if the window is near the end of
    /// what is laid out.
    func layoutApplied() {
        guard placedAreMounted else { return }

        mountedItems = placed.enumerated().map {
            ($0.element.id, $0.element.node, laidOutItems.lowerBound + $0.offset)
        }
        let across = across(frame.size)
        if measuredAcross != across {
            // Lengths at another width no longer hold.
            measured = [:]
            measuredAcross = across
            startsAreStale = true
        }
        for (id, node) in placed {
            let length = along(node.frame.size)
            if measured[id] != length {
                measured[id] = length
                startsAreStale = true
            }
        }
        if let first = placed.first?.node, let last = placed.last?.node {
            covered = (
                laidOutItems.lowerBound == 0 ? -.infinity : start(of: first),
                laidOutItems.upperBound == items.count
                    ? .infinity : start(of: last) + along(last.frame.size)
            )
        }
        mountedCover = covered

        // An item `scroll(to:)` sent the scroll to decides where it is, not what showed.
        if !keepScrolledTo(), let anchor,
            let node = placed.first(where: { $0.id == anchor.id })?.node,
            let rect = anchor.scroll.frame(of: node)
        {
            let moved = along(rect.origin) - anchor.position
            if moved != 0 {
                // The items that changed are before the window: an animated move going the
                // other way, toward the stack's end, ends on content after them.
                let target = along(anchor.scroll.targetOffset)
                let now = along(anchor.scroll.contentOffset)
                anchor.scroll.shiftOffset(
                    by: axis == .vertical
                        ? LayoutPoint(x: 0, y: moved) : LayoutPoint(x: moved, y: 0),
                    movesTarget: isReversed ? target < now : target > now
                )
            }
        }
        anchor = nil
        // A rejected capture must not consume the caller's request to preserve scroll.
        if placedVersion == itemsVersion { holdsScroll = false }
        viewportMoved()
        if placedVersion == itemsVersion {
            onLayoutApplied?()
        }
    }

    /// Something around the stack moved: asks for a layout if the window, with half a screen
    /// either side, reaches past what is laid out.
    func viewportMoved() {
        guard let host, let span = visibleSpan() else { return }

        updatePreparation()
        evaluatePagination(window: span)
        evaluatePrefetch(window: span)
        updateStarts()
        let reach = along(host.size) / 2
        let needed = (start: max(0, span.start - reach), end: min(length, span.end + reach))
        guard needed.start < needed.end else { return }

        let shown = (start: max(0, span.start), end: min(length, span.end))
        if shown.start < shown.end,
            shown.start < mountedCover.start || shown.end > mountedCover.end
        {
            // Part of what shows is not laid out: it is missing on screen until it is.
            host.setNeedsLayoutNow()
        } else if needed.start < covered.start || needed.end > covered.end {
            setNeedsLayout()
        }
    }

    /// The layout for where the move ends reaches a screen before and after it: the window
    /// where the move starts is laid out then only if it is within that screen.
    func needsFrames(toMove scroll: Scroll, by delta: LayoutPoint) -> Bool {
        guard scroll === self.scroll, let host else { return false }

        return abs(along(delta)) > along(host.size)
    }
}

/// A node whose layout depends on where it shows, told by the host after each layout it is
/// in and whenever a scroll moves.
@MainActor
protocol ViewportDependent: AnyObject {
    func layoutApplied()
    func viewportMoved()
    /// Whether an animated move of `scroll` by `delta`, drawn by the platform from where it
    /// is to where it ends, would pass over parts of the node not laid out.
    func needsFrames(toMove scroll: Scroll, by delta: LayoutPoint) -> Bool
}

extension LazyStack: ViewportDependent {}

/// A list laid out by where it shows, as assistive technologies reach all its items: by
/// index, laid out or not.
@MainActor
protocol AccessibleList: AnyObject {
    var itemCount: Int { get }
    var laidOutItems: Range<Int> { get }
    var itemAxis: ScrollAxis { get }
    /// How many items stand side by side; 1 or more.
    var itemLanes: Int { get }
    /// The index of the item `node`, placed by the list, stands for.
    func index(ofPlaced node: Node) -> Int?
    /// Where the item at `index` is expected to be, in the list's coordinates: where it is,
    /// once laid out.
    func expectedFrame(ofItem index: Int) -> LayoutRect
    /// Scrolls the list's scroll so that the item at `index` shows; returns whether it could.
    func reveal(itemAt index: Int) -> Bool
}

extension LazyStack: AccessibleList {
    var itemCount: Int { items.count }
    var itemAxis: ScrollAxis { axis }
    var itemLanes: Int { perLine }

    func index(ofPlaced node: Node) -> Int? {
        guard placedAreMounted, let offset = placed.firstIndex(where: { $0.node === node })
        else { return nil }

        return laidOutItems.lowerBound + offset
    }

    func expectedFrame(ofItem index: Int) -> LayoutRect {
        updateStarts()
        let line = min(max(0, index / perLine), max(0, lineCount - 1))
        let start = lineCount == 0 ? 0 : starts[line]
        let length = lineCount == 0 ? estimatedLength : end(of: line) - start
        let breadth = across(frame.size)
        let share = (breadth - spacing * Double(perLine - 1)) / Double(perLine)
        let lane = Double(index % perLine) * (share + spacing)
        let rightToLeft = (host ?? NodeHost.preparing)?.direction == .rightToLeft
        switch axis {
        case .vertical:
            return LayoutRect(
                x: rightToLeft ? breadth - lane - share : lane,
                y: start,
                width: share,
                height: length
            )
        case .horizontal:
            return LayoutRect(
                x: isReversed ? frame.size.width - start - length : start,
                y: lane,
                width: length,
                height: share
            )
        }
    }

    func reveal(itemAt index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }

        return scroll(to: items[index].id)
    }
}
