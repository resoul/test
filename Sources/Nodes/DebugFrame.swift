import LayoutCore

/// One node that shows, with where it is, as the debug overlay draws it.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct DebugFrame: Sendable, Equatable {
    public var id: NodeID
    /// The node's Swift type, as written: `Text`, `Stack<Route>`.
    public var typeName: String
    /// The node's box in the coordinates of the host's root, as shown: moved by the scrolls
    /// around it and by sticky positions.
    public var frame: LayoutRect
    /// How many nodes are between this one and the root.
    public var depth: Int
    /// Whether the node can take focus, which is what makes it respond to a press.
    public var isInteractive: Bool

    public init(
        id: NodeID,
        typeName: String,
        frame: LayoutRect,
        depth: Int,
        isInteractive: Bool
    ) {
        self.id = id
        self.typeName = typeName
        self.frame = frame
        self.depth = depth
        self.isInteractive = isInteractive
    }
}

extension NodeHost {
    /// The nodes that show, in the order the tree is read (a node before the nodes inside it, the
    /// first of them first), each with its box in the root's coordinates.
    ///
    /// Hidden and fully transparent nodes, and all under them, are left out, as they are from
    /// hit testing and from accessibility. A node inside a scroll that is out of the scroll's
    /// window is still here: the frames are where layout and the scroll put them, not what is
    /// visible on screen.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func debugFrames() -> [DebugFrame] {
        var frames: [DebugFrame] = []
        var depths: [NodeID: Int] = [:]
        root.walkVisible(from: .identity) { node, placement in
            let depth = node.supernode.flatMap { depths[$0.id] }.map { $0 + 1 } ?? 0
            depths[node.id] = depth
            frames.append(
                DebugFrame(
                    id: node.id,
                    typeName: String(describing: type(of: node)),
                    frame: node.frame(in: placement),
                    depth: depth,
                    isInteractive: node.canBecomeFocused
                )
            )
            return true
        }
        return frames
    }
}
