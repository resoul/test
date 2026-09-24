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
    /// A render with an animation moves every layer from what it shows now — midway through
    /// an earlier animation too — to the new frame and appearance. A node that comes into a
    /// tree already on screen fades in, and one that leaves it fades out where it was; a
    /// hidden node fades out as well. Drawn content (text) is not animated: it changes at
    /// once and keeps its size while the frame moves.
    ///
    /// Ownership: the renderer owns the layers it creates; layers of nodes no longer mounted
    /// are removed from their superlayers and released, after their fade when animated.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @MainActor
    public final class LayerRenderer {
        private var layers: [NodeID: CALayer] = [:]
        private var drawn: [NodeID: Drawing] = [:]
        /// Layers of nodes that left in an animated render, fading out in place. They are
        /// dropped at the first render after their fade is over.
        private var leaving: [NodeID: CALayer] = [:]

        /// What a layer's contents were drawn from.
        private struct Drawing: Equatable {
            let revision: UInt64
            let size: CGSize
            let scale: Double
        }

        /// The state of one render: what it visited, what it has to draw, and the layers it
        /// took out of their superlayers.
        private struct Pass {
            let animation: Animation?
            var visited: Set<NodeID> = []
            var drawings: [(node: Node, drawing: any LayerDrawing, layer: CALayer)] = []
            var detached: [(layer: CALayer, superlayer: CALayer, index: Int)] = []
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
        /// into `container`. Drawn content is rendered for `scale` pixels per point. Frames
        /// grow downward, so `container` must have its origin at the top left (a UIKit view's
        /// layer does; an AppKit one needs `isGeometryFlipped`). With `animation`, the changes
        /// move with it (usually `NodeHost.renderAnimation`); without, they show at once.
        ///
        /// Ownership: updates layers the renderer owns and adds one sublayer to `container`.
        /// Isolation: MainActor. Errors: none. Cancellation: a later render replaces the
        /// animations it started.
        public func render(
            _ root: Node,
            in container: CALayer,
            scale: Double = 1,
            animation: Animation? = nil
        ) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            var pass = Pass(animation: animation)
            let rootLayer = sync(root, parentIsNew: true, pass: &pass)
            if rootLayer.superlayer !== container {
                container.addSublayer(rootLayer)
            }

            for entry in pass.drawings {
                draw(entry.drawing, of: entry.node, into: entry.layer, scale: scale)
            }

            var gone: [ObjectIdentifier: NodeID] = [:]
            for id in layers.keys where !pass.visited.contains(id) {
                if let layer = layers.removeValue(forKey: id) {
                    gone[ObjectIdentifier(layer)] = id
                }
                drawn[id] = nil
            }
            settle(pass.detached, gone: gone, animation: animation)
        }

        private func sync(_ node: Node, parentIsNew: Bool, pass: inout Pass) -> CALayer {
            pass.visited.insert(node.id)
            var isNew = false
            var cameBack = false
            let layer: CALayer
            if let existing = layers[node.id] {
                layer = existing
            } else if let fading = leaving.removeValue(forKey: node.id) {
                layer = fading
                layers[node.id] = fading
                cameBack = true
            } else {
                layer = CALayer()
                layers[node.id] = layer
                isNew = true
            }

            let before: (model: Look, shown: Look)? =
                isNew ? nil : (Look(layer), Look(presentedBy: layer))
            // Position and bounds rather than `frame`, which a scale transform would distort.
            let frame = node.frame
            layer.bounds = CGRect(x: 0, y: 0, width: frame.size.width, height: frame.size.height)
            layer.position = CGPoint(
                x: frame.origin.x + frame.size.width / 2,
                y: frame.origin.y + frame.size.height / 2
            )
            apply(node.appearance, to: layer)
            applyVisibility(of: node, to: layer, isNew: isNew, animated: pass.animation != nil)
            if let drawing = node as? any LayerDrawing {
                // The content keeps its size while the frame animates, instead of being
                // stretched with it.
                layer.contentsGravity = .left
                pass.drawings.append((node, drawing, layer))
            }

            if let before {
                transition(
                    layer,
                    from: before.model,
                    shown: before.shown,
                    animation: pass.animation
                )
            } else if let animation = pass.animation, !parentIsNew, !layer.isHidden {
                let fadeIn = makeAnimation(
                    "opacity",
                    from: Float(0),
                    to: layer.opacity,
                    animation
                )
                layer.add(fadeIn, forKey: "opacity")
            }

            var sublayers: [CALayer] = []
            for subnode in node.subnodes {
                sublayers.append(
                    sync(subnode, parentIsNew: isNew || cameBack, pass: &pass)
                )
            }
            let current = layer.sublayers ?? []
            if !current.elementsEqual(sublayers, by: ===) {
                let kept = Set(sublayers.map(ObjectIdentifier.init))
                for (index, sublayer) in current.enumerated()
                where !kept.contains(ObjectIdentifier(sublayer)) {
                    pass.detached.append((sublayer, layer, index))
                }
                layer.sublayers = sublayers.isEmpty ? nil : sublayers
            }
            return layer
        }

        /// A hidden node's layer is hidden — after fading out, when the render is animated
        /// or the fade is already running.
        private func applyVisibility(
            of node: Node,
            to layer: CALayer,
            isNew: Bool,
            animated: Bool
        ) {
            guard node.isHidden else {
                layer.isHidden = false
                return
            }
            guard !layer.isHidden else { return }

            if !isNew && (animated || layer.animation(forKey: "opacity") != nil) {
                layer.opacity = 0
            } else {
                layer.isHidden = true
            }
        }

        /// Decides what happens to the layers taken out of their superlayers by this render:
        /// a layer whose node left fades out where it was when the render is animated, and so
        /// does one still fading from before; any other is dropped.
        private func settle(
            _ detached: [(layer: CALayer, superlayer: CALayer, index: Int)],
            gone: [ObjectIdentifier: NodeID],
            animation: Animation?
        ) {
            var fading: [NodeID: CALayer] = [:]
            for entry in detached {
                let layer = entry.layer
                if let id = gone[ObjectIdentifier(layer)], let animation {
                    let from = Look(presentedBy: layer).opacity
                    layer.opacity = 0
                    let fadeOut = makeAnimation("opacity", from: from, to: Float(0), animation)
                    layer.add(fadeOut, forKey: "opacity")
                    fading[id] = layer
                } else if let id = leaving.first(where: { $0.value === layer })?.key,
                    layer.animation(forKey: "opacity") != nil
                {
                    fading[id] = layer
                } else {
                    continue
                }

                let count = entry.superlayer.sublayers?.count ?? 0
                entry.superlayer.insertSublayer(layer, at: UInt32(min(entry.index, count)))
            }
            // Fading layers inside a layer that was itself dropped go with it.
            leaving = fading
        }

        /// For every property of `layer` whose value differs from `before`, animates from what
        /// was `shown`; without an animation, stops the animation running on it so the new value
        /// shows. A property that did not change keeps the animation it has.
        private func transition(
            _ layer: CALayer,
            from before: Look,
            shown: Look,
            animation: Animation?
        ) {
            let after = Look(layer)
            func change(_ key: String, _ from: Any, _ to: Any, changed: Bool) {
                guard changed else { return }

                if let animation {
                    layer.add(makeAnimation(key, from: from, to: to, animation), forKey: key)
                } else {
                    layer.removeAnimation(forKey: key)
                }
            }

            change(
                "position",
                shown.position,
                after.position,
                changed: before.position != after.position
            )
            change("bounds", shown.bounds, after.bounds, changed: before.bounds != after.bounds)
            change(
                "opacity",
                shown.opacity,
                after.opacity,
                changed: before.opacity != after.opacity
            )
            change(
                "cornerRadius",
                shown.cornerRadius,
                after.cornerRadius,
                changed: before.cornerRadius != after.cornerRadius
            )
            change(
                "borderWidth",
                shown.borderWidth,
                after.borderWidth,
                changed: before.borderWidth != after.borderWidth
            )
            change(
                "transform",
                shown.transform,
                after.transform,
                changed: !CATransform3DEqualToTransform(before.transform, after.transform)
            )
            change(
                "shadowOpacity",
                shown.shadowOpacity,
                after.shadowOpacity,
                changed: before.shadowOpacity != after.shadowOpacity
            )
            change(
                "shadowRadius",
                shown.shadowRadius,
                after.shadowRadius,
                changed: before.shadowRadius != after.shadowRadius
            )
            change(
                "shadowOffset",
                shown.shadowOffset,
                after.shadowOffset,
                changed: before.shadowOffset != after.shadowOffset
            )
            let colors = [
                (
                    "backgroundColor", before.backgroundColor, shown.backgroundColor,
                    after.backgroundColor
                ),
                ("borderColor", before.borderColor, shown.borderColor, after.borderColor),
                ("shadowColor", before.shadowColor, shown.shadowColor, after.shadowColor),
            ]
            for (key, old, from, to) in colors where !Look.same(old, to) {
                // No color is the other color, transparent: it fades rather than jumps.
                if let fromColor = from ?? to?.copy(alpha: 0),
                    let toColor = to ?? from?.copy(alpha: 0)
                {
                    change(key, fromColor, toColor, changed: true)
                } else {
                    layer.removeAnimation(forKey: key)
                }
            }
        }

        private func makeAnimation(
            _ key: String,
            from: Any,
            to: Any,
            _ animation: Animation
        ) -> CABasicAnimation {
            let result: CABasicAnimation
            switch animation.curve {
            case .spring(let response, let dampingRatio):
                let spring = CASpringAnimation(keyPath: key)
                spring.mass = 1
                spring.stiffness = CGFloat((2 * Double.pi / response) * (2 * Double.pi / response))
                spring.damping = CGFloat(4 * Double.pi * dampingRatio / response)
                result = spring
            case .linear:
                result = CABasicAnimation(keyPath: key)
                result.timingFunction = CAMediaTimingFunction(name: .linear)
            case .easeIn:
                result = CABasicAnimation(keyPath: key)
                result.timingFunction = CAMediaTimingFunction(name: .easeIn)
            case .easeOut:
                result = CABasicAnimation(keyPath: key)
                result.timingFunction = CAMediaTimingFunction(name: .easeOut)
            case .easeInOut:
                result = CABasicAnimation(keyPath: key)
                result.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            result.fromValue = from
            result.toValue = to
            result.duration = animation.duration
            return result
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
            layer.transform =
                appearance.scale == 1
                ? CATransform3DIdentity
                : CATransform3DMakeScale(CGFloat(appearance.scale), CGFloat(appearance.scale), 1)
            if let shadow = appearance.shadow {
                layer.shadowColor = cgColor(shadow.color)
                layer.shadowOpacity = Float(shadow.opacity)
                layer.shadowRadius = CGFloat(shadow.radius)
                layer.shadowOffset = CGSize(width: shadow.x, height: shadow.y)
            } else {
                // The color and geometry stay, so a shadow that goes away fades out in place.
                layer.shadowOpacity = 0
            }
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

    /// The animatable properties of a layer.
    @MainActor
    private struct Look {
        var position: CGPoint
        var bounds: CGRect
        var opacity: Float
        var cornerRadius: CGFloat
        var borderWidth: CGFloat
        var backgroundColor: CGColor?
        var borderColor: CGColor?
        var transform: CATransform3D
        var shadowOpacity: Float
        var shadowRadius: CGFloat
        var shadowOffset: CGSize
        var shadowColor: CGColor?

        /// The model values of `layer`: what it shows once its animations are over.
        init(_ layer: CALayer) {
            self.init(values: layer)
            if layer.isHidden {
                opacity = 0
            }
        }

        private init(values layer: CALayer) {
            position = layer.position
            bounds = layer.bounds
            opacity = layer.opacity
            cornerRadius = layer.cornerRadius
            borderWidth = layer.borderWidth
            backgroundColor = layer.backgroundColor
            borderColor = layer.borderColor
            transform = layer.transform
            shadowOpacity = layer.shadowOpacity
            shadowRadius = layer.shadowRadius
            shadowOffset = layer.shadowOffset
            shadowColor = layer.shadowColor
        }

        /// What `layer` shows right now: midway through its animations, if any run; nothing,
        /// if it is hidden.
        init(presentedBy layer: CALayer) {
            let isAnimating = !(layer.animationKeys() ?? []).isEmpty
            self.init(values: isAnimating ? layer.presentation() ?? layer : layer)
            if layer.isHidden {
                opacity = 0
            }
        }

        static func same(_ first: CGColor?, _ second: CGColor?) -> Bool {
            switch (first, second) {
            case (nil, nil): true
            case let (first?, second?): CFEqual(first, second)
            default: false
            }
        }
    }
#endif
