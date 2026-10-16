import Foundation

/// The windowed materialization core shared by ListNode, GridNode and TableNode (R10,
/// ADR 0030). It owns one `content` node that the container places inside its own
/// `ScrollNode` (composition, not inheritance): `content` is sized to the whole run's extent
/// and holds absolutely positioned nodes only for the items of the display window. Live UI is
/// therefore bounded by the window and `maximumMaterializedCount`, never by the model count.
///
/// Item identity is the snapshot's stable ID: an item that stays in the window keeps its
/// node across snapshots, an item that leaves it has its node disposed, and a changed model
/// reaches the node through `ItemProvider.update`. Lengths come from `ItemMeasurementCache`
/// when the model, cross extent and environment match, otherwise from `estimatedLength`;
/// `recordMeasurements()` feeds real lengths back after a layout commit. Anchor preservation
/// during those corrections is R11's transaction layer, not this type.
///
/// Ownership: owns `content`, the live item nodes, the measurement cache and the retained
/// provider; the embedding container owns this window and places `content`. Isolation:
/// MainActor. Errors: none — invalid input is clamped and diagnosed through `Log`.
/// Cancellation: `dispose()` disposes every live node and `content`; nothing is scheduled
/// asynchronously by this type.
@MainActor
public final class MaterializationWindow<Provider: ItemProvider> {
    /// Identity type of the items.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias ItemID = Provider.ItemID

    /// Model type of the items.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Item = Provider.Item

    /// The node that holds materialized items; the container adds it to its `ScrollNode`.
    ///
    /// Ownership: owned by this window. Isolation: MainActor. Errors: none. Cancellation:
    /// disposed by `dispose()`.
    public let content: Node

    /// Scrolled axis. `.both` is not a collection axis and is treated as `.vertical`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let axis: ScrollAxis

