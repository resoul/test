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
        private var accessibilityCache: [UIAccessibilityElement]?

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
                renderer.render(host.root, in: layer, scale: host.scale)
                host.didRender()
                accessibilityCache = nil
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

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
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
