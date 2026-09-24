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
        private var isLayingOut = false

        /// A view showing `root`.
        ///
        /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(root: Node) {
            host = NodeHost(root: root, size: LayoutSize(width: 0, height: 0))
            super.init(frame: .zero)
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

            host.size = LayoutSize(width: Double(bounds.width), height: Double(bounds.height))
            host.scale = Double(traitCollection.displayScale > 0 ? traitCollection.displayScale : 1)
            host.direction =
                effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(host.root, in: layer, scale: host.scale)
                host.didRender()
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

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var intrinsicContentSize: CGSize {
            let fitting = host.fittingSize(width: .maxContent)
            return CGSize(width: fitting.width, height: fitting.height)
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
#endif
