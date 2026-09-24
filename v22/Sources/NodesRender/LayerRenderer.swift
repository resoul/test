#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import QuartzCore

    /// A node that draws its own content (text, a shape) into its layer.
    ///
    /// Ownership: the node owns what it draws. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public protocol LayerDrawing: AnyObject {
        /// Grows whenever what `draw` produces changes; the renderer redraws only then (or
        /// when the size or scale changes).
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: none.
        var drawingRevision: UInt64 { get }

        /// Draws the content in a box of `size` points whose origin is at the bottom left,
        /// as Core Graphics expects.
        ///
        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        func draw(in context: CGContext, size: CGSize)
    }

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
        private var drawn: [NodeID: Drawing] = [:]

        /// What a layer's contents were drawn from.
        private struct Drawing: Equatable {
            let revision: UInt64
            let size: CGSize
            let scale: Double
        }

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
        /// into `container`. Drawn content is rendered for `scale` pixels per point. Frames grow downward, so `container` must have its origin at the
        /// top left (a UIKit view's layer does; an AppKit one needs `isGeometryFlipped`).
        /// Changes are not animated.
        ///
        /// Ownership: updates layers the renderer owns and adds one sublayer to `container`.
        /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func render(_ root: Node, in container: CALayer, scale: Double = 1) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            var visited: Set<NodeID> = []
            var drawings: [(node: Node, drawing: any LayerDrawing, layer: CALayer)] = []
            let rootLayer = sync(root, visited: &visited, drawings: &drawings)
            if rootLayer.superlayer !== container {
                container.addSublayer(rootLayer)
            }

            for entry in drawings {
                draw(entry.drawing, of: entry.node, into: entry.layer, scale: scale)
            }

            let gone = layers.keys.filter { !visited.contains($0) }
            for id in gone {
                layers[id]?.removeFromSuperlayer()
                layers[id] = nil
                drawn[id] = nil
            }
        }

        private func sync(
            _ node: Node,
            visited: inout Set<NodeID>,
            drawings: inout [(node: Node, drawing: any LayerDrawing, layer: CALayer)]
        ) -> CALayer {
            visited.insert(node.id)
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
            if let drawing = node as? any LayerDrawing {
                drawings.append((node, drawing, layer))
            }

            var sublayers: [CALayer] = []
            for subnode in node.subnodes {
                sublayers.append(sync(subnode, visited: &visited, drawings: &drawings))
            }
            if !(layer.sublayers ?? []).elementsEqual(sublayers, by: ===) {
                layer.sublayers = sublayers.isEmpty ? nil : sublayers
            }
            return layer
        }

        /// Draws `drawing` into a bitmap that becomes the layer's contents, unless the
        /// contents already show this revision at this size and scale.
        private func draw(
            _ drawing: any LayerDrawing,
            of node: Node,
            into layer: CALayer,
            scale: Double
        ) {
            let size = CGSize(width: node.frame.size.width, height: node.frame.size.height)
            let wanted = Drawing(revision: drawing.drawingRevision, size: size, scale: scale)
            guard drawn[node.id] != wanted else { return }

            drawn[node.id] = wanted
            let pixelWidth = Int((Double(size.width) * scale).rounded(.up))
            let pixelHeight = Int((Double(size.height) * scale).rounded(.up))
            guard pixelWidth > 0, pixelHeight > 0,
                let context = CGContext(
                    data: nil,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            else {
                layer.contents = nil
                return
            }

            // An image in `contents` is shown as it is, top row at the top, whatever the
            // geometry of the layers around it — so it is drawn upright.
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            drawing.draw(in: context, size: size)
            layer.contentsScale = CGFloat(scale)
            layer.contents = context.makeImage()
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
