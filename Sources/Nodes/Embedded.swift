import LayoutCore

/// A node that shows a view of the platform in its frame — a text field, and later a map or
/// a video. The tree lays it out and moves it with the scrolls around it; the adapter puts
/// the platform's view over the tree's drawing at the node's frame, cut to what the nodes
/// around it show. The view takes its own touches and keys; the node draws nothing.
///
/// A subclass says what view it is (`TextField`); each adapter makes that view.
///
/// Ownership: the tree keeps the node; the adapter keeps the view while the node is in the
/// tree. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
open class EmbeddedNode: Node {
    /// The size the node lays out at, unless its layout says otherwise: the adapter sets it to
    /// the view's own size when it makes the view, and after.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var preferredSize = LayoutSize(width: 200, height: 44) {
        didSet {
            if preferredSize != oldValue { setNeedsLayout() }
        }
    }

    /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public override init() {
        super.init()
        // In the reading order where it is: the adapter gives its view's accessibility there.
        accessibility.isElement = true
    }

    /// The preferred size.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open override var layoutContent: LeafContent? { .size(preferredSize) }
}

/// Where an embedded node shows, for the adapter to put its view there.
///
/// Ownership: value referring to a node of the tree. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public struct EmbeddedItem {
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public let node: EmbeddedNode

    /// The node's frame in the root's coordinates, where the scrolls around it have it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect

    /// The part of the frame the nodes around it show — their clipping cuts the rest; `nil`
    /// when none of it shows.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let shownFrame: LayoutRect?
}

extension NodeHost {
    /// The embedded nodes of the tree that are not hidden, in the tree's order, framed in the
    /// root's coordinates — for the adapter to put their views over the drawing after it.
    ///
    /// Ownership: returns values referring to nodes of the tree. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func embeddedItems() -> [EmbeddedItem] {
        var items: [EmbeddedItem] = []
        root.walkVisible(from: .identity) { node, _ in
            if let embedded = node as? EmbeddedNode {
                items.append(
                    EmbeddedItem(
                        node: embedded,
                        frame: frameInRoot(of: embedded),
                        shownFrame: shownFrame(of: embedded)
                    )
                )
            }
            return true
        }
        return items
    }
}

extension Node {
    /// How far the platform's keyboard comes up over the bottom of the tree
    /// (`NodeHost.keyboardInset`); 0 out of a tree. Reading it in `layoutSpec()` lays the
    /// node out again as the keyboard moves.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var keyboardInset: Double {
        host?.keyboardInset ?? 0
    }
}
