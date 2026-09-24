#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import UIKit
    import os

    /// Temporary: the focus handshake with tvOS, while defect #134 is open.
    private let focusLog = Logger(subsystem: "dev.layout.nodes", category: "focus")

    /// A view that shows a tree of nodes: it lays the tree out in its bounds and draws it into
    /// its layer. Outside, it is an ordinary view — frames, Auto Layout (through
    /// `intrinsicContentSize`), or a place in another view's `layoutSpec()`.
    ///
    /// Ownership: the view owns the host and, through it, the tree. Isolation: MainActor.
    /// Errors: none. Cancellation: `host.detach()` ends the tree's updates.
    @MainActor
    public final class NodeView: UIView {
        /// Ownership: owned by the view. Isolation: MainActor. Errors: none. Cancellation:
        /// `detach()`.
        public let host: NodeHost

        fileprivate let renderer = LayerRenderer()
        private var isLayingOut = false
        private var accessibilityCache: [UIAccessibilityElement]?
        /// The focus items of the tree, one per focusable node, kept while the node is: the
        /// focus system recognizes the focused item by identity.
        private var focusItemsByNode: [NodeID: NodeFocusItem] = [:]
        private var focusOrder: [NodeFocusItem] = []
        /// A select press that began on a focused node and has not ended yet.
        private var isSelecting = false

        /// A view showing `root`.
        ///
        /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(root: Node) {
            host = NodeHost(root: root, size: LayoutSize(width: 0, height: 0))
            super.init(frame: .zero)
            isAccessibilityElement = false
            host.onNeedsLayout = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.invalidateIntrinsicContentSize()
                self.setNeedsLayout()
            }
            host.onNeedsRender = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.setNeedsLayout()
            }
        }

        /// Not supported: a node tree is built in code.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: always fails. Cancellation: not
        /// applicable.
        public required init?(coder: NSCoder) {
            nil
        }

        /// Ownership: returns the root the host keeps. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var root: Node { host.root }

        /// Lays the tree out in the bounds and draws it.
        ///
        /// Ownership: updates the tree and the layers. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func layoutSubviews() {
            super.layoutSubviews()
            isLayingOut = true
            defer { isLayingOut = false }

            let widthChanged = host.size.width != Double(bounds.width)
            host.size = LayoutSize(width: Double(bounds.width), height: Double(bounds.height))
            host.scale = Double(traitCollection.displayScale > 0 ? traitCollection.displayScale : 1)
            host.direction =
                effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(
                    host.root,
                    in: layer,
                    scale: host.scale,
                    animation: host.renderAnimation
                )
                host.didRender()
                accessibilityCache = nil
                updateFocusItems()
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .layoutChanged, argument: nil)
                }
            }
            if widthChanged {
                // The height the tree wants depends on the width it has.
                invalidateIntrinsicContentSize()
            }
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func sizeThatFits(_ size: CGSize) -> CGSize {
            let limited = size.width > 0 && size.width < CGFloat.greatestFiniteMagnitude
            let fitting = host.fittingSize(
                width: limited ? .definite(Double(size.width)) : .maxContent
            )
            return CGSize(width: fitting.width, height: fitting.height)
        }

        /// Presses on nodes with `onTap`; other touches go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, host.pointerDown(at: point(of: touch)) else {
                super.touchesBegan(touches, with: event)
                return
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first {
                host.pointerUp(at: point(of: touch))
            }
            super.touchesEnded(touches, with: event)
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            host.pointerCancelled()
            super.touchesCancelled(touches, with: event)
        }

        private func point(of touch: UITouch) -> LayoutPoint {
            let location = touch.location(in: self)
            return LayoutPoint(x: Double(location.x), y: Double(location.y))
        }

        // MARK: - Focus

        /// Whether the platform's focus system moves between the tree's nodes: on tvOS. With a
        /// keyboard on iPad the tree takes no focus yet.
        private var usesFocus: Bool {
            traitCollection.userInterfaceIdiom == .tv
        }

        /// The tree's focusable nodes as focus items, added to UIKit's own (subviews).
        ///
        /// Ownership: the view keeps the items. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func focusItems(in rect: CGRect) -> [any UIFocusItem] {
            let own = super.focusItems(in: rect)
            let nodes = focusOrder.filter { $0.frame.intersects(rect) }
            focusLog.notice(
                "focusItems(in: \(String(describing: rect))) own=\(own.count) nodes=\(nodes.map(\.debugDescription))"
            )
            return own + nodes
        }

        public override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            let result = super.shouldUpdateFocus(in: context)
            focusLog.notice(
                "shouldUpdateFocus \(String(describing: context.previouslyFocusedItem)) -> \(String(describing: context.nextFocusedItem)) heading=\(context.focusHeading.rawValue) result=\(result)"
            )
            return result
        }

        /// The focused node's item, so a focus update keeps the focus where it is.
        ///
        /// Ownership: returns an item the view keeps. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            if let focused = host.focusedNode, let item = focusItemsByNode[focused] {
                return [item]
            }
            return super.preferredFocusEnvironments
        }

        /// Tells the host where the platform moved the focus: to one of the tree's nodes, or
        /// away from them.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            super.didUpdateFocus(in: context, with: coordinator)
            focusLog.notice(
                "didUpdateFocus \(String(describing: context.previouslyFocusedItem)) -> \(String(describing: context.nextFocusedItem)) heading=\(context.focusHeading.rawValue)"
            )
            if let next = context.nextFocusedItem as? NodeFocusItem, next.view === self {
                host.focus(next.node)
            } else if host.focusedNode != nil {
                host.focus(nil)
            }
        }

        /// Remote presses come to the first responder, and a focus item that is not a view
        /// is not one: the view takes the role where the tree takes focus.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var canBecomeFirstResponder: Bool { usesFocus }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, usesFocus {
                becomeFirstResponder()
            }
        }

        /// The remote's select button presses the focused node; other presses go on up the
        /// responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            focusLog.notice(
                "pressesBegan \(presses.map { $0.type.rawValue }) firstResponder=\(self.isFirstResponder)"
            )
            if presses.contains(where: { $0.type == .select }), host.selectBegan() {
                isSelecting = true
            } else {
                super.pressesBegan(presses, with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if isSelecting, presses.contains(where: { $0.type == .select }) {
                isSelecting = false
                host.selectEnded()
            } else {
                super.pressesEnded(presses, with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            if isSelecting {
                isSelecting = false
                host.pointerCancelled()
            } else {
                super.pressesCancelled(presses, with: event)
            }
        }

        /// Brings the focus items in line with the tree after a drawing. Asks the focus system
        /// to look again when the focused node is gone, and when the first items appear — it
        /// may have looked for them before the tree was laid out.
        private func updateFocusItems() {
            guard usesFocus else { return }

            let hadItems = !focusOrder.isEmpty
            var kept: [NodeID: NodeFocusItem] = [:]
            focusOrder = host.focusItems().map { item in
                let focusItem =
                    focusItemsByNode[item.node] ?? NodeFocusItem(view: self, node: item.node)
                focusItem.frame = CGRect(
                    x: item.frame.origin.x,
                    y: item.frame.origin.y,
                    width: item.frame.size.width,
                    height: item.frame.size.height
                )
                kept[item.node] = focusItem
                return focusItem
            }
            let lostFocus = focusItemsByNode.values.contains {
                $0.isFocused && kept[$0.node] == nil
            }
            focusItemsByNode = kept
            focusLog.notice(
                "focus items \(self.focusOrder.map(\.debugDescription)) in bounds \(String(describing: self.bounds))"
            )
            if lostFocus || (!hadItems && !focusOrder.isEmpty) {
                setNeedsFocusUpdate()
            }
        }

        /// The tree's accessibility elements (`NodeHost.accessibilityItems()`), rebuilt after
        /// every drawing.
        ///
        /// Ownership: the view keeps the elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override var accessibilityElements: [Any]? {
            get {
                if let accessibilityCache { return accessibilityCache }

                let elements = host.accessibilityItems().map {
                    NodeAccessibilityElement(container: self, item: $0)
                }
                accessibilityCache = elements
                return elements
            }
            set {}
        }

        /// No width of its own — the surroundings give it one (constraints, SwiftUI, a
        /// frame), as for a paragraph of text — and the height the tree takes at the current
        /// width. A tree's widest content is a poor width to ask for: one long line of text
        /// can make it wider than the screen.
        public override var intrinsicContentSize: CGSize {
            let width =
                bounds.width > 0 ? AvailableSpace.definite(Double(bounds.width)) : .maxContent
            return CGSize(
                width: UIView.noIntrinsicMetric,
                height: host.fittingSize(width: width).height
            )
        }
    }

    extension NodeView {
        /// The layer drawing `node`, for tests and debugging.
        ///
        /// Ownership: returns a layer the view's renderer owns. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public func renderedLayer(for node: Node) -> CALayer? {
            renderer.layer(for: node)
        }
    }

    extension UIView {
        /// Shows `node` in a new `NodeView` added as a subview, and returns it for sizing
        /// and positioning.
        ///
        /// Ownership: the view keeps the new subview, which keeps the node. Isolation:
        /// MainActor. Errors: none. Cancellation: remove the subview and call
        /// `host.detach()`.
        @discardableResult
        public func addSubnode(_ node: Node) -> NodeView {
            let view = NodeView(root: node)
            addSubview(view)
            return view
        }
    }

    /// One focusable node of a tree for the platform's focus system. It keeps the node's
    /// identity and its frame from the last drawing; it never holds the node itself.
    @MainActor
    final class NodeFocusItem: NSObject, UIFocusItem {
        let node: NodeID
        private(set) weak var view: NodeView?
        /// In the view's coordinates.
        var frame: CGRect = .zero

        init(view: NodeView, node: NodeID) {
            self.view = view
            self.node = node
        }

        var isFocused: Bool {
            UIFocusSystem.focusSystem(for: self)?.focusedItem === self
        }

        var canBecomeFocused: Bool { true }

        override var debugDescription: String {
            "\(node) \(String(describing: frame))"
        }

        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
        var parentFocusEnvironment: (any UIFocusEnvironment)? { view }
        /// The container of the item's own children, not of the item: a node is focused as a
        /// whole, so there are none. The view here made the focus engine find the item's
        /// siblings as its children, and the remote could not move the focus.
        var focusItemContainer: (any UIFocusItemContainer)? { nil }

        func setNeedsFocusUpdate() {
            UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self)
        }

        func updateFocusIfNeeded() {
            UIFocusSystem.focusSystem(for: self)?.updateFocusIfNeeded()
        }

        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }

        func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {}
    }

    /// One accessibility element of a node tree. It keeps the node's identity and asks the
    /// host to act on it; it never holds the node itself.
    @MainActor
    final class NodeAccessibilityElement: UIAccessibilityElement {
        private let node: NodeID
        private weak var host: NodeHost?

        init(container: NodeView, item: AccessibilityItem) {
            node = item.node
            host = container.host
            super.init(accessibilityContainer: container)
            accessibilityLabel = item.label
            accessibilityValue = item.value
            accessibilityHint = item.hint
            accessibilityTraits = NodeAccessibilityElement.traits(item.traits)
            accessibilityFrameInContainerSpace = CGRect(
                x: item.frame.origin.x,
                y: item.frame.origin.y,
                width: item.frame.size.width,
                height: item.frame.size.height
            )
        }

        override func accessibilityActivate() -> Bool {
            host?.activate(node) ?? false
        }

        private static func traits(_ traits: AccessibilityTraits) -> UIAccessibilityTraits {
            var result: UIAccessibilityTraits = []
            if traits.contains(.button) { result.insert(.button) }
            if traits.contains(.header) { result.insert(.header) }
            if traits.contains(.image) { result.insert(.image) }
            if traits.contains(.staticText) { result.insert(.staticText) }
            if traits.contains(.selected) { result.insert(.selected) }
            if traits.contains(.notEnabled) { result.insert(.notEnabled) }
            return result
        }
    }
#endif
