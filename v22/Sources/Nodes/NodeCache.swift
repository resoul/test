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
/// that last asked for it — by then it is no longer on screen.
///
/// Ownership: the cache owns its nodes until it releases them. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public final class NodeCache<Key: Hashable, Item: Node> {
    private let make: @MainActor (Key) -> Item
    private var items: [Key: Item] = [:]
    private var used: Set<Key> = []
    private var generation: UInt64?

    /// A cache that makes a node for a new identity with `make`.
    ///
    /// Ownership: keeps `make`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ make: @escaping @MainActor (Key) -> Item) {
        self.make = make
    }

    /// The node for `key`: the one made before, or a new one.
    ///
    /// Ownership: the cache keeps the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public subscript(key: Key) -> Item {
        releaseUnusedIfANewPassBegan()
        used.insert(key)
        if let item = items[key] { return item }

        let item = make(key)
        items[key] = item
        return item
    }

    /// Number of nodes the cache keeps.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var count: Int { items.count }

    /// The first request in a new layout pass releases what the previous pass that used the
    /// cache did not ask for.
    private func releaseUnusedIfANewPassBegan() {
        let current = NodeHost.passGeneration
        guard generation != current else { return }

        if generation != nil {
            for key in items.keys where !used.contains(key) {
                items[key] = nil
            }
        }
        used = []
        generation = current
    }
}
