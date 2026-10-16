/// Nodes for a list of models, one per model identity: the same identity gets the same node
/// in every layout, so a node keeps its state and its place in the tree across reorders.
///
///     private let rows = NodeCache<Item.ID, ItemRow> { _ in ItemRow() }
///
///     override func layoutSpec() -> LayoutSpec? {
///         FlexContainer(.column) {
///             for item in items.value { rows[item.id].showing(item) }
///         }
///     }
///
/// A node the layout stops asking for is released at the next layout pass after the one
/// that last asked for it — by then it is no longer on screen. With a `reserve`, the last
/// released nodes wait there instead, and one asked for again comes back rather than being
/// made anew — a list scrolled back and forth near its edge makes fewer nodes. A node in
/// the reserve is out of the tree, as a released one is: what it does while shown (loads,
/// timers, following the screen) ends when it leaves. Keep the state a reader must find
/// again in the model: a node may leave the reserve at any time.
///
/// Ownership: the cache owns its nodes until it releases them. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public final class NodeCache<Key: Hashable, Item: Node> {
    private let make: @MainActor (Key) -> Item
    private var items: [Key: Item] = [:]
    private var used: Set<Key> = []
    private var generation: UInt64?
    /// Released nodes kept for their keys, and the keys from the longest released on.
    private var reserved: [Key: Item] = [:]
    private var reserveOrder: [Key] = []

    /// A cache that makes a node for a new identity with `make`, and keeps up to `reserve`
    /// of the nodes it released.
    ///
    /// Ownership: keeps `make`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(reserve: Int = 0, _ make: @escaping @MainActor (Key) -> Item) {
        self.reserve = max(reserve, 0)
        self.make = make
    }

    /// At most this many released nodes wait in the reserve; the ones released longest ago
    /// go first. The nodes the layout asks for do not count. `0` releases them at once.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var reserve: Int {
        didSet {
            reserve = max(reserve, 0)
            trimReserve()
        }
    }

    /// Number of released nodes waiting in the reserve.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var reservedCount: Int { reserved.count }

    /// Lets go of every node in the reserve.
    ///
    /// Ownership: releases the nodes. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func clearReserve() {
        reserved = [:]
        reserveOrder = []
    }

    /// The node for `key`: the one made before, or a new one.
    ///
    /// Ownership: the cache keeps the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public subscript(key: Key) -> Item {
        releaseUnusedIfANewPassBegan()
        used.insert(key)
        if let item = items[key] { return item }
        if let item = reserved.removeValue(forKey: key) {
            reserveOrder.removeAll { $0 == key }
            items[key] = item
            return item
        }

        let item = make(key)
        items[key] = item
        return item
    }

    /// Number of nodes the cache keeps for the layout, not counting the reserve.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var count: Int { items.count }

    /// The first request in a new layout pass releases what the previous pass that used the
    /// cache did not ask for.
    private func releaseUnusedIfANewPassBegan() {
        let current = NodeHost.passGeneration
        guard generation != current else { return }

        if generation != nil {
            for (key, item) in items where !used.contains(key) {
                items[key] = nil
                if reserve > 0 {
                    reserved[key] = item
                    reserveOrder.append(key)
                }
            }
            trimReserve()
        }
        used = []
        generation = current
    }

    private func trimReserve() {
        let excess = reserveOrder.count - reserve
        guard excess > 0 else { return }

        for key in reserveOrder.prefix(excess) {
            reserved[key] = nil
        }
        reserveOrder.removeFirst(excess)
    }
}
