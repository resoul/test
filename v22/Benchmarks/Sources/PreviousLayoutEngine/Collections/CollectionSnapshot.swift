import Foundation

/// One element of a collection: a stable identity plus the Sendable model shown for it (R10,
/// ADR 0030). The identity survives reorders and content changes; the model's equality is the
/// item's content revision — an unchanged model never re-runs `ItemProvider.update`.
///
/// Ownership: a value; owns `value`. Isolation: none. Errors: none. Cancellation: not
/// applicable.
public struct CollectionItem<ItemID: Hashable & Sendable, Item: Sendable & Equatable>: Sendable,
    Equatable
{
    /// Stable identity of this item. Events leave the collection with this value, never with
    /// an index.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: ItemID

    /// The model shown for this item.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let value: Item

    /// Creates an item.
    ///
    /// Ownership: takes ownership of `value`. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(id: ItemID, value: Item) {
        self.id = id
        self.value = value
    }
}

/// A named run of items inside a snapshot. Supplementary content such as a section header is
/// composed by the container, not stored here.
///
/// Ownership: a value; owns its items. Isolation: none. Errors: none. Cancellation: not
/// applicable.
public struct CollectionSection<ItemID: Hashable & Sendable, Item: Sendable & Equatable>: Sendable,
    Equatable
{
    /// Stable identity of the section inside its snapshot.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: String

    /// Items of this section, in display order, after duplicate removal.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let items: [CollectionItem<ItemID, Item>]

    /// Creates a section.
    ///
    /// Ownership: takes ownership of `items`. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(id: String, items: [CollectionItem<ItemID, Item>]) {
        self.id = id
        self.items = items
    }
}

/// A reported loading failure. Only a diagnostic message crosses the data boundary; the
/// underlying error stays with the model that produced it.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionLoadError: Sendable, Hashable {
    /// A message suitable for an error row or log line — never a raw URL or payload.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let message: String

    /// Creates an error description.
    ///
    /// Ownership: takes ownership of `message`. Isolation: none. Errors: none. Cancellation:
    /// not applicable.
    public init(message: String) {
        self.message = message
    }
}

/// The loading status that travels with a snapshot (P6.7): the initial phase plus the
/// independent refresh and next-page flags. "Empty" is not a separate case — it is a
/// `.loaded` phase with zero items.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CollectionLoadState: Sendable, Hashable {
    /// Phase of the initial request for the snapshot's data key.
    ///
    /// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Phase: Sendable, Hashable {
        /// Nothing requested yet.
        case initial
        /// The initial request is in flight.
        case loading
        /// The initial request completed; items (possibly none) are available.
        case loaded
        /// The initial request failed; retry repeats the initial request.
        case failed(CollectionLoadError)
    }

    /// Initial-request phase.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var phase: Phase

    /// A refresh is in flight while the current items stay visible.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isRefreshing: Bool

    /// A next-page request is in flight.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isLoadingMore: Bool

    /// The last next-page request failed; retry repeats that page, not the initial load.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var pageError: CollectionLoadError?

    /// The data source has no further pages; pagination demand stops.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var endReached: Bool

    /// Creates a load state; the default is "nothing requested yet".
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        phase: Phase = .initial,
        isRefreshing: Bool = false,
        isLoadingMore: Bool = false,
        pageError: CollectionLoadError? = nil,
        endReached: Bool = false
    ) {
        self.phase = phase
        self.isRefreshing = isRefreshing
        self.isLoadingMore = isLoadingMore
        self.pageError = pageError
        self.endReached = endReached
    }
}

