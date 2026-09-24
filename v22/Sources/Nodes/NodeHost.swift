import LayoutCore
import StateCore

/// Lays out a tree of nodes in a given size. A platform adapter owns one per root: it sets
/// `size`, `scale` and `direction`, is told through `onNeedsLayout` when the tree must be laid
/// out again, and calls `layoutIfNeeded()` before it draws.
///
/// A layout pass first runs pending state updates (`update()` of nodes whose state changed),
/// then lays out the whole tree in one engine pass — nested nodes' layouts are part of it —
/// and finally mounts the nodes the layouts mention and unmounts those they no longer do.
///
/// Ownership: the host keeps the root, which keeps its mounted subnodes. Isolation:
/// MainActor; the pass runs synchronously. Errors: none. Cancellation: `detach()`.
@MainActor
public final class NodeHost {
    /// Ownership: owned by the host. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let root: Node

    /// The size the root is laid out in.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var size: LayoutSize {
        didSet { if size != oldValue { setNeedsLayout() } }
    }

    /// Pixels per point, for snapping frames to the pixel grid.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var scale: Double = 1 {
        didSet { if scale != oldValue { setNeedsLayout() } }
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var direction: LayoutDirection = .leftToRight {
        didSet { if direction != oldValue { setNeedsLayout() } }
    }

    /// The points of spacing steps (`.s1` … `.s9`) in the tree's layouts.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var spacing: SpacingScale = .standard {
        didSet { setNeedsLayout() }
    }

    /// Called once when the tree goes from laid out to needing a layout — the adapter
    /// schedules `layoutIfNeeded()` from it (`setNeedsLayout` of its view).
    ///
    /// Ownership: the host keeps the closure; it must not keep the host. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onNeedsLayout: (@MainActor () -> Void)?

    /// Called once when something visible changed without needing a layout (an
    /// `appearance`) — the adapter redraws from it.
    ///
    /// Ownership: the host keeps the closure; it must not keep the host. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onNeedsRender: (@MainActor () -> Void)?

    /// Whether the tree changed since the adapter last drew it: set by every layout and by
    /// `setNeedsRender()`, cleared by `didRender()`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var needsRender = true

    /// Whether the next `layoutIfNeeded()` lays the tree out.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var needsLayout = true

    /// Layout passes run so far — for tests and diagnostics.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var passes = 0

    private var mounted: [NodeID: Node] = [:]
    private var pressed: Node?

    /// A host for `root`, which must not be mounted anywhere else.
    ///
    /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation:
    /// `detach()`.
    public init(root: Node, size: LayoutSize) {
        self.root = root
        self.size = size
        root.hostOfRoot = self
    }

    /// Marks the tree as needing a layout.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func setNeedsLayout() {
        guard !needsLayout else { return }

        needsLayout = true
        onNeedsLayout?()
    }

    /// Marks the tree as needing to be drawn again.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func setNeedsRender() {
        guard !needsRender else { return }

        needsRender = true
        onNeedsRender?()
    }

    /// Tells the host the adapter has drawn the tree as it is now.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func didRender() {
        needsRender = false
    }

    /// The size the tree takes under the given space — for `sizeThatFits` and
    /// `intrinsicContentSize`.
    ///
    /// Ownership: returns a value. Isolation: MainActor; synchronous. Errors: none.
    /// Cancellation: not applicable.
    public func fittingSize(
        width: AvailableSpace,
        height: AvailableSpace = .maxContent
    ) -> LayoutSize {
        StateUpdates.flush()
        return root.asLayoutSpec.measure(
            width: width,
            height: height,
            direction: direction,
            spacing: spacing
        )
    }

    /// Runs pending state updates, then lays the tree out if anything asked for it.
    ///
    /// Ownership: sets frames and subnodes of the tree. Isolation: MainActor; synchronous.
    /// Errors: none. Cancellation: not applicable.
    public func layoutIfNeeded() {
        StateUpdates.flush()
        guard needsLayout else { return }

        needsLayout = false
        needsRender = true
        passes += 1
        let placements = root.asLayoutSpec.apply(
            in: LayoutRect(origin: .zero, size: size),
            direction: direction,
            scale: scale,
            spacing: spacing
        )
        mount(placements)
    }

    // MARK: - Pointer

    /// A finger or the mouse went down at `point`, in the root's coordinates. Returns whether
    /// a node with `onTap` is under it — the node then shows itself pressed. When it returns
    /// `false`, the adapter passes the event on.
    ///
    /// Ownership: remembers the pressed node until the pointer goes up. Isolation:
    /// MainActor. Errors: none. Cancellation: `pointerCancelled()`.
    @discardableResult
    public func pointerDown(at point: LayoutPoint) -> Bool {
        pointerCancelled()
        var node = root.hitTest(point)
        while let current = node, current.onTap == nil {
            node = current.supernode
        }
        guard let target = node else { return false }

        pressed = target
        target.pressChanged(true)
        return true
    }

    /// The pointer went up at `point`: the pressed node is tapped if the pointer is still
    /// over it (or over a node inside it).
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func pointerUp(at point: LayoutPoint) {
        guard let target = pressed else { return }

        pressed = nil
        target.pressChanged(false)
        if let hit = root.hitTest(point), hit.isDescendant(of: target) {
            target.onTap?()
        }
    }

    /// The system took the pointer away (a scroll began, the window lost it): nothing is
    /// tapped.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func pointerCancelled() {
        guard let target = pressed else { return }

        pressed = nil
        target.pressChanged(false)
    }

    /// Unmounts the whole tree and lets go of the root's host role. The host does nothing
    /// afterwards.
    ///
    /// Ownership: releases the tree's subscriptions. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation.
    public func detach() {
        pointerCancelled()
        for node in mounted.values {
            node.unmount()
        }
        mounted = [:]
        root.unmount()
        root.hostOfRoot = nil
        onNeedsLayout = nil
        onNeedsRender = nil
    }

    /// Makes the tree match the placements: each node's subnodes are the nodes placed by its
    /// layout, in order. A node placed twice (both sides of a `Breakpoint`) belongs where it
    /// was laid out.
    private func mount(_ placements: [LayoutPlacement]) {
        var present: [NodeID: Node] = [root.id: root]
        var parent: [NodeID: Node] = [:]
        for placement in placements {
            guard let node = placement.element as? Node, node !== root else { continue }

            present[node.id] = node
            if let container = placement.container as? Node,
                placement.frame != nil || parent[node.id] == nil
            {
                parent[node.id] = container
            }
        }

        var children: [NodeID: [Node]] = [:]
        var listed: Set<NodeID> = []
        for placement in placements {
            guard let node = placement.element as? Node, let container = parent[node.id],
                placement.container === container, !listed.contains(node.id)
            else { continue }

            listed.insert(node.id)
            children[container.id, default: []].append(node)
        }

        for (id, node) in mounted where present[id] == nil {
            node.unmount()
        }
        for (id, node) in present {
            node.mount(in: parent[id], subnodes: children[id] ?? [])
        }
        mounted = present
    }
}
