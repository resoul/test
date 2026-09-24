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

            host.size = LayoutSize(width: Double(bounds.width), height: Double(bounds.height))
            host.scale = Double(window?.backingScaleFactor ?? 1)
            host.direction =
                userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(host.root, in: hostedLayer, scale: host.scale)
                host.didRender()
            }
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var intrinsicContentSize: CGSize {
            let fitting = host.fittingSize(width: .maxContent)
            return CGSize(width: fitting.width, height: fitting.height)
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
#endif
