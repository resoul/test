import Foundation

/// One ID-based change of a `CollectionDelta`. Positions are expressed by neighbouring IDs,
/// never by indices, so a change cannot land on a different item after reordering.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionChange<ItemID: Hashable & Sendable, Item: Sendable & Equatable>: Sendable,
    Equatable
{
    /// Inserts `item` into `section` after `after`, or at the section start when `after` is
    /// `nil`. An ID that already exists is dropped (first-wins).
    case insert(CollectionItem<ItemID, Item>, after: ItemID?, section: String)
    /// Removes the item with this ID.
    case delete(ItemID)
    /// Moves an item after `after` (or to the start) of `section`.
    case move(ItemID, after: ItemID?, section: String)
    /// Replaces the model of an existing item.
    case update(CollectionItem<ItemID, Item>)
}

/// Why a delta was not applied.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionDeltaRejection: Error, Sendable, Hashable {
    /// The delta was built on another data key.
    case dataKey
    /// The delta's base revision is not the snapshot's revision; recompute from the last
    /// committed snapshot instead of applying it (ADR 0030).
    case staleBase(expected: UInt64, actual: UInt64)
}

/// An ID-based update for a model that keeps its own snapshot (P6.4, ADR 0030). It applies only
/// to the exact base revision; there is no index-based variant and no way to skip an
/// intermediate delta.
///
/// Ownership: a value. Isolation: none. Errors: `apply(to:)` rejects a mismatched base.
/// Cancellation: not applicable.
public struct CollectionDelta<ItemID: Hashable & Sendable, Item: Sendable & Equatable>: Sendable,
    Equatable
{
    /// Data key the delta belongs to.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let dataKey: String

    /// Revision the delta was built on.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let baseRevision: UInt64

    /// Revision of the snapshot the delta produces.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let revision: UInt64

    /// Changes in application order.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let changes: [CollectionChange<ItemID, Item>]

    /// New load state, or `nil` to keep the base one.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let loadState: CollectionLoadState?

    /// Creates a delta.
    ///
    /// Ownership: takes ownership of `changes`. Isolation: none. Errors: none. Cancellation:
    /// not applicable.
    public init(
        dataKey: String,
        baseRevision: UInt64,
        revision: UInt64,
        changes: [CollectionChange<ItemID, Item>],
        loadState: CollectionLoadState? = nil
    ) {
        self.dataKey = dataKey
        self.baseRevision = baseRevision
        self.revision = revision
        self.changes = changes
        self.loadState = loadState
    }

    /// Applies the changes to `base`. Changes that name a missing ID are skipped; a missing
    /// section is appended.
    ///
    /// Ownership: returns a new snapshot. Isolation: none. Errors: `CollectionDeltaRejection`
    /// when the data key or base revision does not match. Cancellation: not applicable.
    public func apply(
        to base: CollectionSnapshot<ItemID, Item>
    ) throws(CollectionDeltaRejection) -> CollectionSnapshot<ItemID, Item> {
        guard base.dataKey == dataKey else { throw .dataKey }
        guard base.revision == baseRevision else {
            throw .staleBase(expected: baseRevision, actual: base.revision)
        }

        var sections = base.sections.map { (id: $0.id, items: $0.items) }
        func locate(_ id: ItemID) -> (section: Int, index: Int)? {
            for (sectionIndex, section) in sections.enumerated() {
                if let index = section.items.firstIndex(where: { $0.id == id }) {
                    return (sectionIndex, index)
                }
            }
            return nil
        }
        func sectionIndex(_ id: String) -> Int {
            if let index = sections.firstIndex(where: { $0.id == id }) { return index }

            sections.append((id: id, items: []))
            return sections.count - 1
        }
        func insert(_ item: CollectionItem<ItemID, Item>, after: ItemID?, section: String) {
            let target = sectionIndex(section)
            var position = 0
            if let after, let index = sections[target].items.firstIndex(where: { $0.id == after }) {
                position = index + 1
            }
            sections[target].items.insert(item, at: position)
        }

        for change in changes {
            switch change {
            case .insert(let item, let after, let section):
                guard locate(item.id) == nil else { continue }

                insert(item, after: after, section: section)
            case .delete(let id):
                guard let found = locate(id) else { continue }

                sections[found.section].items.remove(at: found.index)
            case .move(let id, let after, let section):
                guard id != after, let found = locate(id) else { continue }

                let item = sections[found.section].items.remove(at: found.index)
                insert(item, after: after, section: section)
            case .update(let item):
                guard let found = locate(item.id) else { continue }

                sections[found.section].items[found.index] = item
            }
        }
        return CollectionSnapshot(
            dataKey: dataKey,
            revision: revision,
            sections: sections.map { CollectionSection(id: $0.id, items: $0.items) },
            loadState: loadState ?? base.loadState
        )
    }
}

/// ID-level difference between two snapshots, computed off the MainActor (R11). `moved`
/// counts surviving items outside the longest run that kept its relative order.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionDiff: Sendable, Hashable {
    /// Items present only in the new snapshot.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let inserted: Int

    /// Items present only in the old snapshot.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let removed: Int

    /// Surviving items whose model changed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let updated: Int

    /// Surviving items that changed relative order.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let moved: Int

    /// Creates a diff summary.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(inserted: Int, removed: Int, updated: Int, moved: Int) {
        self.inserted = inserted
        self.removed = removed
        self.updated = updated
        self.moved = moved
    }
}