/// One accepted, immutable state of a collection's data (R10, ADR 0030, P6.4/P6.11): the data
/// key and revision, sections with stable item IDs, and the load state. Counts and order are
/// derived only from this value — a container never asks a data source for "number of rows".
///
/// Duplicate item IDs are resolved first-wins across the whole snapshot (ADR 0030): the first
/// occurrence stays, later ones are dropped and counted in `droppedDuplicateCount` so the
/// container can report them through `Log`. An index is meaningful only inside the snapshot
/// that produced it.
///
/// Ownership: a value; owns its sections. Isolation: none — built and compared on any
/// executor. Errors: none; duplicates are resolved, not rejected. Cancellation: not applicable.
public struct CollectionSnapshot<ItemID: Hashable & Sendable, Item: Sendable & Equatable>: Sendable,
    Equatable
{
    /// Identifies the data set (for example a peer or filter). A new key starts a new data
    /// generation: pending results of the previous key are not applied to it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let dataKey: String

    /// Monotonic revision of this data set inside its key, assigned by the producer.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let revision: UInt64

    /// Sections in display order, with duplicates already removed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let sections: [CollectionSection<ItemID, Item>]

    /// Load status that accompanies these items.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let loadState: CollectionLoadState

    /// Number of items dropped because an earlier item already used the same ID.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let droppedDuplicateCount: Int

    /// All items in display order across sections.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let items: [CollectionItem<ItemID, Item>]

    private let positions: [ItemID: Int]

    /// Creates a snapshot, removing duplicate item IDs first-wins.
    ///
    /// Ownership: takes ownership of `sections`. Isolation: none. Errors: none — duplicates are
    /// dropped and counted. Cancellation: not applicable.
    public init(
        dataKey: String,
        revision: UInt64,
        sections: [CollectionSection<ItemID, Item>],
        loadState: CollectionLoadState = CollectionLoadState(phase: .loaded)
    ) {
        var seen: [ItemID: Int] = [:]
        var flat: [CollectionItem<ItemID, Item>] = []
        var dropped = 0
        var resolvedSections: [CollectionSection<ItemID, Item>] = []
        resolvedSections.reserveCapacity(sections.count)
        for section in sections {
            var kept: [CollectionItem<ItemID, Item>] = []
            kept.reserveCapacity(section.items.count)
            for item in section.items {
                guard seen[item.id] == nil else {
                    dropped += 1
                    continue
                }
                seen[item.id] = flat.count
                flat.append(item)
                kept.append(item)
            }
            resolvedSections.append(CollectionSection(id: section.id, items: kept))
        }
        self.dataKey = dataKey
        self.revision = revision
        self.sections = resolvedSections
        self.loadState = loadState
        self.droppedDuplicateCount = dropped
        self.items = flat
        self.positions = seen
    }

    /// Creates a single-section snapshot — the common shape of a plain list.
    ///
    /// Ownership: takes ownership of `items`. Isolation: none. Errors: none — duplicates are
    /// dropped and counted. Cancellation: not applicable.
    public init(
        dataKey: String,
        revision: UInt64,
        items: [CollectionItem<ItemID, Item>],
        loadState: CollectionLoadState = CollectionLoadState(phase: .loaded)
    ) {
        self.init(
            dataKey: dataKey,
            revision: revision,
            sections: [CollectionSection(id: "", items: items)],
            loadState: loadState
        )
    }

    /// An empty snapshot in the `.initial` load phase.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func initial(dataKey: String) -> Self {
        Self(dataKey: dataKey, revision: 0, sections: [], loadState: CollectionLoadState())
    }

    /// Number of items across sections.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var count: Int { items.count }

    /// Display index of `id` inside this snapshot, or `nil` when the ID is not part of it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func index(of id: ItemID) -> Int? {
        positions[id]
    }

    /// Whether this snapshot contains `id`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func contains(_ id: ItemID) -> Bool {
        positions[id] != nil
    }

    /// Snapshots are equal when key, revision, load state and sections match; the derived
    /// lookup table is not compared.
    ///
    /// Ownership: none. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dataKey == rhs.dataKey && lhs.revision == rhs.revision
            && lhs.loadState == rhs.loadState && lhs.sections == rhs.sections
    }
}
