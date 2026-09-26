import LayoutCore
import StateCore

/// Identity of a node for as long as it lives; never reused.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct NodeID: Hashable, Sendable, CustomStringConvertible {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let raw: UInt64

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var description: String { "#\(raw)" }

    @MainActor private static var last: UInt64 = 0

    @MainActor
    static func next() -> NodeID {
        last &+= 1
        return NodeID(raw: last)
    }
}

/// A piece of UI: a subclass creates its child nodes once, keeps them in properties, and
/// describes how they are laid out in `layoutSpec()`.
///
///     final class ProfileCard: Node {
///         let title = Text()
///         let follow = Button("Follow")
///         let model: ProfileModel
///
///         override func update() {
///             title.text = model.user.value.name
///         }
///
///         override func layoutSpec() -> LayoutSpec? {
///             FlexContainer(.row) {
///                 title.flex(grow: 1)
///                 if !model.isFollowing.value { follow }
///             }
///             .padding(16)
///         }
///     }
///
/// What `update()` reads, it depends on: when any of it changes, `update()` runs again. What
/// `layoutSpec()` reads, the layout depends on: when any of it changes, the tree is laid out
/// again. The nodes a layout mentions are the node's subnodes; a node it stops mentioning is
/// unmounted but stays alive in its property, and comes back as the same node.
///
/// Ownership: the creator owns a node; a node owns its subnodes while they are mounted and
/// knows its supernode weakly. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
open class Node: LayoutElement {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let id: NodeID

    /// The node whose layout placed this one; `nil` for a root or an unmounted node.
    ///
    /// Ownership: weak. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) weak var supernode: Node?

    /// The nodes this node's last layout placed, in the order it mentions them.
    ///
    /// Ownership: the node keeps them while they are mounted. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    public private(set) var subnodes: [Node] = []

    /// The frame from the last layout, in the coordinates of the supernode.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var frame = LayoutRect(x: 0, y: 0, width: 0, height: 0)

    /// Where the node sticks while its scroll moves (`sticky` in the layout that placed it),
    /// or `nil`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var sticky: StickyPosition?

    /// Hidden by `hidden`, `invisible` or a `Breakpoint` in the layout that placed it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isHidden = false

