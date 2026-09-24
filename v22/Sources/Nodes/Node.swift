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

    /// Whether the node is part of a laid-out tree.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isMounted = false

    weak var hostOfRoot: NodeHost?
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

        host?.setNeedsLayout()
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
        isMounted = true
        self.supernode = supernode
        self.subnodes = subnodes
        prepare()
    }

    func unmount() {
        isMounted = false
        supernode = nil
        subnodes = []
        updateObserver?.cancel()
        updateObserver = nil
        layoutObserver?.cancel()
        layoutObserver = nil
    }
}
