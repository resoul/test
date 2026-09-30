import LayoutCore
import StateCore
import ThemeCore

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

    /// How the node comes onto the screen and leaves it in an animated change; see
    /// `Transition`. The default fades.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var transition: Transition = .opacity

    /// Sets `transition` and returns the node, for use where it is placed:
    /// `if showsBadge { badge.transition(.scale) }`.
    ///
    /// Ownership: returns `self`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @discardableResult
    public func transition(_ transition: Transition) -> Self {
        self.transition = transition
        return self
    }

    /// The bar above the keyboard set on this node; see `keyboardBar`.
    var keyboardBarStorage: KeyboardBar?

    /// How the node presents itself to assistive technologies; see `Accessibility`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var accessibility = Accessibility() {
        didSet { if accessibility != oldValue { host?.setNeedsRender() } }
    }

    /// What assistive technologies can do with the node besides activating it; each shows
    /// as an action of its element.
    ///
    /// Ownership: the node keeps the actions; they must not keep the node. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var accessibilityActions: [AccessibilityAction] = [] {
        didSet { host?.setNeedsRender() }
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

    /// Whether the node takes a press at `point`, in its own coordinates, although it has no
    /// `onTap`: text takes a press on a link and leaves the rest to what is behind it. A node
    /// that takes it is tapped, on release, through `tapped(at:)`, and shows itself pressed.
    /// The default is `false`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func takesPress(at point: LayoutPoint) -> Bool { false }

    /// Whether the remote's select button can tap the node when it has focus: by default
    /// whether it has `onTap`. A node that takes presses at points overrides it to say whether
    /// it has one place to tap.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open var isTappable: Bool { onTap != nil }

    /// The node was tapped: at `point`, in its own coordinates, or `nil` when the tap did not
    /// come from a place (the select button). The default calls `onTap`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func tapped(at point: LayoutPoint?) {
        onTap?()
    }

    /// A short text the pointer shows by the node when it rests on it — the mouse on a Mac,
    /// a pointer on iPad; `nil`, the default, for none. A node inside one with a tip shows
    /// its own tip, or else the outer one's. Nothing shows it on iPhone or on a TV.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var toolTip: String? {
        didSet { if toolTip != oldValue { host?.setNeedsRender() } }
    }

    /// The way the node is dragged — a row swiped aside along `.horizontal` — or `nil`, the
    /// default, for none. A drag along it that starts on the node, or on a subnode not
    /// dragged that way itself, goes to `onDrag`, and a tap on it does not happen; a drag the
    /// other way scrolls as usual.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var dragAxis: ScrollAxis?

    /// What a drag along `dragAxis` does, told as it goes.
    ///
    /// Ownership: the node keeps the closure; it must not keep the node. Isolation:
    /// MainActor. Errors: none. Cancellation: a drag the system takes away ends `cancelled`.
    public var onDrag: (@MainActor (Drag) -> Void)?

    /// Whether the remote (tvOS) can move focus to the node. `nil`, the default, makes a node
    /// with `onTap` focusable. A focusable node is focused as a whole: nodes inside it are
    /// not focused separately.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isFocusable: Bool? {
        didSet { if isFocusable != oldValue { host?.setNeedsRender() } }
    }

    /// What an arrow pressed while the node has the focus does — the remote's (tvOS), the
    /// keyboard's (Mac) — before the focus moves. Returns whether the node took the press:
    /// the focus then stays where it is. A row lifted to be moved, for one, moves instead.
    /// Asked of the focused node, else of the nearest node around it that has one.
    ///
    ///     handle.onMoveCommand = { move in
    ///         guard isLifted else { return false }
    ///         step(move == .up ? -1 : 1)
    ///         return true
    ///     }
    ///
    /// Ownership: the node keeps the closure; it must not keep the node. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onMoveCommand: (@MainActor (FocusMove) -> Bool)?

    /// The commands the node carries out (`handle(_:isEnabled:perform:)`).
    var commandHandlers: [CommandHandler] = [] {
        didSet { handlersRevision?.value += 1 }
    }

    /// Changes whenever a handler is added or taken away, for whoever asked what the nodes can
    /// do; made when first asked.
    private var handlersRevision: State<Int>?

    /// Reading the handlers under tracking depends on their changing.
    func trackHandlers() {
        if handlersRevision == nil { handlersRevision = State(0) }
        _ = handlersRevision?.value
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

    /// Whether the node is in a tree its host shows (`NodeHost.isShown`): mounted, and the
    /// view holding the tree in a window and not hidden. A screen under the next one in a
    /// navigation stack, or in a tab not chosen, keeps its nodes mounted but not shown.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isShown = false

    /// Asks the host to keep `isOnScreen` up to date and to call `screenChanged(_:)` — for a
    /// node whose work should go first while it shows, such as an image loading. Off by
    /// default: the host looks at such nodes on every scroll move. A change takes effect at
    /// the next layout.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var tracksScreen = false {
        didSet { if tracksScreen != oldValue { setNeedsLayout() } }
    }

    /// Whether some of the node shows: its host shows, and it is within the host's bounds and
    /// within every node around it that clips its content, none of them hidden. Kept up to date after each layout and
    /// scroll move only while `tracksScreen` is set; `false` otherwise.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isOnScreen = false

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
        guard let scroll = enclosingScroll else { return .zero }

        return stickyOffset(showing: scroll.shownOffset)
    }

    /// `stickyOffset` were the node's scroll to show `view`: the point of its content at the
    /// window's top left corner, as drawn.
    func stickyOffset(showing view: LayoutPoint) -> LayoutPoint {
        guard let sticky, let scroll = enclosingScroll,
            let placement = scroll.placement(of: self)
        else { return .zero }

        // Everything in the scroll's coordinates, as laid out: the content zoomed that many
        // times shows that many times less of itself in the window.
        let scale = placement.scale
        let rect = LayoutRect(
            x: placement.origin.x / scale,
            y: placement.origin.y / scale,
            width: frame.size.width,
            height: frame.size.height
        )
        let view = LayoutPoint(x: view.x / scale, y: view.y / scale)
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
        let size = LayoutSize(
            width: scroll.frame.size.width / scale,
            height: scroll.frame.size.height / scale
        )
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
    /// origin, moved by `stickyOffset` and by `appearance.offset`.
    var shownOrigin: LayoutPoint {
        let moved = appearance.offset
        guard sticky != nil else {
            return LayoutPoint(x: frame.origin.x + moved.x, y: frame.origin.y + moved.y)
        }

        let offset = stickyOffset
        return LayoutPoint(
            x: frame.origin.x + offset.x + moved.x,
            y: frame.origin.y + offset.y + moved.y
        )
    }

    /// The subnodes in the order they are drawn, the last on top: by `appearance.zIndex`,
    /// and at the same one sticky ones over the rest, as positioned boxes are over the others
    /// in CSS; otherwise in layout order.
    ///
    /// Ownership: returns nodes the node keeps. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var subnodesInDrawingOrder: [Node] {
        guard subnodes.contains(where: { $0.sticky != nil || $0.appearance.zIndex != 0 }) else {
            return subnodes
        }

        // By rank, and in layout order within one.
        func rank(_ entry: (offset: Int, element: Node)) -> (Int, Int, Int) {
            (entry.element.appearance.zIndex, entry.element.sticky == nil ? 0 : 1, entry.offset)
        }
        return subnodes.enumerated()
            .sorted { rank($0) < rank($1) }
            .map(\.element)
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

    /// The pointer came to rest over the node, or left it — to show that a press would go
    /// to it. Told only to a node with `onTap` that is not turned off, as the mouse on a Mac
    /// or a pointer on iPad moves; never on iPhone or a TV. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func hoverChanged(_ isHovered: Bool) {}

    /// How the pointer looks while it rests over the node, where the platform has a pointer of
    /// its own — the mouse on a Mac: `.pointingHand` over a link, the arrow elsewhere. Read
    /// only while the node is the one under the pointer (`hoverChanged`), so a node with
    /// `onTap` and none of its own does not need to answer.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open var pointerStyle: PointerStyle { .arrow }

    /// Whether presses, the focus and assistive technologies reach the node: `false` for a
    /// control turned off, which then shows itself so.
    var isInteractive: Bool { true }

    /// The tip the pointer shows by the node: `toolTip`, or one a control takes from its
    /// command.
    var shownToolTip: String? { toolTip }

    /// The node joined a host's tree or left it — to start or stop work that only matters
    /// while it can be shown. Called on each change, not on every layout pass. A node that
    /// left can come back while its owner keeps it. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: an override
    /// cancels work it no longer needs when the node leaves.
    open func mountedChanged(_ isMounted: Bool) {}

    /// The node's tree began or stopped showing (`isShown`) — to start or stop work that only
    /// matters while it shows: loads, timers, frames. A node joining a shown tree gets it after
    /// `mountedChanged(true)`, a node leaving one before `mountedChanged(false)`; the tree's
    /// view leaving the window, or hidden, tells every node while they stay in the tree. Called
    /// on each change. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: an override
    /// cancels work it no longer needs when the tree stops showing.
    open func shownChanged(_ isShown: Bool) {}

    /// Tells the node whether its tree shows.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }

        isShown = shown
        shownChanged(shown)
    }

    /// The node came into sight or went out of it (`isOnScreen`), where it `tracksScreen`.
    /// Called on each change. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func screenChanged(_ isOnScreen: Bool) {}

    /// Updates `isOnScreen`, telling `screenChanged(_:)` of a change.
    func updateScreen() {
        let shows = isShown && shownRect != nil
        guard shows != isOnScreen else { return }

        isOnScreen = shows
        screenChanged(shows)
    }

    /// The part of the node's box that shows, in its own coordinates: within the host's
    /// bounds and every node around it that clips its content. `nil` when none of it shows,
    /// when it or a node around it is hidden or fully transparent, or when it is not mounted.
    var shownRect: LayoutRect? {
        guard isMounted, let host, !isHidden, appearance.opacity > 0 else { return nil }

        var low = LayoutPoint.zero
        var high = LayoutPoint(x: frame.size.width, y: frame.size.height)
        // Where this node's box is in the box of `node`.
        var placement = Placement.identity
        /// Keeps to the part of this node's box that shows within a box of `size` it is placed
        /// in by `placement`.
        func clip(to size: LayoutSize) {
            low.x = max(low.x, -placement.origin.x / placement.scale)
            low.y = max(low.y, -placement.origin.y / placement.scale)
            high.x = min(high.x, (size.width - placement.origin.x) / placement.scale)
            high.y = min(high.y, (size.height - placement.origin.y) / placement.scale)
        }
        var node: Node = self
        while let supernode = node.supernode {
            guard !supernode.isHidden, supernode.appearance.opacity > 0 else { return nil }

            placement = placement.moved(into: supernode, from: node.shownOrigin)
            if supernode.appearance.clipsContent {
                clip(to: supernode.frame.size)
            }
            node = supernode
        }
        placement.origin.x += node.frame.origin.x
        placement.origin.y += node.frame.origin.y
        clip(to: host.size)
        guard low.x < high.x, low.y < high.y else { return nil }

        return LayoutRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }

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
                let scale = node.contentScale
                let local = LayoutPoint(
                    x: (levels[top].point.x + node.contentOrigin.x) / scale - origin.x,
                    y: (levels[top].point.y + node.contentOrigin.y) / scale - origin.y
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

    /// Visits this node and the visible ones under it in pre-order, each with where the
    /// coordinates of its frame — its supernode's content — are (the first gets `placement`);
    /// `visit` returns whether to go into the node's subnodes. Hidden and fully transparent
    /// nodes, and all under them, are skipped. A loop over an explicit stack, so that a tree
    /// deeper than the main thread's stack does not crash it.
    func walkVisible(from placement: Placement, _ visit: (Node, Placement) -> Bool) {
        var pending: [(node: Node, placement: Placement)] = [(self, placement)]
        while let (node, placement) = pending.popLast() {
            guard !node.isHidden, node.appearance.opacity > 0, visit(node, placement) else {
                continue
            }

            let inner = placement.inside(node)
            // Pushed last to first, so the first subnode is visited next.
            for subnode in node.subnodes.reversed() {
                pending.append((subnode, inner))
            }
        }
    }

    /// The point of the node's box shown at its top left corner: its subnodes are drawn
    /// moved back by it. Zero, except where a scroll moved its content.
    var contentOrigin: LayoutPoint { .zero }

    /// How many times bigger than laid out the node's content is drawn, from the content's
    /// origin. 1, except where a scroll is zoomed.
    var contentScale: Double { 1 }

    /// The frame where `placement` puts the coordinates it is laid out in.
    func frame(in placement: Placement) -> LayoutRect {
        placement.rect(LayoutRect(origin: shownOrigin, size: frame.size))
    }

    /// Where this node's box is in the box of `ancestor` — by the frames as laid out, or as
    /// shown, moved where they stick; `nil` when `ancestor` is not around it.
    func placement(in ancestor: Node, shown: Bool = true) -> Placement? {
        var placement = Placement.identity
        var node: Node = self
        while node !== ancestor {
            guard let supernode = node.supernode else { return nil }

            placement = placement.moved(
                into: supernode,
                from: shown ? node.shownOrigin : node.frame.origin
            )
            node = supernode
        }
        return placement
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

    /// The theme of this part of the tree, in the conditions it is shown in: the host's
    /// theme, changed by the `themeOverride` of the node and of the nodes around it. Read in
    /// `update()` or `layoutSpec()`, the node follows it: a change of the theme, of the
    /// conditions or of an override runs them again.
    ///
    ///     override func update() {
    ///         appearance.background = theme.color(.surface)
    ///     }
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var theme: ResolvedTheme {
        let host = self.host ?? pendingHost ?? NodeHost.preparing
        var resolved =
            host?.resolvedTheme ?? ResolvedTheme(theme: .standard, conditions: .standard)
        var overrides: [ThemeOverride] = []
        var node: Node? = self
        while let current = node {
            if let override = current.themeOverride {
                overrides.append(override)
            }
            node = current.supernode
        }
        for override in overrides.reversed() {
            resolved = override.applied(to: resolved)
        }
        if supernode == nil, hostOfRoot == nil {
            // Read before the node is in the tree: an override around it counts once it is.
            readThemeAway = true
        }
        return resolved
    }

    /// A change of the theme for this node and the nodes inside it — its color scheme, its
    /// contrast, any of its values; the rest comes from around, also when that changes later.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var themeOverride: ThemeOverride? {
        didSet { (host ?? pendingHost)?.themeOverridesChanged() }
    }

    /// The node read its theme while it was not in the tree.
    private var readThemeAway = false

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
        isInteractive && (isFocusable ?? isTappable)
    }

    /// Whether the pointer rests over the node (`hoverChanged`).
    private(set) var isHovered = false

    func setHovered(_ isHovered: Bool) {
        guard isHovered != self.isHovered else { return }

        self.isHovered = isHovered
        hoverChanged(isHovered)
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

    func mount(in supernode: Node?, subnodes: [Node], shown: Bool = false) {
        let wasMounted = isMounted
        isMounted = true
        self.supernode = supernode
        self.subnodes = subnodes
        if readThemeAway, supernode != nil {
            readThemeAway = false
            var node: Node? = supernode
            while let current = node {
                if current.themeOverride != nil {
                    // It read the tree's theme, and an override around it changes that.
                    host?.themeOverridesChanged()
                    break
                }
                node = current.supernode
            }
        }
        prepare()
        if !wasMounted { mountedChanged(true) }
        setShown(shown)
    }

    func unmount() {
        setShown(false)
        setHovered(false)
        let wasMounted = isMounted
        isMounted = false
        isOnScreen = false
        supernode = nil
        subnodes = []
        updateObserver?.cancel()
        updateObserver = nil
        layoutObserver?.cancel()
        layoutObserver = nil
        if wasMounted { mountedChanged(false) }
    }
}

