#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import UIKit

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
        /// Holds the tree's layers, scaled by `zoom` from its top left corner.
        private let contentLayer = CALayer()
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
            contentLayer.anchorPoint = .zero
            layer.addSublayer(contentLayer)
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

        /// How many times bigger than its points the tree is shown: at 2, it is laid out in
        /// half the view's size and drawn twice as big — for a TV, seen from across a room.
        /// Text is drawn for the final size and stays sharp; taps, focus and accessibility
        /// frames follow.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var zoom: Double = 1 {
            didSet {
                guard zoom != oldValue else { return }

                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        /// `zoom`, kept positive.
        private var factor: Double { zoom > 0 ? zoom : 1 }

        /// Lays the tree out in the bounds and draws it.
        ///
        /// Ownership: updates the tree and the layers. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func layoutSubviews() {
            super.layoutSubviews()
            isLayingOut = true
            defer { isLayingOut = false }

            let content = LayoutSize(
                width: Double(bounds.width) / factor,
                height: Double(bounds.height) / factor
            )
            let widthChanged = host.size.width != content.width
            host.size = content
            // Frames snap to, and text is drawn for, the pixels of the zoomed size.
            host.scale =
                Double(traitCollection.displayScale > 0 ? traitCollection.displayScale : 1) * factor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.bounds = CGRect(x: 0, y: 0, width: content.width, height: content.height)
            contentLayer.position = .zero
            contentLayer.transform = CATransform3DMakeScale(CGFloat(factor), CGFloat(factor), 1)
            CATransaction.commit()
            host.direction =
                effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(
                    host.root,
                    in: contentLayer,
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
                width: limited ? .definite(Double(size.width) / factor) : .maxContent
            )
            return CGSize(width: fitting.width * factor, height: fitting.height * factor)
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
            return LayoutPoint(x: Double(location.x) / factor, y: Double(location.y) / factor)
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
            super.focusItems(in: rect) + focusOrder.filter { $0.frame.intersects(rect) }
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
                focusItem.frame = zoomed(item.frame)
                kept[item.node] = focusItem
                return focusItem
            }
            let lostFocus = focusItemsByNode.values.contains {
                $0.isFocused && kept[$0.node] == nil
            }
            focusItemsByNode = kept
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
                bounds.width > 0
                ? AvailableSpace.definite(Double(bounds.width) / factor) : .maxContent
            return CGSize(
                width: UIView.noIntrinsicMetric,
                height: host.fittingSize(width: width).height * factor
            )
        }

        /// A frame in the tree's points, in the view's.
        fileprivate func zoomed(_ frame: LayoutRect) -> CGRect {
            CGRect(
                x: frame.origin.x * factor,
                y: frame.origin.y * factor,
                width: frame.size.width * factor,
                height: frame.size.height * factor
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
            accessibilityFrameInContainerSpace = container.zoomed(item.frame)
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
