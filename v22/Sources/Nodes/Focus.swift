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

    /// The node's corner radius, for a ring around it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let cornerRadius: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(node: NodeID, frame: LayoutRect, cornerRadius: Double = 0) {
        self.node = node
        self.frame = frame
        self.cornerRadius = cornerRadius
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

/// How a focused node shows it has the focus.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FocusLook: Sendable, Hashable {
    /// The node itself gets bigger and casts a shadow, as on a TV.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case lift
    /// The adapter draws the system's focus ring around the node, as with a keyboard on
    /// iPad and Mac.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case ring
}

/// Where `NodeHost.moveFocus` moves the focus.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FocusMove: Sendable, Hashable {
    /// The next focusable node in reading order (Tab).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case next
    /// The previous one (Shift-Tab).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case previous
    /// The nearest focusable node above (an arrow key).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case up
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case down
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case left
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case right
}
