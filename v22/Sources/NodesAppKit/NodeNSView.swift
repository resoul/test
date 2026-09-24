#if canImport(AppKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender

    /// A view that shows a tree of nodes: it lays the tree out in its bounds and draws it into
    /// a layer it hosts. Outside, it is an ordinary view — frames, Auto Layout (through
    /// `intrinsicContentSize`), or a place in another view's `layoutSpec()`.
    ///
    /// The view hosts its own layer, so AppKit leaves that layer's geometry alone; it is
    /// flipped to put the origin at the top left, where layout frames start.
    ///
    /// Ownership: the view owns the host and, through it, the tree. Isolation: MainActor.
    /// Errors: none. Cancellation: `host.detach()` ends the tree's updates.
    @MainActor
    public final class NodeNSView: NSView {
        /// Ownership: owned by the view. Isolation: MainActor. Errors: none. Cancellation:
        /// `detach()`.
        public let host: NodeHost

        private let renderer = LayerRenderer()
        private let hostedLayer = CALayer()
        private var isLayingOut = false
        private var accessibilityCache: [NSAccessibilityElement]?

        /// A view showing `root`.
        ///
        /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(root: Node) {
            host = NodeHost(root: root, size: LayoutSize(width: 0, height: 0))
            super.init(frame: .zero)
            hostedLayer.isGeometryFlipped = true
            layer = hostedLayer
            wantsLayer = true
            host.onNeedsLayout = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.invalidateIntrinsicContentSize()
                self.needsLayout = true
            }
            host.onNeedsRender = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.needsLayout = true
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

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var isFlipped: Bool { true }

        /// A new size needs a new layout; AppKit asks for one by itself only for views laid
        /// out by constraints.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }

        /// Lays the tree out in the bounds and draws it.
        ///
        /// Ownership: updates the tree and the layers. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func layout() {
            super.layout()
            isLayingOut = true
            defer { isLayingOut = false }

            let widthChanged = host.size.width != Double(bounds.width)
            host.size = LayoutSize(width: Double(bounds.width), height: Double(bounds.height))
            host.scale = Double(window?.backingScaleFactor ?? 1)
            host.direction =
                userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(
                    host.root,
                    in: hostedLayer,
                    scale: host.scale,
                    animation: host.renderAnimation
                )
                host.didRender()
                accessibilityCache = nil
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
            if widthChanged {
                // The height the tree wants depends on the width it has.
                invalidateIntrinsicContentSize()
            }
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        /// The view is a container: its elements are the tree's.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func isAccessibilityElement() -> Bool {
            false
        }

        /// The tree's accessibility elements (`NodeHost.accessibilityItems()`), rebuilt after
        /// every drawing.
        ///
        /// Ownership: the view keeps the elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func accessibilityChildren() -> [Any]? {
            if let accessibilityCache { return accessibilityCache }

            let elements = host.accessibilityItems().map {
                NodeAccessibilityElement(parent: self, item: $0)
            }
            accessibilityCache = elements
            return elements
        }

        /// No width of its own — the surroundings give it one (constraints, SwiftUI, a
        /// frame), as for a paragraph of text — and the height the tree takes at the current
        /// width. A tree's widest content is a poor width to ask for: one long line of text
        /// can make it wider than the window.
        public override var intrinsicContentSize: CGSize {
            let width =
                bounds.width > 0 ? AvailableSpace.definite(Double(bounds.width)) : .maxContent
            return CGSize(
                width: NSView.noIntrinsicMetric,
                height: host.fittingSize(width: width).height
            )
        }

        /// Presses on nodes with `onTap`; other clicks go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseDown(with event: NSEvent) {
            if !host.pointerDown(at: point(of: event)) {
                super.mouseDown(with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseUp(with event: NSEvent) {
            host.pointerUp(at: point(of: event))
            super.mouseUp(with: event)
        }

        /// A click on an inactive window also reaches the nodes.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        private func point(of event: NSEvent) -> LayoutPoint {
            // The view is flipped, so the point is measured from the top left.
            let location = convert(event.locationInWindow, from: nil)
            return LayoutPoint(x: Double(location.x), y: Double(location.y))
        }

        /// The layer drawing `node`, for tests and debugging.
        ///
        /// Ownership: returns a layer the view's renderer owns. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public func renderedLayer(for node: Node) -> CALayer? {
            renderer.layer(for: node)
        }
    }

    extension NSView {
        /// Shows `node` in a new `NodeNSView` added as a subview, and returns it for sizing
        /// and positioning.
        ///
        /// Ownership: the view keeps the new subview, which keeps the node. Isolation:
        /// MainActor. Errors: none. Cancellation: remove the subview and call
        /// `host.detach()`.
        @discardableResult
        public func addSubnode(_ node: Node) -> NodeNSView {
            let view = NodeNSView(root: node)
            addSubview(view)
            return view
        }
    }

    /// One accessibility element of a node tree. It keeps the node's identity and asks the
    /// host to act on it; it never holds the node itself.
    @MainActor
    final class NodeAccessibilityElement: NSAccessibilityElement {
        private let node: NodeID
        private weak var host: NodeHost?

        init(parent: NodeNSView, item: AccessibilityItem) {
            node = item.node
            host = parent.host
            super.init()
            setAccessibilityParent(parent)
            setAccessibilityLabel(item.label)
            setAccessibilityValue(item.value)
            setAccessibilityHelp(item.hint)
            setAccessibilityRole(NodeAccessibilityElement.role(item.traits))
            setAccessibilitySelected(item.traits.contains(.selected))
            setAccessibilityEnabled(!item.traits.contains(.notEnabled))
            setAccessibilityFrameInParentSpace(
                NSRect(
                    x: item.frame.origin.x,
                    y: item.frame.origin.y,
                    width: item.frame.size.width,
                    height: item.frame.size.height
                )
            )
        }

        override func accessibilityPerformPress() -> Bool {
            host?.activate(node) ?? false
        }

        private static func role(_ traits: AccessibilityTraits) -> NSAccessibility.Role {
            if traits.contains(.button) { return .button }
            if traits.contains(.image) { return .image }
            if traits.contains(.staticText) || traits.contains(.header) { return .staticText }
            return .group
        }
    }
#endif
