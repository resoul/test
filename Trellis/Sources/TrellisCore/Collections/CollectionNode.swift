import Foundation

/// The shared runtime of ListNode and GridNode (R12a/R12b, ADR 0030–0033): one scroll node,
/// one materialization window, one loader, one update queue and one event dispatcher. The
/// subclasses only choose the window's layout — a list has one item per row, a grid a column
/// layout — so there is no second copy of the reactive or scroll runtime.
///
/// Composition, not inheritance from `ScrollNode`: the container owns a vertical `ScrollNode`
/// (`scrollNode`) whose content is the window. Only items of the display window have nodes;
/// each node is made and updated by the `ItemProvider` and stays with its item ID. Durable item
/// state belongs to the model and reaches a node through its item (P6.9).
///
/// Mounting is automatic: the host finds the container in its committed tree
/// (`HostedContainer`), binds `source` through the mounted session (D14), activates loading and
/// serves commits. Updates keep the item being read in place, also during drag and
/// deceleration: offset shifts are applied by the host in the geometry commit that shows the
/// change (ADR 0031/0032).
///
/// Ownership: owns its scroll node, window, loader, queue and dispatcher; retains `source` and
/// the provider. Isolation: MainActor. Errors: none — load failures are reported through the
/// snapshot's load state. Cancellation: leaving the host cancels the binding, loads and
/// preparation; `dispose()` additionally disposes every item node.
@MainActor
public class CollectionNode<Provider: ItemProvider, SourceItem: Sendable & Equatable>: Node,
    HostedContainer, PageStateRestoring
{
    /// Identity type of the items.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias ItemID = Provider.ItemID

    /// Model type the window and provider see — the source's item for lists and grids, a row
    /// with section context for tables.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Item = Provider.Item

    /// The latest-value data source; the model publishes snapshots here.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let source: StateSubject<CollectionSnapshot<ItemID, SourceItem>>

    /// The scroll node that owns the native scroll view.
    ///
    /// Ownership: owned child. Isolation: MainActor. Errors: none. Cancellation: disposed with
    /// the list.
    public let scrollNode: ScrollNode

    /// The materialization window placed inside `scrollNode`.
    ///
    /// Ownership: owned. Isolation: MainActor. Errors: none. Cancellation: disposed with the
    /// list.
    public let window: MaterializationWindow<Provider>

    /// Loading hooks (`onLoad`, `onRefresh`, `onLoadMore`, `onRetry`) and their task owner.
    ///
    /// Ownership: owned. Isolation: MainActor. Errors: none. Cancellation: deactivated when the
    /// list leaves its host.
    public let loader: CollectionLoader<ItemID, SourceItem>

    /// Event closures and the weak delegate.
    ///
    /// Ownership: owned. Isolation: MainActor. Errors: none. Cancellation: `removeAll()`.
    public let events = CollectionEventDispatcher<ItemID>()

    /// Sum of anchor shifts the host has applied to the native offset — a diagnostic that lets
    /// a consumer separate the list's own corrections from user scrolling.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var appliedOffsetShift = 0.0

    private let transform:
        @MainActor (CollectionSnapshot<ItemID, SourceItem>) -> CollectionSnapshot<
            ItemID, Item
        >
    private let queue: CollectionUpdateQueue<Provider>
    private weak var host: (any ContainerHost)?
    private var binding: (any ContainerBinding)?
    private var pendingDelta = 0.0
    private var reveal: PendingReveal?
    private var revealGeneration: UInt64 = 0
    private var pendingPosition: CollectionPagePosition<ItemID>?

    private struct PendingReveal {
        let id: ItemID
        let alignment: ScrollAlignment
        let animated: Bool
        let generation: UInt64
        let completion: (@MainActor (CollectionScrollResult) -> Void)?
        var topInset = 0.0
        var attempts = 0
        var awaitingCommit = false
    }

    init(
        source: StateSubject<CollectionSnapshot<ItemID, SourceItem>>,
        provider: Provider,
        transform:
            @escaping @MainActor (CollectionSnapshot<ItemID, SourceItem>) -> CollectionSnapshot<
                ItemID, Item
            >,
        grid: GridLayout?,
        estimatedLength: Double,
        spacing: Double,
        pagination: PaginationPolicy,
        ranges: PreparationRanges,
        maximumMaterializedCount: Int,
        style: LayoutStyle
    ) {
        self.source = source
        self.transform = transform
        let window = MaterializationWindow(
            provider: provider,
            axis: .vertical,
            estimatedLength: estimatedLength,
            spacing: spacing,
            ranges: ranges,
            maximumMaterializedCount: maximumMaterializedCount,
            dataKey: source.current.dataKey
        )
        window.grid = grid
        self.window = window
        self.loader = CollectionLoader(source: source, pagination: pagination)
        self.queue = CollectionUpdateQueue(window: window)
        var scrollStyle = LayoutStyle()
        // ADR 0026: a scroll container scrolls along its flex main axis.
        scrollStyle.flexDirection = .column
        scrollStyle.flexGrow = 1
        scrollStyle.flexShrink = 1
        scrollStyle.alignSelf = .stretch
        self.scrollNode = ScrollNode(style: scrollStyle)
        var listStyle = style
        listStyle.flexDirection = .column
        super.init(style: listStyle)
        scrollNode.configuration = ScrollConfiguration(axis: .vertical)
        scrollNode.addSubnode(window.content)
        addSubnode(scrollNode)
        scrollNode.onScrollStateChanged = { [weak self] state in
            self?.scrollStateChanged(state)
        }
        window.onOffsetAdjustment = { [weak self] adjustment in
            self?.adjustNativeOffset(by: adjustment.delta)
        }
        queue.onCommit = { [weak self] _ in
            guard let self else { return }

            self.didCommit(self.window.snapshot)
        }
        window.apply(transform(source.current))
    }

    /// Asks the loader to refresh (pull-to-refresh, a toolbar button).
    ///
    /// Ownership: may start one load task. Isolation: MainActor. Errors: none. Cancellation:
    /// see `CollectionLoader.refresh()`.
    public func refresh() {
        loader.refresh()
    }

    /// Asks the loader to repeat the failed operation.
    ///
    /// Ownership: may start one load task. Isolation: MainActor. Errors: none. Cancellation:
    /// see `CollectionLoader.retry()`.
    public func retry() {
        loader.retry()
    }

    /// Keeps the viewport at the end when it was there (chat-like feeds). Off by default.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var followsBottom: Bool {
        get { window.followsBottom }
        set { window.followsBottom = newValue }
    }

    /// Scrolls to the item `id`, also when it has no node yet (P6.9): the item is revealed at
    /// its estimated position, materialized, measured and revealed again until its committed
    /// frame is in place. A later call, a scroll command on `scrollNode` or user scrolling
    /// cancels the previous reveal; an ID missing from the committed snapshot — or removed
    /// before the reveal finished — yields `.notFound`. Loading a range the snapshot does not
    /// contain is the model's job; reveal again after it published the snapshot.
    ///
    /// Ownership: retains `completion` until it runs exactly once. Isolation: MainActor.
    /// Errors: none — every result is a `CollectionScrollResult`. Cancellation: superseding,
    /// user input and detach resolve the pending reveal.
    public func scrollTo(
        _ id: ItemID,
        alignment: ScrollAlignment = .start,
        animated: Bool = false,
        completion: (@MainActor (CollectionScrollResult) -> Void)? = nil
    ) {
        startReveal(id, alignment: alignment, animated: animated, topInset: 0, completion)
    }

    private func startReveal(
        _ id: ItemID,
        alignment: ScrollAlignment,
        animated: Bool,
        topInset: Double,
        _ completion: (@MainActor (CollectionScrollResult) -> Void)?
    ) {
        finishReveal(.cancelled)
        guard !isDisposed, host != nil else {
            completion?(.notAttached)
            return
        }
        guard window.snapshot.contains(id) else {
            Log.on(
                .event,
                "reveal-not-found",
                host: window.correlation.host,
                node: self.id,
                "item=\(id)"
            )
            completion?(.notFound)
            return
        }

        revealGeneration &+= 1
        reveal = PendingReveal(
            id: id,
            alignment: alignment,
            animated: animated,
            generation: revealGeneration,
            completion: completion,
            topInset: topInset
        )
        stepReveal()
    }

    // MARK: Page state (R13, P6.9)

    /// The reading position: the first visible item and its distance from the viewport top.
    /// `nil` before the first viewport or with no items.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var pagePosition: CollectionPagePosition<ItemID>? {
        guard let first = window.visibleIDs.first, let index = window.snapshot.index(of: first)
        else { return nil }

        return CollectionPagePosition(
            itemID: first,
            offsetFromTop: window.itemOffset(at: index) - window.offset
        )
    }

    /// Restores a reading position once the container is mounted and has a viewport: the item
    /// is revealed at the same distance from the top. An item no longer in the data is ignored.
    ///
    /// Ownership: keeps the value until applied. Isolation: MainActor. Errors: none.
    /// Cancellation: a user scroll or a later reveal replaces it.
    public func restore(_ position: CollectionPagePosition<ItemID>) {
        pendingPosition = position
        restorePendingPosition()
    }

    /// Captures the reading position (and a table's selection) for a pager evicting this
    /// page.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func capturePageState() -> PageState? {
        let position = pagePosition
        let extras = pageExtras()
        guard position != nil || extras != nil else { return nil }

        return PageState(CollectionPageSnapshot(position: position, extras: extras))
    }

    /// Restores a state captured by `capturePageState()`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: a state of another type is ignored.
    /// Cancellation: not applicable.
    public func restorePageState(_ state: PageState) {
        guard let snapshot = state.value as? CollectionPageSnapshot<ItemID> else { return }

        if let extras = snapshot.extras {
            restorePageExtras(extras)
        }
        if let position = snapshot.position {
            restore(position)
        }
    }

    /// Container-specific page state beyond the position; subclasses override.
    func pageExtras() -> (any Sendable)? { nil }

    /// Restores what `pageExtras()` returned.
    func restorePageExtras(_ extras: any Sendable) {}

    private func restorePendingPosition() {
        guard let position = pendingPosition, host != nil, window.extents.count > 0,
            scrollNode.state.viewportSize.height > 0
        else { return }

        pendingPosition = nil
        guard window.snapshot.contains(position.itemID) else { return }

        startReveal(
            position.itemID,
            alignment: .start,
            animated: false,
            topInset: position.offsetFromTop,
            nil
        )
    }

    // MARK: HostedContainer

    /// Binds `source`, activates loading and joins the host's preparation budget.
    ///
    /// Ownership: keeps `host` weakly and the binding handle strongly. Isolation: MainActor.
    /// Errors: none. Cancellation: undone by `hostDidDetach()`.
    public func hostDidAttach(_ host: any ContainerHost) {
        guard !isDisposed else { return }

        self.host = host
        let correlation = CollectionCorrelation(host: host.hostID)
        window.correlation = correlation
        loader.correlation = correlation
        window.budget = host.materializationBudget
        binding?.cancel()
        binding = host.bindContainerState(source) { [weak self] snapshot in
            self?.deliver(snapshot)
        }
        queue.attach()
        loader.activate()
    }

    /// Records committed item lengths (keeping the anchor) and re-evaluates pagination.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func hostDidCommit(_ commit: ContainerCommit) {
        guard !isDisposed, host != nil else { return }

        window.correlation.generation = commit.generation
        loader.correlation.generation = commit.generation
        window.recordMeasurements()
        afterDataChange()
        if reveal?.awaitingCommit == true, pendingDelta == 0 {
            stepReveal()
        }
        restorePendingPosition()
    }

    /// Cancels the binding, loads and preparation; the next attach starts them again without
    /// repeating loaded data.
    ///
    /// Ownership: releases host resources. Isolation: MainActor. Errors: none. Cancellation:
    /// this is the cancellation point.
    public func hostDidDetach() {
        finishReveal(.notAttached)
        binding?.cancel()
        binding = nil
        loader.deactivate()
        queue.detach()
        window.budget = nil
        window.correlation = CollectionCorrelation()
        loader.correlation = CollectionCorrelation()
        pendingDelta = 0
        host = nil
    }

    /// Detaches from the host, then disposes every item node and the scroll node.
    ///
    /// Ownership: releases everything the list owns. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal.
    public override func dispose() {
        guard !isDisposed else { return }

        hostDidDetach()
        events.removeAll()
        window.dispose()
        super.dispose()
    }

    // MARK: Private

    private func deliver(_ sourceSnapshot: CollectionSnapshot<ItemID, SourceItem>) {
        loader.sourceDidChange()
        let snapshot = transform(sourceSnapshot)
        // Nothing to preserve yet: commit synchronously so the first frame has the data.
        if window.snapshot.count == 0 || window.snapshot.dataKey != snapshot.dataKey {
            window.apply(snapshot)
            didCommit(window.snapshot)
        } else {
            queue.submit(snapshot)
        }
    }

    /// Re-derives the window's snapshot from the current source value and commits it
    /// synchronously — for presentation state folded into rows (selection, table chrome).
    func refreshPresentation() {
        guard !isDisposed else { return }

        window.apply(transform(source.current))
        didCommit(window.snapshot)
    }

    private func didCommit(_ snapshot: CollectionSnapshot<ItemID, Item>) {
        if let reveal, !snapshot.contains(reveal.id) {
            finishReveal(.notFound)
        }
        didApply(snapshot)
        afterDataChange()
    }

    /// Called after every committed snapshot; subclasses reconcile per-item interaction state.
    func didApply(_ snapshot: CollectionSnapshot<ItemID, Item>) {}

    private func scrollStateChanged(_ state: ScrollState) {
        window.updateViewport(
            offset: state.offset.y + pendingDelta,
            length: state.viewportSize.height,
            crossExtent: state.viewportSize.width
        )
        if state.isUserDriven {
            pendingPosition = nil
            finishReveal(.cancelled)
            loader.userDidScroll()
        }
        events.scrollPhaseChanged(state.phase)
        afterDataChange()
    }

    private func afterDataChange() {
        events.visibleItemsChanged(window.visibleIDs)
        loader.evaluateDemand(in: window)
    }

    private func adjustNativeOffset(by delta: Double) {
        guard let host, delta != 0 else { return }

        pendingDelta += delta
        host.adjustScrollOffset(of: scrollNode, by: LayoutPoint(x: 0, y: delta)) { [weak self] in
            self?.pendingDelta -= delta
            self?.appliedOffsetShift += delta
        }
    }

    private func stepReveal() {
        guard var pending = reveal, let host else { return }
        guard let index = window.snapshot.index(of: pending.id) else {
            finishReveal(.notFound)
            return
        }

        pending.attempts += 1
        pending.awaitingCommit = false
        reveal = pending
        guard pending.attempts <= Self.maximumRevealAttempts else {
            Log.on(
                .event,
                "reveal-unsettled",
                host: window.correlation.host,
                node: id,
                "item=\(pending.id)"
            )
            finishReveal(.completed)
            return
        }

        let row = index / max(1, window.columnCount)
        let frame = LayoutFrame(
            origin: LayoutPoint(x: 0, y: window.itemOffset(at: index) - pending.topInset),
            width: 0,
            height: window.extents.length(of: row)
        )
        let before = window.offset
        let generation = pending.generation
        host.scrollContainer(
            scrollNode,
            .reveal(frame: frame, alignment: pending.alignment, animated: pending.animated)
        ) { [weak self] outcome in
            guard let self, self.reveal?.generation == generation else { return }

            switch outcome {
            case .completed(let state):
                if abs(state.offset.y - before) < 0.5, self.isLaidOut(index) {
                    self.finishReveal(.completed)
                } else {
                    self.reveal?.awaitingCommit = true
                }
            case .supersededByLaterCommand, .cancelledByUserInput:
                self.finishReveal(.cancelled)
            case .notAttached:
                self.finishReveal(.notAttached)
            }
        }
    }

    /// Whether the item at `index` has a committed frame at its current window position.
    private func isLaidOut(_ index: Int) -> Bool {
        let id = window.snapshot.items[index].id
        guard let frame = window.node(for: id)?.calculatedFrame,
            abs(frame.origin.y - window.itemOffset(at: index)) < 0.5
        else { return false }
        guard window.columnCount == 1 else { return true }

        return abs(frame.height - window.extents.length(of: index)) < 0.5
    }

    private func finishReveal(_ result: CollectionScrollResult) {
        guard let pending = reveal else { return }

        reveal = nil
        Log.on(
            .event,
            "reveal-finished",
            host: window.correlation.host,
            node: id,
            "item=\(pending.id) result=\(result) attempts=\(pending.attempts)"
        )
        pending.completion?(result)
    }

    private static var maximumRevealAttempts: Int { 8 }
}

/// Result of `CollectionNode.scrollTo(_:alignment:animated:completion:)` (P6.9).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionScrollResult: Sendable, Hashable {
    /// The item's committed frame is at the requested alignment (or as close as clamping
    /// allows).
    case completed
    /// A later reveal or scroll command, or user scrolling, replaced this one; the viewport
    /// stays where that left it.
    case cancelled
    /// The ID is not in the committed snapshot, or was removed before the reveal finished.
    case notFound
    /// The container is not mounted in a host.
    case notAttached
}

/// A container's reading position: an item and its distance from the viewport top (R13).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionPagePosition<ItemID: Hashable & Sendable>: Sendable, Hashable {
    /// The anchor item.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let itemID: ItemID

    /// Distance of the item's leading edge from the viewport top (negative when it starts
    /// above).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let offsetFromTop: Double

    /// Creates a position.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(itemID: ItemID, offsetFromTop: Double) {
        self.itemID = itemID
        self.offsetFromTop = offsetFromTop
    }
}

/// What a collection container keeps for a pager while its page is evicted.
struct CollectionPageSnapshot<ItemID: Hashable & Sendable>: Sendable {
    let position: CollectionPagePosition<ItemID>?
    let extras: (any Sendable)?
}
