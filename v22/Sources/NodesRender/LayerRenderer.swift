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
        /// The scroll indicator of each scroll, the last sublayer of its layer.
        private var indicators: [NodeID: CALayer] = [:]
        /// The offset each scroll was drawn at, to show the indicator when it moves.
        private var drawnOffsets: [NodeID: LayoutPoint] = [:]
        /// The sticky nodes inside each scroll at the last render: they move when it scrolls.
        private var stickyNodes: [NodeID: [Node]] = [:]

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
            /// The layer the tree is rendered into: coordinates of the pass start there.
            let container: CALayer
            var visited: Set<NodeID> = []
            var drawings: [(node: Node, drawing: any LayerDrawing, layer: CALayer)] = []
            var detached: [(layer: CALayer, superlayer: CALayer, index: Int)] = []
            /// Where the coordinate space of each layer handled so far starts, in the root's
            /// superlayer, as it was shown before this render.
            var shownOrigins: [ObjectIdentifier: CGPoint] = [:]
            /// The superlayers layers were taken out of during this render.
            var formerSuperlayers: [ObjectIdentifier: CALayer] = [:]
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

            var pass = Pass(animation: animation, container: container)
            stickyNodes = [:]
            let rootLayer = sync(root, pass: &pass)
            if rootLayer.superlayer !== container {
                container.addSublayer(rootLayer)
            }

            for entry in pass.drawings {
                draw(
                    entry.drawing,
                    of: entry.node,
                    into: entry.layer,
                    scale: scale,
                    animation: animation
                )
            }

            var gone: [ObjectIdentifier: NodeID] = [:]
            for id in layers.keys where !pass.visited.contains(id) {
                if let layer = layers.removeValue(forKey: id) {
                    gone[ObjectIdentifier(layer)] = id
                }
                drawn[id] = nil
                indicators[id] = nil
                drawnOffsets[id] = nil
            }
            settle(pass.detached, gone: gone, animation: animation)
        }

        /// Moves the content of `scrolls` to their offsets, and shows their indicators, without
        /// drawing anything else — for `NodeHost.scrolledSinceRender`, many times a second
        /// while a finger drags. The scrolls must have been drawn by a render before.
        ///
        /// Ownership: updates layers the renderer owns. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public func renderScrolls(_ scrolls: [Scroll]) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            for scroll in scrolls {
                guard let layer = layers[scroll.id] else { continue }

                let offset = scroll.shownOffset
                layer.removeAnimation(forKey: "bounds")
                layer.bounds.origin = CGPoint(x: offset.x, y: offset.y)
                updateIndicator(of: scroll, in: layer)
                for node in stickyNodes[scroll.id] ?? [] {
                    guard let sticky = layers[node.id] else { continue }

                    sticky.removeAnimation(forKey: "position")
                    sticky.position = LayerRenderer.position(of: node)
                }
            }
        }

        /// A node whose layer is in line, while the layers of its subnodes are brought in line.
        private struct Level {
            let layer: CALayer
            /// Drawn over the subnodes' layers, last.
            let indicator: CALayer?
            let subnodes: [Node]
            /// The subnodes' layers appear with this one: they do not fade in by themselves.
            let subnodesAreNew: Bool
            var next = 0
            var sublayers: [CALayer] = []
        }

        /// Brings the layers of `root` and everything under it in line with the nodes, and
        /// returns the root's layer. A loop over an explicit stack rather than recursion: it
        /// runs on the main thread, whose stack is small on a phone, and a tree can be deeper
        /// than it allows. Each node is handled before its subnodes and its sublayers are set
        /// after them, as a recursive walk would.
        private func sync(_ root: Node, pass: inout Pass) -> CALayer {
            var levels = [enter(root, parent: nil, parentIsNew: true, pass: &pass)]
            while true {
                let top = levels.count - 1
                if levels[top].next < levels[top].subnodes.count {
                    let subnode = levels[top].subnodes[levels[top].next]
                    levels[top].next += 1
                    levels.append(
                        enter(
                            subnode,
                            parent: levels[top].layer,
                            parentIsNew: levels[top].subnodesAreNew,
                            pass: &pass
                        )
                    )
                    continue
                }

                let done = levels.removeLast()
                attach(
                    done.sublayers + (done.indicator.map { [$0] } ?? []),
                    to: done.layer,
                    pass: &pass
                )
                guard let parent = levels.indices.last else { return done.layer }

                levels[parent].sublayers.append(done.layer)
            }
        }

        /// Brings the layer of `node` itself in line: frame, appearance, visibility, and the
        /// animation from what it showed. `parent` is the layer it goes into — the parent
        /// node's, already in line — or `nil` for the root's.
        private func enter(
            _ node: Node,
            parent: CALayer?,
            parentIsNew: Bool,
            pass: inout Pass
        ) -> Level {
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

            var before: (model: Look, shown: Look)? =
                isNew ? nil : (Look(layer), Look(presentedBy: layer))
            let oldParent = layer.superlayer ?? pass.formerSuperlayers[ObjectIdentifier(layer)]
            let oldParentOrigin = oldParent.map { shownOrigin(of: $0, pass: pass) } ?? .zero
            if let shown = before?.shown {
                pass.shownOrigins[ObjectIdentifier(layer)] = LayerRenderer.origin(
                    of: shown,
                    in: oldParentOrigin
                )
            }
            // Position and bounds rather than `frame`, which a scale transform would distort. A
            // scroll's bounds start at its offset, which moves its sublayers back by it.
            let frame = node.frame
            let scroll = node as? Scroll
            let offset = scroll?.shownOffset ?? .zero
            layer.bounds = CGRect(
                x: offset.x,
                y: offset.y,
                width: frame.size.width,
                height: frame.size.height
            )
            layer.position = LayerRenderer.position(of: node)
            apply(node.appearance, to: layer)
            applyVisibility(of: node, to: layer, isNew: isNew, animated: pass.animation != nil)
            if let drawing = node as? any LayerDrawing {
                // The content keeps its size while the frame animates, instead of being
                // stretched with it.
                layer.contentsGravity = .left
                pass.drawings.append((node, drawing, layer))
            }

            if isNew || before == nil {
                pass.shownOrigins[ObjectIdentifier(layer)] = LayerRenderer.origin(
                    of: Look(layer),
                    in: parent.map { shownOrigin(of: $0, pass: pass) } ?? .zero
                )
            }
            if let parent, let oldParent, oldParent !== parent, var moved = before {
                // A node that moved to another parent starts where it was shown, in the
                // coordinates of the parent it moves into.
                let newParentOrigin = shownOrigin(of: parent, pass: pass)
                moved.shown.position.x += oldParentOrigin.x - newParentOrigin.x
                moved.shown.position.y += oldParentOrigin.y - newParentOrigin.y
                moved.model.position = moved.shown.position
                before = moved
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

            var indicator: CALayer?
            if let scroll {
                indicator = updateIndicator(of: scroll, in: layer)
            }
            if node.sticky != nil, let scroll = node.enclosingScroll {
                stickyNodes[scroll.id, default: []].append(node)
            }
            return Level(
                layer: layer,
                indicator: indicator,
                subnodes: node.subnodesInDrawingOrder,
                subnodesAreNew: isNew || cameBack
            )
        }

        /// The center of the node's layer in its supernode's: its frame's, moved by where it
        /// sticks.
        private static func position(of node: Node) -> CGPoint {
            let frame = node.frame
            let offset = node.stickyOffset
            return CGPoint(
                x: frame.origin.x + offset.x + frame.size.width / 2,
                y: frame.origin.y + offset.y + frame.size.height / 2
            )
        }

        /// Where the coordinate space of `layer` starts, as shown before this render: recorded
        /// when the render handled it, else summed up its superlayers.
        private func shownOrigin(of layer: CALayer, pass: Pass) -> CGPoint {
            var chain: [CALayer] = []
            var current: CALayer? = layer
            var base = CGPoint.zero
            while let next = current, next !== pass.container {
                if let known = pass.shownOrigins[ObjectIdentifier(next)] {
                    base = known
                    break
                }

                chain.append(next)
                current = next.superlayer
            }
            for next in chain.reversed() {
                base = LayerRenderer.origin(of: Look(presentedBy: next), in: base)
            }
            return base
        }

        /// The start of the coordinate space of a layer showing `look` inside a superlayer
        /// whose own space starts at `base`.
        private static func origin(of look: Look, in base: CGPoint) -> CGPoint {
            CGPoint(
                x: base.x + look.position.x - look.bounds.width / 2 - look.bounds.minX,
                y: base.y + look.position.y - look.bounds.height / 2 - look.bounds.minY
            )
        }

        /// Puts `sublayers` into `layer` in that order; layers taken out go to `pass.detached`.
        private func attach(_ sublayers: [CALayer], to layer: CALayer, pass: inout Pass) {
            let current = layer.sublayers ?? []
            if !current.elementsEqual(sublayers, by: ===) {
                let kept = Set(sublayers.map(ObjectIdentifier.init))
                for (index, sublayer) in current.enumerated()
                where !kept.contains(ObjectIdentifier(sublayer)) {
                    pass.detached.append((sublayer, layer, index))
                    pass.formerSuperlayers[ObjectIdentifier(sublayer)] = layer
                }
                layer.sublayers = sublayers.isEmpty ? nil : sublayers
            }
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
        /// contents already show this revision at this size and scale. With `animation`, new
        /// content — a new revision, not the same content at a new size — fades in over what
        /// was shown; without one it shows at once, stopping such a fade.
        private func draw(
            _ drawing: any LayerDrawing,
            of node: Node,
            into layer: CALayer,
            scale: Double,
            animation: Animation?
        ) {
            if animation == nil {
                layer.removeAnimation(forKey: "contents")
            }
            let size = CGSize(width: node.frame.size.width, height: node.frame.size.height)
            let wanted = Drawing(revision: drawing.drawingRevision, size: size, scale: scale)
            let before = drawn[node.id]
            guard before != wanted else { return }

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
            let shown = layer.contents
            let image = context.makeImage()
            layer.contentsScale = CGFloat(scale)
            layer.contents = image
            if let animation, let before, before.revision != wanted.revision, let shown,
                let image
            {
                // A spring would overshoot a cross-fade: the fade keeps the timing, eased.
                let curve =
                    if case .spring = animation.curve {
                        Animation.easeInOut(duration: animation.duration)
                    } else {
                        animation
                    }
                layer.add(
                    makeAnimation("contents", from: shown, to: image, curve),
                    forKey: "contents"
                )
            }
        }

        /// Places the indicator of `scroll` along its trailing (or bottom) edge where its offset
        /// is between the ends, and shows it for a moment when the offset moved since it was
        /// last drawn. It lives in the scroll's layer, whose coordinates start at the offset.
        @discardableResult
        private func updateIndicator(of scroll: Scroll, in layer: CALayer) -> CALayer {
            let indicator = indicators[scroll.id] ?? makeIndicator(for: scroll)
            let offset = scroll.contentOffset
            // The layer's coordinates start where it shows, past the ends while it bounces.
            let base = scroll.shownOffset
            let range = scroll.offsetRange
            let content = scroll.contentBounds
            let size = scroll.frame.size
            let thickness = 3.0
            let inset = 3.0
            let vertical = scroll.axis == .vertical
            let window = vertical ? size.height : size.width
            let length = vertical ? content.size.height : content.size.width
            let track = max(0, window - 2 * inset)
            let bar = min(track, max(36, track * window / max(length, 1)))
            let travel =
                vertical ? range.highest.y - range.lowest.y : range.highest.x - range.lowest.x
            let done = vertical ? offset.y - range.lowest.y : offset.x - range.lowest.x
            let along = inset + (travel > 0 ? (track - bar) * done / travel : 0)
            indicator.frame =
                vertical
                ? CGRect(
                    // Along the trailing edge: the left one right to left.
                    x: scroll.host?.direction == .rightToLeft
                        ? base.x + inset : base.x + size.width - inset - thickness,
                    y: base.y + along,
                    width: thickness,
                    height: bar
                )
                : CGRect(
                    x: base.x + along,
                    y: base.y + size.height - inset - thickness,
                    width: bar,
                    height: thickness
                )

            let moved = drawnOffsets[scroll.id].map { $0 != offset } ?? false
            drawnOffsets[scroll.id] = offset
            if moved, scroll.canScroll {
                // Shown while the offset keeps moving, then faded out: each move starts the
                // animation over, so no timer has to hide it.
                let flash = CAKeyframeAnimation(keyPath: "opacity")
                flash.values = [Float(1), Float(1), Float(0)]
                flash.keyTimes = [0, 0.6, 1]
                flash.duration = 1.2
                indicator.add(flash, forKey: "opacity")
            }
            return indicator
        }

        private func makeIndicator(for scroll: Scroll) -> CALayer {
            let indicator = CALayer()
            indicator.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.4)
            indicator.cornerRadius = 1.5
            indicator.opacity = 0
            indicators[scroll.id] = indicator
            return indicator
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