    /// How the node's box looks. A change redraws the tree without a layout.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var appearance = Appearance() {
        didSet { if appearance != oldValue { host?.setNeedsRender() } }
    }

    /// How the node presents itself to assistive technologies; see `Accessibility`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var accessibility = Accessibility() {
        didSet { if accessibility != oldValue { host?.setNeedsRender() } }
    }

    /// What the node's content says to assistive technologies by itself — text, for a node
    /// showing text. The default is `nil`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    open var accessibilityContentLabel: String? { nil }

    /// Traits of the node's content by itself — `.staticText` for text. The default is none.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    open var accessibilityContentTraits: AccessibilityTraits { [] }

    /// What a tap on the node, or on a subnode without a tap action of its own, does.
    ///
    /// Ownership: the node keeps the closure; it must not keep the node. Isolation:
    /// MainActor. Errors: none. Cancellation: set to `nil`.
    public var onTap: (@MainActor () -> Void)?

    /// Whether the remote (tvOS) can move focus to the node. `nil`, the default, makes a node
    /// with `onTap` focusable. A focusable node is focused as a whole: nodes inside it are
    /// not focused separately.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isFocusable: Bool? {
        didSet { if isFocusable != oldValue { host?.setNeedsRender() } }
    }

    /// Makes the node a focus section: when the remote moves the focus toward any part of
    /// the node, the focus goes to a node inside it — the one focused there last, else the
    /// first — instead of only to nodes lying straight in the direction pressed. For rows and
    /// cards whose focusable nodes do not line up with their neighbors'.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isFocusSection = false {
        didSet { if isFocusSection != oldValue { host?.setNeedsRender() } }
    }

    /// Whether the node has the focus of its host.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isFocused = false

    /// Whether the node is part of a laid-out tree.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isMounted = false

    weak var hostOfRoot: NodeHost?
    /// The host whose layout, still being solved off the main thread, is going to mount this
    /// node. Until then the node hangs from nothing, and a change to it must still reach
    /// that host, or the layout would show what the node was when the solve began.
    weak var pendingHost: NodeHost?
    private var layoutObserver: Observer?
    private var updateObserver: Observer?
    private var isInFirstUpdate = false

    /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {
        id = NodeID.next()
    }

    /// The layout of this node's subnodes, or `nil` for a node without any — it is then
    /// measured by `layoutContent`. Reads made here are dependencies of the layout.
    ///
    /// Ownership: returns a value borrowing the subnodes. Isolation: MainActor. Errors: none.
    /// Cancellation: none.
    open func layoutSpec() -> LayoutSpec? { nil }

    /// Brings the node's own properties up to date with the state it shows. Runs before the
    /// node is first laid out, and again whenever something it read changes. Reads made here
    /// are dependencies of the update, not of the layout.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func update() {}

    /// How the node's own content measures (text, an image), or `nil` for none.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    open var layoutContent: LeafContent? { nil }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public var embeddedLayout: LayoutSpec? {
        prepare()
        let observer = layoutObserver ?? makeLayoutObserver()
        return observer.track { layoutSpec() }
    }

    /// Ownership: stores the frame. Isolation: MainActor. Errors: none. Cancellation: none.
    public func applyLayoutFrame(_ frame: LayoutRect) {
        self.frame = frame
    }

    /// Ownership: stores the value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func applyLayoutVisibility(_ isVisible: Bool) {
        isHidden = !isVisible
    }

    /// Ownership: stores the value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func applyLayoutSticky(_ sticky: StickyPosition?) {
        self.sticky = sticky
    }

    /// How far a sticky node is moved from its frame now to keep to its scroll's edges —
    /// within the frame of its container. Zero for a node that does not stick, or is not in a
    /// scroll.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var stickyOffset: LayoutPoint {
        guard let sticky, let scroll = enclosingScroll, let rect = scroll.frame(of: self) else {
            return .zero
        }

        // Everything in the scroll's coordinates, as laid out.
        let shift = LayoutPoint(
            x: rect.origin.x - frame.origin.x,
            y: rect.origin.y - frame.origin.y
        )
        let bounds = LayoutRect(
            x: sticky.bounds.origin.x + shift.x,
            y: sticky.bounds.origin.y + shift.y,
            width: sticky.bounds.size.width,
            height: sticky.bounds.size.height
        )
        let view = scroll.shownOffset
        let size = scroll.frame.size
        return LayoutPoint(
            x: Node.stick(
                rect.origin.x,
                rect.size.width,
                start: sticky.left.map { view.x + $0 },
                end: sticky.right.map { view.x + size.width - $0 },
                within: bounds.origin.x,
                bounds.origin.x + bounds.size.width
            ),
            y: Node.stick(
                rect.origin.y,
                rect.size.height,
                start: sticky.top.map { view.y + $0 },
                end: sticky.bottom.map { view.y + size.height - $0 },
                within: bounds.origin.y,
                bounds.origin.y + bounds.size.height
            )
        )
    }

    /// How far a span at `position` of `length` moves along one axis to start no earlier
    /// than `start` and end no later than `end`, without leaving `low`…`high` (CSS
    /// Positioned Layout §3.4).
    private static func stick(
        _ position: Double,
        _ length: Double,
        start: Double?,
        end: Double?,
        within low: Double,
        _ high: Double
    ) -> Double {
        var shift = 0.0
        if let start, position < start {
            shift = min(start - position, max(0, high - (position + length)))
        }
        if let end, position + length + shift > end {
            shift = max(end - (position + length), min(0, low - position))
        }
        return shift
    }

    /// The nearest scroll around the node, or `nil`.
    ///
    /// Ownership: returns a node of the tree. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var enclosingScroll: Scroll? {
        var node = supernode
        while let current = node {
            if let scroll = current as? Scroll { return scroll }

            node = current.supernode
        }
        return nil
    }

    /// Where the node shows in its supernode's coordinates as laid out: its frame's
    /// origin, moved by `stickyOffset`.
    var shownOrigin: LayoutPoint {
        guard sticky != nil else { return frame.origin }

        let offset = stickyOffset
        return LayoutPoint(x: frame.origin.x + offset.x, y: frame.origin.y + offset.y)
    }

    /// The subnodes in the order they are drawn, the last on top: sticky ones over the rest,
    /// as positioned boxes are over the others in CSS; otherwise in layout order.
    ///
    /// Ownership: returns nodes the node keeps. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var subnodesInDrawingOrder: [Node] {
        guard subnodes.contains(where: { $0.sticky != nil }) else { return subnodes }

        return subnodes.filter { $0.sticky == nil } + subnodes.filter { $0.sticky != nil }
    }

    /// The node got or lost the focus — to show it. Runs inside the host's
    /// `focusAnimation`. The default lifts the node, a tenth bigger, where the host's
    /// `focusLook` is `.lift` (a TV); with `.ring` the adapter draws the ring and the default
    /// does nothing. An override replaces that.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func focusChanged(_ isFocused: Bool) {
        guard (host?.focusLook ?? .lift) == .lift else { return }

        appearance.scale = isFocused ? 1.1 : 1
    }

    /// A press on the node (one with `onTap`) began or ended — to show it pressed. The
    /// default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func pressChanged(_ isPressed: Bool) {}

    /// The node joined a host's tree or left it — to start or stop work that only matters
    /// while it can be shown. Called on each change, not on every layout pass. A node that
    /// left can come back while its owner keeps it. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: an override
    /// cancels work it no longer needs when the node leaves.
    open func mountedChanged(_ isMounted: Bool) {}

    /// The deepest visible node under `point`, given in this node's coordinates, or `nil`.
    /// Later subnodes are on top. Subnodes outside the node's box are found too, unless the
    /// node clips its content.
    ///
    /// Ownership: returns a node of the tree. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func hitTest(_ point: LayoutPoint) -> Node? {
        // A loop over an explicit stack rather than recursion, so that a tree deeper than the
        // main thread's stack does not crash it. Each level remembers the subnode it tries
        // next, from the last; a node is the hit once none of its subnodes is.
        struct Level {
            let node: Node
            let point: LayoutPoint
            let isInside: Bool
            let subnodes: [Node]
            var next: Int
        }

        func enter(_ node: Node, at point: LayoutPoint) -> Level? {
            guard !node.isHidden, node.appearance.opacity > 0 else { return nil }

            let isInside =
                point.x >= 0 && point.y >= 0 && point.x < node.frame.size.width
                && point.y < node.frame.size.height
            if node.appearance.clipsContent && !isInside { return nil }

            let subnodes = node.subnodesInDrawingOrder
            return Level(
                node: node,
                point: point,
                isInside: isInside,
                subnodes: subnodes,
                next: subnodes.count - 1
            )
        }

        guard let first = enter(self, at: point) else { return nil }

        var levels = [first]
        while let top = levels.indices.last {
            if levels[top].next >= 0 {
                let node = levels[top].node
                let subnode = levels[top].subnodes[levels[top].next]
                levels[top].next -= 1
                let origin = subnode.shownOrigin
                let local = LayoutPoint(
                    x: levels[top].point.x - origin.x + node.contentOrigin.x,
                    y: levels[top].point.y - origin.y + node.contentOrigin.y
                )
                if let level = enter(subnode, at: local) {
                    levels.append(level)
                }
                continue
            }

            let done = levels.removeLast()
            if done.isInside { return done.node }
        }
        return nil
    }

    /// Visits this node and the visible ones under it in pre-order, each with the origin of
    /// its supernode's frame (the first gets `origin`); `visit` returns whether to go into the
    /// node's subnodes. Hidden and fully transparent nodes, and all under them, are skipped.
    /// A loop over an explicit stack, so that a tree deeper than the main thread's stack does
    /// not crash it.
    func walkVisible(from origin: LayoutPoint, _ visit: (Node, LayoutPoint) -> Bool) {
        var pending: [(node: Node, origin: LayoutPoint)] = [(self, origin)]
        while let (node, origin) = pending.popLast() {
            guard !node.isHidden, node.appearance.opacity > 0, visit(node, origin) else {
                continue
            }

            let shown = node.shownOrigin
            let inner = LayoutPoint(
                x: origin.x + shown.x - node.contentOrigin.x,
                y: origin.y + shown.y - node.contentOrigin.y
            )
            // Pushed last to first, so the first subnode is visited next.
            for subnode in node.subnodes.reversed() {
                pending.append((subnode, inner))
            }
        }
    }

    /// The point of the node's own coordinates shown at its top left corner: its subnodes
    /// are drawn moved back by it. Zero, except where a scroll moved its content.
    var contentOrigin: LayoutPoint { .zero }

    /// The frame in the coordinates `origin` is given in.
    func frame(from origin: LayoutPoint) -> LayoutRect {
        let shown = shownOrigin
        return LayoutRect(
            x: origin.x + shown.x,
            y: origin.y + shown.y,
            width: frame.size.width,
            height: frame.size.height
        )
    }

    /// Whether `ancestor` is this node or one of its supernodes.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func isDescendant(of ancestor: Node) -> Bool {
        var node: Node? = self
        while let current = node {
            if current === ancestor { return true }

            node = current.supernode
        }
        return false
    }

    /// The host of the tree this node is mounted in.
    ///
    /// Ownership: returns a reference the host owns. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var host: NodeHost? {
        var node: Node? = self
        while let current = node {
            if let host = current.hostOfRoot { return host }

            node = current.supernode
        }
        return nil
    }

    /// Asks for a new layout of the tree: call it when something `layoutContent` depends on
    /// changes (text, an image). State read in `layoutSpec()` does this by itself.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func setNeedsLayout() {
        // The first update runs while the node is being laid out, before it is measured:
        // what it changes is already in this layout.
        guard !isInFirstUpdate else { return }

        (host ?? pendingHost)?.setNeedsLayout()
    }

    var canBecomeFocused: Bool {
        isFocusable ?? (onTap != nil)
    }

    func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }

        self.isFocused = isFocused
        focusChanged(isFocused)
    }

    // MARK: - Mounting

    /// Starts the tracked update before the node is first measured.
    private func prepare() {
        guard updateObserver == nil else { return }

        let observer = Observer { [weak self] in self?.runUpdate() }
        updateObserver = observer
        isInFirstUpdate = true
        defer { isInFirstUpdate = false }
        runUpdate()
    }

    private func runUpdate() {
        updateObserver?.track { update() }
    }

    private func makeLayoutObserver() -> Observer {
        let observer = Observer { [weak self] in self?.setNeedsLayout() }
        layoutObserver = observer
        return observer
    }

    func mount(in supernode: Node?, subnodes: [Node]) {
        let wasMounted = isMounted
        isMounted = true
        self.supernode = supernode
        self.subnodes = subnodes
        prepare()
        if !wasMounted { mountedChanged(true) }
    }

    func unmount() {
        let wasMounted = isMounted
        isMounted = false
        supernode = nil
        subnodes = []
        updateObserver?.cancel()
        updateObserver = nil
        layoutObserver?.cancel()
        layoutObserver = nil
        if wasMounted { mountedChanged(false) }
    }
}
