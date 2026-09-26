import Foundation

/// Why a measured item length could not be reused — logged as `measure miss reason=…` (P6.9,
/// P6.12).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum MeasurementInvalidation: String, Sendable, Hashable {
    /// The item was never measured.
    case absent
    /// The item's model changed.
    case content
    /// The cross-axis extent (for example the list width) changed.
    case crossExtent = "cross-extent"
    /// The environment's `layoutRevision` changed. Paint-only keys such as `ThemeKey` do not
    /// advance it; every key that does not declare `affectsLayout == false` does (P6.9).
    case environment
}

/// Measured main-axis lengths of items, valid only for the exact model, cross extent and
/// environment revision they were measured with (R10, P6.9). Entries of IDs that leave the
/// snapshot are pruned, so the cache is bounded by the data set, never by history.
///
/// Ownership: a value owned by its container; stores copies of models. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public struct ItemMeasurementCache<ItemID: Hashable & Sendable, Item: Sendable & Equatable>:
    Sendable
{
    private struct Entry: Sendable {
        let item: Item
        let crossExtent: Double
        let environmentRevision: UInt64
        let length: Double
    }

    private var entries: [ItemID: Entry] = [:]

    /// Creates an empty cache.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init() {}

    /// Number of stored lengths.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var count: Int { entries.count }

    /// Looks up a length measured for exactly this model, cross extent and environment.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none — a mismatch is a `.failure`
    /// naming its reason. Cancellation: not applicable.
    public func length(
        for id: ItemID,
        item: Item,
        crossExtent: Double,
        environmentRevision: UInt64
    ) -> Result<Double, MeasurementMiss> {
        guard let entry = entries[id] else { return .failure(MeasurementMiss(reason: .absent)) }
        guard entry.item == item else { return .failure(MeasurementMiss(reason: .content)) }
        guard entry.crossExtent == crossExtent else {
            return .failure(MeasurementMiss(reason: .crossExtent))
        }
        guard entry.environmentRevision == environmentRevision else {
            return .failure(MeasurementMiss(reason: .environment))
        }

        return .success(entry.length)
    }

    /// Stores a measured length, replacing any previous entry for `id`.
    ///
    /// Ownership: copies `item`. Isolation: none. Errors: none — a non-finite or negative
    /// length is ignored. Cancellation: not applicable.
    public mutating func record(
        _ length: Double,
        for id: ItemID,
        item: Item,
        crossExtent: Double,
        environmentRevision: UInt64
    ) {
        guard length.isFinite, length >= 0 else { return }

        entries[id] = Entry(
            item: item,
            crossExtent: crossExtent,
            environmentRevision: environmentRevision,
            length: length
        )
    }

    /// Drops entries whose IDs `snapshot` no longer contains.
    ///
    /// Ownership: mutates this cache. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func prune(keeping snapshot: CollectionSnapshot<ItemID, Item>) {
        entries = entries.filter { snapshot.contains($0.key) }
    }
}

/// A measurement cache miss and its reason.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct MeasurementMiss: Error, Sendable, Hashable {
    /// Why the stored length could not be reused.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let reason: MeasurementInvalidation

    /// Creates a miss.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(reason: MeasurementInvalidation) {
        self.reason = reason
    }
}