    /// Main-axis length assumed for an item that has no valid measurement.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var estimatedLength: Double {
        didSet { if estimatedLength != oldValue { _ = rebuild(reason: "estimate") } }
    }

    /// Gap between consecutive items.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var spacing: Double {
        didSet { if spacing != oldValue { _ = rebuild(reason: "spacing") } }
    }

    /// Column layout for a vertical grid, or `nil` for a list (one item per row). Changing it
    /// reflows rows and keeps the anchor. Ignored on a horizontal axis.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var grid: GridLayout? {
        didSet { if grid != oldValue { _ = rebuild(reason: "grid") } }
    }

    /// Display and preload distances around the viewport.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var ranges: PreparationRanges {
        didSet { if ranges != oldValue { materialize() } }
    }

    /// Upper bound on live item nodes regardless of viewport size.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var maximumMaterializedCount: Int {
        didSet { if maximumMaterializedCount != oldValue { materialize() } }
    }

    /// The last applied snapshot.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var snapshot: CollectionSnapshot<ItemID, Item>

    /// Row positions for the current snapshot, measurements and cross extent. A list has one
    /// item per row; use `itemOffset(at:)`/`itemIndex(at:)` for item-level positions.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var extents = ItemExtentIndex(lengths: [])

    /// The window computed at the last materialization.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var window = VirtualizationWindow(
        visible: 0..<0,
        display: 0..<0,
        preload: 0..<0
    )

    /// Host and render generation for diagnostics (P6.12); `none` until the container is
    /// mounted. Data revision and data key travel in `details`, never in `gen`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var correlation = CollectionCorrelation()

    /// Preparation priority inside the host budget. Raising it takes effect at the next
    /// materialization; lowering it lets more urgent windows reclaim margin at the next pass.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var priority: MaterializationPriority = .active {
        didSet { if priority > oldValue { materialize() } }
    }

    /// The host's shared budget, or `nil` for an unbudgeted window (only its own cap applies).
    /// The window registers itself weakly and unregisters on `dispose()` or replacement.
    ///
    /// Ownership: the window retains the budget; the budget references the window weakly.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var budget: MaterializationBudget? {
        didSet {
            guard budget !== oldValue else { return }

            oldValue?.unregister(self)
            budget?.register(self)
            materialize()
        }
    }

    /// Keeps the viewport at the end when it was there before a commit (chat-like feeds).
    /// Off by default: insertions never pull a reading user down (P6.4).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var followsBottom = false

    /// Distance from the end, in points, that still counts as "at the bottom".
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var bottomTolerance = 1.0

    /// Called whenever a commit, measurement correction or viewport change moves the offset
    /// that keeps the anchor in place; the container applies it to its `ScrollNode` without
    /// animation. Return values of the same calls carry the same adjustment.
    ///
    /// Ownership: retained; capture the container weakly. Isolation: MainActor. Errors: none.
    /// Cancellation: assign `nil`.
    public var onOffsetAdjustment: (@MainActor (CollectionAdjustment<ItemID>) -> Void)?

    /// Current physical scroll offset as the window understands it, including its own
    /// adjustments.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var offset: Double { physicalOffset }

    /// Receives formatted diagnostic lines instead of `Log` — a test hook for P6.12 format
    /// checks; every area is delivered while it is set.
    var diagnosticSink: ((String) -> Void)?

    private let provider: Provider
    private var cache = ItemMeasurementCache<ItemID, Item>()
    private var live: [ItemID: LiveItem] = [:]
    private var order: [ItemID] = []
    private var physicalOffset = 0.0
    private var viewportLength = 0.0
    private var crossExtent = 0.0
    private var environmentRevision: UInt64 = 0
    private var direction = ScrollDirectionHint.forward
    private var isDisposed = false
    private var requiredCount = 0
    private var itemLengths: [Double] = []
    private var columns = 1
    private var cellWidth = 0.0
    private var commitGeneration: UInt64 = 0
    private var cacheVersion: UInt64 = 0

    private struct AnchorCapture {
        let snapshot: CollectionSnapshot<ItemID, Item>
        let extents: ItemExtentIndex
        let columns: Int
        let logicalOffset: Double
        let index: Int
        let atBottom: Bool
    }

    private struct LiveItem {
        let node: Provider.Content
        let item: Item
    }

    /// Creates an empty window.
    ///
    /// Ownership: retains `provider`; creates and owns `content`. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(
        provider: Provider,
        axis: ScrollAxis = .vertical,
        estimatedLength: Double = 44,
        spacing: Double = 0,
        ranges: PreparationRanges = PreparationRanges(),
        maximumMaterializedCount: Int = 64,
        dataKey: String = ""
    ) {
        self.provider = provider
        self.axis = axis == .horizontal ? .horizontal : .vertical
        self.estimatedLength = estimatedLength.isFinite ? max(0, estimatedLength) : 0
        self.spacing = spacing
        self.ranges = ranges
        self.maximumMaterializedCount = max(0, maximumMaterializedCount)
        self.snapshot = .initial(dataKey: dataKey)
        self.content = Node()
        if axis == .both {
            log(.schedule, "axis-unsupported", "axis=both fallback=vertical")
        }
    }

    /// Item IDs that currently have live nodes, in display order.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var materializedIDs: [ItemID] { order }

    /// The live node of `id`, or `nil` when the item is outside the window.
    ///
    /// Ownership: the window keeps owning the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func node(for id: ItemID) -> Provider.Content? {
        live[id]?.node
    }

    /// Visible item IDs in display order.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var visibleIDs: [ItemID] {
        window.visible.map { snapshot.items[$0].id }
    }

    /// Number of stored measurements — bounded by the snapshot.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var measurementCount: Int { cache.count }

    /// Items per row: 1 for a list, the grid's current column count otherwise.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var columnCount: Int { columns }

    /// Leading offset along the scrolled axis of the item at `index` (its row's offset).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none; the index is clamped.
    /// Cancellation: not applicable.
    public func itemOffset(at index: Int) -> Double {
        extents.offset(of: max(0, index) / columns)
    }

    /// Index of the first item of the row containing `position`, or `nil` for no items.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func itemIndex(at position: Double) -> Int? {
        guard let row = extents.index(at: position) else { return nil }

        return min(row * columns, max(0, snapshot.count - 1))
    }

    /// Applies a new snapshot synchronously: prepares it on the MainActor and commits it, keeping
    /// the reading position (R11). Large or frequent updates go through
    /// `CollectionUpdateQueue`, which prepares on a worker. A new data key drops every live node
    /// and measurement and starts at offset 0.
    ///
    /// Ownership: takes ownership of `newSnapshot`. Isolation: MainActor. Errors: none.
    /// Cancellation: ignored after `dispose()`.
    @discardableResult
    public func apply(_ newSnapshot: CollectionSnapshot<ItemID, Item>) -> CollectionAdjustment<
        ItemID
    >? {
        guard !isDisposed,
            let prepared = PreparedCollection.prepare(
                preparationInput(for: newSnapshot),
                cancellable: false
            )
        else { return nil }

        return try? commit(prepared).get()
    }

    /// Captures the values a worker needs to prepare `newSnapshot` against the committed state.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func preparationInput(
        for newSnapshot: CollectionSnapshot<ItemID, Item>
    ) -> CollectionPreparationInput<ItemID, Item> {
        let sameKey = newSnapshot.dataKey == snapshot.dataKey
        return CollectionPreparationInput(
            base: snapshot,
            target: newSnapshot,
            cache: sameKey ? cache : ItemMeasurementCache(),
            key: currentKey()
        )
    }

    /// Commits a prepared result atomically: snapshot, positions and measurements switch
    /// together, the anchor keeps its viewport position (or follow-bottom / neighbour rules
    /// apply), then the window re-materializes. A result prepared against another commit, or
    /// under different metrics, is rejected whole — nothing is partially applied.
    ///
    /// Ownership: takes the prepared values. Isolation: MainActor. Errors:
    /// `CollectionCommitRejection`; the caller prepares again. Cancellation: rejected after
    /// `dispose()`.
    public func commit(
        _ prepared: PreparedCollection<ItemID, Item>
    ) -> Result<CollectionAdjustment<ItemID>, CollectionCommitRejection> {
        guard !isDisposed else { return .failure(.disposed) }
        guard prepared.key.commitGeneration == commitGeneration else {
            log(
                .commit,
                "dataset-rejected",
                "reason=stale-base dataRevision=\(prepared.snapshot.revision)"
            )
            return .failure(.staleBase)
        }

        guard prepared.key.metrics == currentMetrics() else {
            log(
                .commit,
                "dataset-rejected",
                "reason=stale-metrics dataRevision=\(prepared.snapshot.revision)"
            )
            return .failure(.staleMetrics)
        }

        let sameKey = prepared.snapshot.dataKey == snapshot.dataKey
        let capture = sameKey ? captureAnchor() : nil
        if !sameKey {
            disposeLiveItems()
            cache = prepared.cache
        } else if prepared.key.cacheVersion == cacheVersion {
            cache = prepared.cache
        } else {
            // Measurements recorded while the worker ran stay; the next correction uses them.
            cache.prune(keeping: prepared.snapshot)
        }
        snapshot = prepared.snapshot
        install(prepared.geometry, metrics: prepared.key.metrics)
        commitGeneration &+= 1
        cacheVersion &+= 1
        log(
            .commit,
            "dataset-applied",
            "dataKey=\(snapshot.dataKey) dataRevision=\(snapshot.revision) "
                + "items=\(snapshot.count) droppedDuplicates=\(snapshot.droppedDuplicateCount) "
                + "inserted=\(prepared.diff.inserted) removed=\(prepared.diff.removed) "
                + "updated=\(prepared.diff.updated) moved=\(prepared.diff.moved) "
                + "measureHit=\(prepared.measurementHits)"
        )
        setContentExtent(extents.totalExtent)
        let adjustment = restore(capture, resetToStart: !sameKey)
        materialize()
        return .success(adjustment)
    }

    /// Updates the viewport. An offset-only change recomputes the window without rebuilding
    /// positions; a changed cross extent or environment revision re-resolves lengths.
    ///
    /// A cross-extent or environment change re-resolves lengths and keeps the anchor; the
    /// returned adjustment (if any) is the offset the container applies.
    ///
    /// `offset` is the scroll view's physical offset. On a horizontal axis in right-to-left
    /// layout, item 0 sits at the trailing (right) end of `content`, so the window converts the
    /// offset to a logical one measured from that end.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none — non-finite values are ignored.
    /// Cancellation: ignored after `dispose()`.
    @discardableResult
    public func updateViewport(
        offset: Double,
        length: Double,
        crossExtent newCross: Double
    ) -> CollectionAdjustment<ItemID>? {
        guard !isDisposed, offset.isFinite, length.isFinite, newCross.isFinite else { return nil }

        let previous = viewportOffset
        physicalOffset = offset
        viewportLength = max(0, length)
        if viewportOffset != previous {
            direction = viewportOffset > previous ? .forward : .backward
        }
        let environment = content.environmentSnapshot.layoutRevision
        if newCross != crossExtent || environment != environmentRevision {
            crossExtent = max(0, newCross)
            environmentRevision = environment
            return rebuild(reason: "viewport")
        }

        materialize()
        return nil
    }

    /// Reads committed layout lengths of live nodes into the measurement cache. When a length
    /// differed from the one used for positioning, positions are rebuilt keeping the anchor,
    /// and the adjustment is returned; the caller schedules another layout pass. `nil` means
    /// nothing changed.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: ignored after
    /// `dispose()`.
    @discardableResult
    public func recordMeasurements() -> CollectionAdjustment<ItemID>? {
        guard !isDisposed, currentMetrics().fixedLength == nil else { return nil }

        var changed = 0
        for id in order {
            guard let entry = live[id], let frame = entry.node.calculatedFrame,
                let index = snapshot.index(of: id)
            else { continue }

            let measured = axis == .horizontal ? frame.width : frame.height
            cache.record(
                measured,
                for: id,
                item: entry.item,
                crossExtent: cellWidth,
                environmentRevision: environmentRevision
            )
            if index >= itemLengths.count || measured != itemLengths[index] {
                changed += 1
            }
        }
        guard changed > 0 else { return nil }

        cacheVersion &+= 1
        log(.measure, "items-measured", "changed=\(changed)")
        return rebuild(reason: "measurement")
    }

    /// Disposes every live node and `content`. Terminal and idempotent.
    ///
    /// Ownership: releases all nodes and the measurement cache. Isolation: MainActor.
    /// Errors: none. Cancellation: this is the cancellation point.
    public func dispose() {
        guard !isDisposed else { return }

        isDisposed = true
        budget?.unregister(self)
        disposeLiveItems()
        cache = ItemMeasurementCache()
        content.dispose()
    }

    private func rebuild(reason: String) -> CollectionAdjustment<ItemID>? {
        guard !isDisposed else { return nil }

        let capture = captureAnchor()
        let metrics = currentMetrics()
        guard
            let geometry = CollectionGeometry.resolve(
                items: snapshot.items,
                cache: cache,
                metrics: metrics
            )
        else { return nil }

        install(geometry, metrics: metrics)
        log(
            .measure,
            "extents-rebuilt",
            "reason=\(reason) columns=\(columns) hit=\(geometry.hits) "
                + geometry.misses.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "miss.\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
        )
        setContentExtent(extents.totalExtent)
        let adjustment = restore(capture, resetToStart: false)
        materialize()
        return adjustment
    }

    private func currentKey() -> PreparationKey {
        PreparationKey(
            commitGeneration: commitGeneration,
            cacheVersion: cacheVersion,
            metrics: currentMetrics()
        )
    }

    private func currentMetrics() -> CollectionMetrics {
        CollectionMetrics(
            crossExtent: crossExtent,
            grid: axis == .vertical ? grid : nil,
            estimatedLength: estimatedLength,
            spacing: spacing,
            environmentRevision: environmentRevision
        )
    }

    private func install(_ geometry: CollectionGeometry, metrics: CollectionMetrics) {
        extents = geometry.rows
        itemLengths = geometry.itemLengths
        columns = max(1, metrics.columns)
        cellWidth = metrics.cellWidth
    }

    /// Records the item at the top of the viewport with the extents it was positioned by.
    private func captureAnchor() -> AnchorCapture? {
        // Nothing sized yet: there is no position to keep (#87).
        guard viewportLength > 0, extents.totalExtent > 0, let index = itemIndex(at: viewportOffset)
        else { return nil }

        return AnchorCapture(
            snapshot: snapshot,
            extents: extents,
            columns: columns,
            logicalOffset: viewportOffset,
            index: index,
            atBottom: viewportOffset + viewportLength >= extents.totalExtent - bottomTolerance
        )
    }

    /// Moves the offset so the anchor (or its nearest surviving neighbour in the old order)
    /// keeps its viewport position under the new extents, then clamps (P6.4, ADR 0030).
    private func restore(_ capture: AnchorCapture?, resetToStart: Bool) -> CollectionAdjustment<
        ItemID
    > {
        let before = physicalOffset
        let maximum = max(0, extents.totalExtent - viewportLength)
        var logical = resetToStart ? 0 : min(viewportOffset, maximum)
        var outcome = CollectionAnchorOutcome<ItemID>.none
        if let capture {
            if followsBottom, capture.atBottom {
                logical = maximum
                outcome = .followedBottom
            } else if let survivor = survivor(of: capture) {
                logical = itemOffset(at: survivor.newIndex) - survivor.viewportPosition
                outcome = survivor.isAnchor ? .preserved(survivor.id) : .neighbour(survivor.id)
            }
        }
        let clampedLogical = min(max(0, logical), maximum)
        setLogicalOffset(clampedLogical)
        let adjustment = CollectionAdjustment(
            anchor: outcome,
            offset: physicalOffset,
            clamped: abs(clampedLogical - logical) > 0.000_1,
            offsetChanged: physicalOffset != before,
            delta: physicalOffset - before
        )
        if adjustment.offsetChanged {
            log(
                .commit,
                "anchor-restored",
                "anchor=\(outcome) offset=\(physicalOffset) clamped=\(adjustment.clamped)"
            )
            onOffsetAdjustment?(adjustment)
        }
        return adjustment
    }

    private func survivor(
        of capture: AnchorCapture
    ) -> (id: ItemID, newIndex: Int, viewportPosition: Double, isAnchor: Bool)? {
        let old = capture.snapshot.items
        func candidate(_ oldIndex: Int) -> (ItemID, Int, Double)? {
            guard oldIndex >= 0, oldIndex < old.count,
                let newIndex = snapshot.index(of: old[oldIndex].id)
            else { return nil }

            let position =
                capture.extents.offset(of: oldIndex / capture.columns) - capture.logicalOffset
            return (old[oldIndex].id, newIndex, position)
        }

        if let found = candidate(capture.index) {
            return (found.0, found.1, found.2, true)
        }

        var distance = 1
        while capture.index - distance >= 0 || capture.index + distance < old.count {
            if let found = candidate(capture.index + distance)
                ?? candidate(capture.index - distance)
            {
                return (found.0, found.1, found.2, false)
            }
            distance += 1
        }
        return nil
    }

    private func setLogicalOffset(_ logical: Double) {
        if axis == .horizontal, isRightToLeft {
            physicalOffset = extents.totalExtent - logical - viewportLength
        } else {
            physicalOffset = logical
        }
    }

    /// Logical viewport offset: physical, except horizontal right-to-left, where it is measured
    /// from the trailing end of the run.
    private var viewportOffset: Double {
        guard axis == .horizontal, isRightToLeft else { return physicalOffset }

        return extents.totalExtent - physicalOffset - viewportLength
    }

    private var isRightToLeft: Bool {
        content.environment.layoutDirection == .rightToLeft
    }

    private func materialize() {
        guard !isDisposed else { return }

        let rows = VirtualizationWindow.compute(
            extents: extents,
            viewportOffset: viewportOffset,
            viewportLength: viewportLength,
            direction: direction,
            ranges: ranges,
            maximumDisplayCount: columns == 1
                ? maximumMaterializedCount : max(1, maximumMaterializedCount / columns)
        )
        window = columns == 1 ? rows : items(of: rows)
        let selection = selectTargets()
        let targetIDs = Set(selection.targets.map { snapshot.items[$0].id })
        var disposed = 0
        for id in order where !targetIDs.contains(id) {
            live.removeValue(forKey: id)?.node.dispose()
            disposed += 1
        }

        var made = 0
        var updated = 0
        var replaced = 0
        var newOrder: [ItemID] = []
        newOrder.reserveCapacity(selection.targets.count)
        for position in selection.targets {
            let item = snapshot.items[position]
            var node: Provider.Content
            if let entry = live[item.id] {
                node = entry.node
                if entry.item != item.value {
                    if provider.canUpdate(entry.node, to: item.value) {
                        provider.update(entry.node, with: item.value, id: item.id)
                        updated += 1
                    } else {
                        entry.node.dispose()
                        node = provider.makeNode(for: item.value, id: item.id)
                        replaced += 1
                    }
                    live[item.id] = LiveItem(node: node, item: item.value)
                }
            } else {
                node = provider.makeNode(for: item.value, id: item.id)
                live[item.id] = LiveItem(node: node, item: item.value)
                made += 1
            }
            place(node, at: itemOffset(at: position), column: position % columns)
            attach(node, at: newOrder.count)
            newOrder.append(item.id)
        }
        order = newOrder
        if selection.deferred > 0 {
            budget?.deferWork(for: self)
        }

        guard made + updated + replaced + disposed + selection.deferred > 0 else { return }

        log(
            .schedule,
            "materialize",
            "dataRevision=\(snapshot.revision) visible=\(window.visible) "
                + "display=\(window.display) made=\(made) updated=\(updated) "
                + "replaced=\(replaced) disposed=\(disposed) deferred=\(selection.deferred) "
                + "live=\(order.count)"
        )
    }

    /// Chooses which display positions get live nodes. Visible items always do. Margin items
    /// follow in preference order (leading side first, nearest first); with a budget they need
    /// a live slot, and a new node additionally needs a creation token — a margin item that
    /// only lacks a token is deferred to the next pass.
    private func selectTargets() -> (targets: [Int], deferred: Int) {
        let visible = window.visible.clamped(to: window.display)
        requiredCount = visible.count
        let leading =
            direction == .forward
            ? Array(visible.upperBound..<window.display.upperBound)
            : Array((window.display.lowerBound..<visible.lowerBound).reversed())
        let trailing =
            direction == .forward
            ? Array((window.display.lowerBound..<visible.lowerBound).reversed())
            : Array(visible.upperBound..<window.display.upperBound)
        guard let budget else {
            return (Array(window.display), 0)
        }

        let missingVisible = visible.filter { live[snapshot.items[$0].id] == nil }.count
        budget.chargeRequired(missingVisible)
        var slots = max(0, budget.liveAllowance(for: self) - visible.count)
        var chosen = Array(visible)
        var deferred = 0
        for position in leading + trailing {
            guard slots > 0 else { break }

            if live[snapshot.items[position].id] != nil || budget.takeCreations(1) == 1 {
                chosen.append(position)
                slots -= 1
            } else {
                deferred += 1
            }
        }
        return (chosen.sorted(), deferred)
    }

    private func log(_ area: LogArea, _ event: String, _ details: @autoclosure () -> String) {
        if let diagnosticSink {
            logIfEnabled(
                area,
                in: Set(LogArea.allCases),
                line: {
                    formatLogLine(
                        area: area,
                        event: event,
                        host: correlation.host,
                        generation: correlation.generation,
                        node: content.id,
                        parent: nil,
                        details: details()
                    )
                },
                output: diagnosticSink
            )
        } else {
            Log.on(
                area,
                event,
                host: correlation.host,
                generation: correlation.generation,
                node: content.id,
                details()
            )
        }
    }

    private func attach(_ node: Node, at index: Int) {
        let children = content.subnodes
        if index < children.count, children[index] === node { return }

        if let current = children.firstIndex(where: { $0 === node }) {
            content.moveSubnode(from: current, to: index)
        } else {
            content.insertSubnode(node, at: min(index, children.count))
        }
    }

    /// Converts a window over rows into the items those rows hold.
    private func items(of rows: VirtualizationWindow) -> VirtualizationWindow {
        func span(_ range: Range<Int>) -> Range<Int> {
            let lower = min(range.lowerBound * columns, snapshot.count)
            return lower..<min(range.upperBound * columns, snapshot.count)
        }
        return VirtualizationWindow(
            visible: span(rows.visible),
            display: span(rows.display),
            preload: span(rows.preload)
        )
    }

    private func place(_ node: Node, at offset: Double, column: Int) {
        var style = node.style
        style.positionType = .absolute
        // A list's cross axis follows the content (and so the viewport) from the first layout
        // pass; grid cells take their computed width and column position.
        if axis == .horizontal {
            style.offsets = DirectionalEdgeOffsets(top: 0, leading: offset)
            style.height = .fraction(1)
        } else if columns == 1 {
            style.offsets = DirectionalEdgeOffsets(top: offset, leading: 0)
            style.width = .fraction(1)
        } else {
            let gap = GridLayout.clean(grid?.columnSpacing ?? 0)
            style.offsets = DirectionalEdgeOffsets(
                top: offset,
                leading: Double(column) * (cellWidth + gap)
            )
            style.width = .points(cellWidth)
        }
        if let fixed = currentMetrics().fixedLength, axis == .vertical {
            style.height = .points(fixed)
        }
        if style != node.style {
            node.style = style
        }
    }

    private func setContentExtent(_ extent: Double) {
        var style = content.style
        if axis == .horizontal {
            style.width = .points(extent)
            style.height = .fraction(1)
        } else {
            style.height = .points(extent)
            style.width = .fraction(1)
        }
        if style != content.style {
            content.style = style
        }
    }

    private func disposeLiveItems() {
        for id in order {
            live.removeValue(forKey: id)?.node.dispose()
        }
        live.removeAll()
        order = []
    }
}