/// Where one node's coordinates are in another's: the point `p` is at `origin + p * scale`.
struct Placement: Equatable {
    var origin: LayoutPoint
    var scale: Double

    static let identity = Placement(origin: .zero, scale: 1)

    func point(_ point: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func rect(_ rect: LayoutRect) -> LayoutRect {
        let at = point(rect.origin)
        return LayoutRect(
            x: at.x,
            y: at.y,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        )
    }

    /// For the content of `node`, whose frame is in the coordinates this places: its
    /// subnodes' frames are in that content, drawn `contentScale` times bigger and moved back
    /// by `contentOrigin`.
    @MainActor
    func inside(_ node: Node) -> Placement {
        let shown = node.shownOrigin
        let back = node.contentOrigin
        return Placement(
            origin: point(LayoutPoint(x: shown.x - back.x, y: shown.y - back.y)),
            scale: scale * node.contentScale
        )
    }

    /// This placement of a box inside a node, taken one level out: into the box of
    /// `supernode`, the node's frame starting at `at` in its content.
    @MainActor
    func moved(into supernode: Node, from at: LayoutPoint) -> Placement {
        let zoom = supernode.contentScale
        let back = supernode.contentOrigin
        return Placement(
            origin: LayoutPoint(
                x: (at.x + origin.x) * zoom - back.x,
                y: (at.y + origin.y) * zoom - back.y
            ),
            scale: scale * zoom
        )
    }
}

/// Where a drag of a node is: `Node.onDrag` is told each step.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Drag: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Phase: Sendable, Hashable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case began
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case changed
        /// The pointer let go.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case ended
        /// The system took the drag away: go back to where it began.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case cancelled
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var phase: Phase
    /// Points the pointer moved since the drag began, in the root's coordinates.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var translation: LayoutPoint
    /// Points a second the pointer moved at when it let go; zero before.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var velocity: LayoutPoint

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(phase: Phase, translation: LayoutPoint, velocity: LayoutPoint = .zero) {
        self.phase = phase
        self.translation = translation
        self.velocity = velocity
    }
}

/// The look of the pointer over a node (`Node.pointerStyle`).
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PointerStyle: Sendable, Hashable {
    /// The pointer as it is everywhere else.
    case arrow
    /// The hand that shows something under the pointer opens when pressed: a link.
    case pointingHand
}
