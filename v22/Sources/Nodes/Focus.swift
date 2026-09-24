import LayoutCore

/// A node the remote can focus, as the host's tree shows it now.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct FocusItem: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let node: NodeID

    /// The node's frame in the root's coordinates.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(node: NodeID, frame: LayoutRect) {
        self.node = node
        self.frame = frame
    }
}

/// A node marked `isFocusSection`, as the host's tree shows it now.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct FocusSection: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let node: NodeID

    /// The node's frame in the root's coordinates.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect

    /// The focusable nodes inside, in reading order.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let items: [NodeID]

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(node: NodeID, frame: LayoutRect, items: [NodeID]) {
        self.node = node
        self.frame = frame
        self.items = items
    }
}
