#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import QuartzCore

    /// Draws a tree of nodes as a tree of `CALayer`s: one layer per mounted node, framed by the
    /// node's frame, styled by its appearance, with the layers of its subnodes as sublayers in
    /// the same order. The same renderer serves UIKit and AppKit.
    ///
    /// Ownership: the renderer owns the layers it creates; layers of nodes no longer mounted
    /// are removed from their superlayers and released. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public final class LayerRenderer {
        private var layers: [NodeID: CALayer] = [:]

        /// Ownership: the caller owns the renderer. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init() {}

        /// The layer drawing `node`, if it has been rendered.
        ///
        /// Ownership: returns a layer the renderer owns. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public func layer(for node: Node) -> CALayer? {
            layers[node.id]
        }

        /// Brings the layers in line with the tree under `root`, and puts the root's layer
        /// into `container`. Frames grow downward, so `container` must have its origin at the
        /// top left (a UIKit view's layer does; an AppKit one needs `isGeometryFlipped`).
        /// Changes are not animated.
        ///
        /// Ownership: updates layers the renderer owns and adds one sublayer to `container`.
        /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func render(_ root: Node, in container: CALayer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            var drawn: Set<NodeID> = []
            let rootLayer = sync(root, drawn: &drawn)
            if rootLayer.superlayer !== container {
                container.addSublayer(rootLayer)
            }

            let gone = layers.keys.filter { !drawn.contains($0) }
            for id in gone {
                layers[id]?.removeFromSuperlayer()
                layers[id] = nil
            }
        }

        private func sync(_ node: Node, drawn: inout Set<NodeID>) -> CALayer {
            drawn.insert(node.id)
            let layer = layers[node.id] ?? makeLayer(for: node)
            let frame = node.frame
            layer.frame = CGRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
            layer.isHidden = node.isHidden
            apply(node.appearance, to: layer)

            var sublayers: [CALayer] = []
            for subnode in node.subnodes {
                sublayers.append(sync(subnode, drawn: &drawn))
            }
            if !(layer.sublayers ?? []).elementsEqual(sublayers, by: ===) {
                layer.sublayers = sublayers.isEmpty ? nil : sublayers
            }
            return layer
        }

        private func makeLayer(for node: Node) -> CALayer {
            let layer = CALayer()
            layers[node.id] = layer
            return layer
        }

        private func apply(_ appearance: Appearance, to layer: CALayer) {
            layer.backgroundColor = appearance.background.map(cgColor)
            layer.cornerRadius = CGFloat(appearance.cornerRadius)
            layer.borderWidth = CGFloat(appearance.borderWidth)
            layer.borderColor = appearance.borderColor.map(cgColor)
            layer.opacity = Float(appearance.opacity)
            layer.masksToBounds = appearance.clipsContent
        }

        private func cgColor(_ color: Color) -> CGColor {
            CGColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
        }
    }
#endif