extension MaterializationWindow {
    /// Evaluates next-page demand for the current snapshot and viewport and logs every
    /// decision except `.notNeeded` (P6.12: transitions, not offset ticks).
    ///
    /// Ownership: mutates `gate`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func evaluatePagination(_ gate: inout PaginationGate) -> PaginationDecision {
        let decision = gate.evaluate(
            snapshot: snapshot,
            extents: extents,
            visible: window.visible,
            viewportOffset: viewportOffset,
            viewportLength: viewportLength
        )
        if decision != .notNeeded {
            log(
                .schedule,
                "pagination-demand",
                "decision=\(decision) dataKey=\(snapshot.dataKey) dataRevision=\(snapshot.revision)"
            )
        }
        return decision
    }
}

extension MaterializationWindow: MaterializationBudgetClient {
    var budgetPriority: MaterializationPriority { priority }
    var budgetLiveCount: Int { order.count }
    var budgetRequiredCount: Int { requiredCount }

    func budgetDidRefill() {
        materialize()
    }
}

/// Diagnostic correlation of a collection window (P6.12): the owning host and its render
/// generation, both `nil` before mount.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionCorrelation: Sendable, Hashable {
    /// Owning host, or `nil` before mount.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var host: UInt64?

    /// Render generation last committed by that host, or `nil` when unknown.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var generation: UInt64?

    /// Creates a correlation.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(host: UInt64? = nil, generation: UInt64? = nil) {
        self.host = host
        self.generation = generation
    }
}
