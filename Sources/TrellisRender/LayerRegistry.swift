import QuartzCore
import TrellisCore

/// Mapping of tree nodes to native layers owned by a single host.
///
/// The registry is the sole place where `NodeID` is paired with `CALayer`. It owns
/// only the mapping entries: detaching a layer from its superlayer is performed by
/// the caller, because the caller controls the order of detachment relative to the transaction.
///
/// The registry stores only layers created by Trellis. External sublayers of the host view
/// are not tracked and cannot be removed through it.
///
/// Ownership: the registry retains layers strongly until removed. Isolation: MainActor —
/// `CALayer` is a native object. Errors: none; missing entries return `nil`.
/// Cancellation: not applicable.
@MainActor
public final class LayerRegistry {
    private var layers: [NodeID: CALayer] = [:]

    /// Creates an empty registry.
    ///
    /// Ownership: the caller owns the registry. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Number of entries.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var count: Int { layers.count }

    /// Identities for which a layer exists.
    ///
    /// Ownership: returns a copy of the set. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var identities: Set<NodeID> { Set(layers.keys) }

    /// Returns the node's layer if one has been created.
    ///
    /// Ownership: the layer remains owned by the registry. Isolation: MainActor.
    /// Errors: none; unknown identities return `nil`. Cancellation: not applicable.
    public func layer(for identity: NodeID) -> CALayer? { layers[identity] }

    /// Associates a layer with a node, replacing any previous entry.
    ///
    /// The previous layer is returned to the caller: the registry does not remove it
    /// from the superlayer itself, so that detachment happens within the same transaction
    /// as the remaining geometry.
    ///
    /// Ownership: the registry accepts the new layer and hands the previous one to the caller.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func set(_ layer: CALayer, for identity: NodeID) -> CALayer? {
        let previous = layers[identity]
        layers[identity] = layer
        return previous
    }

    /// Removes an entry and returns the detached layer.
    ///
    /// Ownership: the layer is handed to the caller. Isolation: MainActor.
    /// Errors: none; unknown identities return `nil`. Cancellation: not applicable.
    @discardableResult
    public func remove(_ identity: NodeID) -> CALayer? { layers.removeValue(forKey: identity) }

    /// Removes all entries and returns the detached layers.
    ///
    /// Ownership: layers are handed to the caller. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func removeAll() -> [CALayer] {
        let removed = Array(layers.values)
        layers.removeAll()
        return removed
    }
}