/// Everything a worker needs to prepare a snapshot for commit: values only, no nodes (R11).
///
/// Ownership: a value. Isolation: none — it crosses to a worker. Errors: none. Cancellation:
/// not applicable.
public struct CollectionPreparationInput<ItemID: Hashable & Sendable, Item: Sendable & Equatable>:
    Sendable
{
    let base: CollectionSnapshot<ItemID, Item>
    let target: CollectionSnapshot<ItemID, Item>
    let cache: ItemMeasurementCache<ItemID, Item>
    let key: PreparationKey
}

/// Conditions a prepared result was computed under; a commit accepts it only if all still hold.
struct PreparationKey: Sendable, Hashable {
    let commitGeneration: UInt64
    let cacheVersion: UInt64
    let metrics: CollectionMetrics
}

/// The worker's result: the new snapshot with resolved item positions, pruned measurements and
/// a diff summary (R11). Committing it on the MainActor is O(window), not O(N).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PreparedCollection<ItemID: Hashable & Sendable, Item: Sendable & Equatable>: Sendable
{
    /// The snapshot this result commits.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let snapshot: CollectionSnapshot<ItemID, Item>

    /// Difference from the base snapshot.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let diff: CollectionDiff

    let geometry: CollectionGeometry
    let cache: ItemMeasurementCache<ItemID, Item>
    let key: PreparationKey
    let measurementHits: Int

    /// Prepares `input`: diff, length resolution and prefix sums. With `cancellable`, returns
    /// `nil` as soon as the current task is cancelled.
    ///
    /// Ownership: returns a new value. Isolation: none — runs on any executor. Errors: none.
    /// Cancellation: cooperative, checked every 512 items when `cancellable`.
    public static func prepare(
        _ input: CollectionPreparationInput<ItemID, Item>,
        cancellable: Bool = true
    ) -> PreparedCollection? {
        func cancelled(_ step: Int) -> Bool {
            cancellable && step % 512 == 0 && Task.isCancelled
        }

        let target = input.target
        var cache = input.cache
        cache.prune(keeping: target)
        guard
            let geometry = CollectionGeometry.resolve(
                items: target.items,
                cache: cache,
                metrics: input.key.metrics,
                isCancelled: cancelled
            )
        else { return nil }

        guard let diff = diff(from: input.base, to: target, cancellable: cancellable) else {
            return nil
        }

        return PreparedCollection(
            snapshot: target,
            diff: diff,
            geometry: geometry,
            cache: cache,
            key: input.key,
            measurementHits: geometry.hits
        )
    }

    private static func diff(
        from base: CollectionSnapshot<ItemID, Item>,
        to target: CollectionSnapshot<ItemID, Item>,
        cancellable: Bool
    ) -> CollectionDiff? {
        guard base.dataKey == target.dataKey else {
            return CollectionDiff(inserted: target.count, removed: base.count, updated: 0, moved: 0)
        }

        var removed = 0
        var updated = 0
        var survivorPositions: [Int] = []
        survivorPositions.reserveCapacity(min(base.count, target.count))
        for (step, item) in base.items.enumerated() {
            if cancellable, step % 512 == 0, Task.isCancelled { return nil }

            guard let index = target.index(of: item.id) else {
                removed += 1
                continue
            }

            survivorPositions.append(index)
            if target.items[index].value != item.value {
                updated += 1
            }
        }
        let kept = longestIncreasingRun(survivorPositions)
        return CollectionDiff(
            inserted: target.count - survivorPositions.count,
            removed: removed,
            updated: updated,
            moved: survivorPositions.count - kept
        )
    }

    /// Length of the longest strictly increasing subsequence, O(n log n).
    private static func longestIncreasingRun(_ values: [Int]) -> Int {
        var tails: [Int] = []
        for value in values {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if tails[middle] < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low == tails.count {
                tails.append(value)
            } else {
                tails[low] = value
            }
        }
        return tails.count
    }
}

/// How the reading position was kept across a commit or a measurement correction (P6.4).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionAnchorOutcome<ItemID: Hashable & Sendable>: Sendable, Hashable {
    /// Nothing was visible, or the data key changed; the offset was reset or clamped.
    case none
    /// The anchor item kept its viewport position.
    case preserved(ItemID)
    /// The anchor was removed; its nearest surviving neighbour in the old order kept its
    /// viewport position.
    case neighbour(ItemID)
    /// Follow-bottom kept the viewport at the end.
    case followedBottom
}

/// The scroll adjustment a commit or measurement correction asks the container to apply to
/// its `ScrollNode` without animation (R11).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionAdjustment<ItemID: Hashable & Sendable>: Sendable, Hashable {
    /// How the reading position was kept.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let anchor: CollectionAnchorOutcome<ItemID>

    /// Physical scroll offset along the axis that keeps the anchor in place.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let offset: Double

    /// Whether the offset had to be clamped to the content range.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let clamped: Bool

    /// Whether `offset` differs from the offset before the change.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let offsetChanged: Bool

    /// `offset` minus the offset before the change — what a host adds to the native offset.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let delta: Double

    /// Creates an adjustment.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        anchor: CollectionAnchorOutcome<ItemID>,
        offset: Double,
        clamped: Bool,
        offsetChanged: Bool,
        delta: Double = 0
    ) {
        self.anchor = anchor
        self.offset = offset
        self.clamped = clamped
        self.offsetChanged = offsetChanged
        self.delta = delta
    }
}

/// Why a prepared result was not committed. The caller prepares again from the latest state.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CollectionCommitRejection: Error, Sendable, Hashable {
    /// Another commit happened after preparation started.
    case staleBase
    /// Measurements, cross extent, environment, estimate or spacing changed.
    case staleMetrics
    /// The window was disposed.
    case disposed
}
