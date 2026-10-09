#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import Tracing
    import ThemeCore
    import QuartzCore

    /// A node that draws its own content (text, a shape) into its layer.
    ///
    /// Ownership: the node owns what it draws. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public protocol LayerDrawing: AnyObject {
        /// Lets a drawing prepare the pixels needed for this size and display scale. A later
        /// result requests another render; drawing can use its current pixels meanwhile.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: the drawing
        /// owns any work it starts.
        func prepareDrawing(size: CGSize, scale: Double)

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

        /// An image the layer can show as it is, instead of a drawing, or `nil` to draw. The
        /// layer then references the image and keeps no bitmap of its own: a decoded photo is
        /// held once, not again at the frame's size. `drawingRevision` still marks changes.
        ///
        /// Ownership: returns a reference to an image the drawing holds. Isolation:
        /// MainActor. Errors: none. Cancellation: none.
        var layerImage: LayerImage? { get }
    }

    /// A node that shows a layer of its own — a video's surface — inside its frame. The
    /// renderer puts the layer into the node's layer beneath the layers of the node's
    /// subnodes, sized to the frame, so that a placeholder or a caption is an ordinary subnode
    /// drawn over it, and the clipping, corner radius, opacity and scrolling of the tree apply
    /// to it as to any node's content.
    ///
    /// Ownership: the node owns the layer for as long as it lives, and returns the same one
    /// each time. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @MainActor
    public protocol LayerHosting: AnyObject {
        /// The layer to show in the node's frame, or `nil` for none.
        ///
        /// Ownership: the node owns it. Isolation: MainActor. Errors: none. Cancellation:
        /// none.
        var hostedLayer: CALayer? { get }
    }

    extension LayerDrawing {
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public func prepareDrawing(size: CGSize, scale: Double) {}

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public var layerImage: LayerImage? { nil }
    }

    /// An image shown as a layer's contents, placed in the frame by `contentMode`.
    ///
    /// Ownership: value holding a shared image. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public struct LayerImage: Sendable {
        /// Ownership: shared reference. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public var image: CGImage
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var contentMode: ImageContentMode

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(image: CGImage, contentMode: ImageContentMode) {
            self.image = image
            self.contentMode = contentMode
        }
    }

    /// Draws a tree of nodes as a tree of `CALayer`s: one layer per mounted node, framed by the
    /// node's frame, styled by its appearance, with the layers of its subnodes as sublayers in
    /// the same order. The same renderer serves UIKit and AppKit.
    ///
    /// A render with an animation moves every layer from what it shows now — midway through
    /// an earlier animation too — to the new frame and appearance. A node that comes into a
    /// tree already on screen comes in the way its `transition` says — fades in, by default
    /// — and one that leaves it goes out that way from where it was; a node hidden or shown
    /// again does the same. Drawn content (text) is not animated: it changes at
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
        /// The transition of each node rendered, for when it leaves: the node is gone by then.
        private var transitions: [NodeID: Transition] = [:]

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
            /// The tree is laid out from the right: leading is right.
            let rightToLeft: Bool
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

            var pass = Pass(
                animation: animation,
                rightToLeft: root.host?.direction == .rightToLeft,
                container: container
            )
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
                    scale: scale * LayerRenderer.zoom(of: entry.node),
                    animation: animation
                )
            }

            var gone: [ObjectIdentifier: (id: NodeID, transition: Transition)] = [:]
            for id in layers.keys where !pass.visited.contains(id) {
                if let layer = layers.removeValue(forKey: id) {
                    gone[ObjectIdentifier(layer)] = (id, transitions[id] ?? .opacity)
                }
                transitions[id] = nil
                drawn[id] = nil
                indicators[id] = nil
                drawnOffsets[id] = nil
            }
            settle(pass.detached, gone: gone, pass: pass)
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
            /// Drawn under the subnodes' layers, first (`LayerHosting`).
            let hosted: CALayer?
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
                    (done.hosted.map { [$0] } ?? []) + done.sublayers
                        + (done.indicator.map { [$0] } ?? []),
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
            transitions[node.id] = node.transition
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
            if let hosted = (node as? any LayerHosting)?.hostedLayer {
                // Sized to the frame at once: the tree animates the node's own layer, and the
                // hosted layer inside it follows.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hosted.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: frame.size.width,
                    height: frame.size.height
                )
                CATransaction.commit()
            }
            apply(node.appearance, to: layer)
            if let scroll = node.supernode as? Scroll, scroll.zoomScale != 1 {
                // Zoomed content is drawn bigger from the content's origin: its center moves
                // out as far as it grows.
                let zoom = CGFloat(scroll.zoomScale)
                layer.position = CGPoint(x: layer.position.x * zoom, y: layer.position.y * zoom)
                layer.transform = CATransform3DConcat(
                    layer.transform,
                    CATransform3DMakeScale(zoom, zoom, 1)
                )
            }
            let wasHidden = layer.isHidden
            let startsHiding = applyVisibility(of: node, to: layer, isNew: isNew, pass: pass)
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
                if let animation = pass.animation {
                    if wasHidden && !layer.isHidden {
                        // Shown again: it comes in as a node coming into the tree does.
                        comeIn(layer, node.transition, animation, pass: pass, replacing: true)
                    } else if startsHiding {
                        goOut(
                            layer,
                            node.transition.removal,
                            node.transition.animation ?? animation,
                            shown: before.shown,
                            pass: pass
                        )
                    }
                }
            } else if let animation = pass.animation, !parentIsNew, !layer.isHidden {
                comeIn(layer, node.transition, animation, pass: pass, replacing: false)
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
                hosted: (node as? any LayerHosting)?.hostedLayer,
                indicator: indicator,
                subnodes: node.subnodesInDrawingOrder,
                subnodesAreNew: isNew || cameBack
            )
        }

        /// How many times bigger than laid out the scrolls around `node` draw it: content
        /// zoomed in is drawn for as many more pixels, so that text stays sharp.
        private static func zoom(of node: Node) -> Double {
            var zoom = 1.0
            var current = node.supernode
            while let supernode = current {
                zoom *= (supernode as? Scroll)?.zoomScale ?? 1
                current = supernode.supernode
            }
            return zoom
        }

        /// The center of the node's layer in its supernode's: its frame's, moved by where it
        /// sticks and by its appearance's offset.
        private static func position(of node: Node) -> CGPoint {
            let frame = node.frame
            let offset = node.stickyOffset
            let moved = node.appearance.offset
            return CGPoint(
                x: frame.origin.x + offset.x + moved.x + frame.size.width / 2,
                y: frame.origin.y + offset.y + moved.y + frame.size.height / 2
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

        /// A hidden node's layer is hidden — after going out the way its transition says,
        /// when the render is animated or the node is already on its way out. Returns whether
        /// it starts going out in this render.
        private func applyVisibility(
            of node: Node,
            to layer: CALayer,
            isNew: Bool,
            pass: Pass
        ) -> Bool {
            guard node.isHidden else {
                layer.isHidden = false
                return false
            }
            guard !layer.isHidden else { return false }

            let goingOut = layer.animation(forKey: "opacity") != nil
            let effect = node.transition.removal
            if !isNew && (goingOut || (pass.animation != nil && !effect.isIdentity)) {
                // Where it goes out to, which the move animates to; it is hidden at the first
                // render after.
                layer.opacity = 0
                layer.transform = LayerRenderer.transform(
                    effect,
                    size: layer.bounds.size,
                    base: layer.transform,
                    rightToLeft: pass.rightToLeft
                )
                return !goingOut
            }
            layer.isHidden = true
            return false
        }

        /// Adds the animations that bring `layer`, new in a tree already shown or shown
        /// again, in from where `transition` has it away. `replacing` drops the fade in the
        /// render added for a layer shown again when the transition does not fade.
        private func comeIn(
            _ layer: CALayer,
            _ transition: Transition,
            _ animation: Animation,
            pass: Pass,
            replacing: Bool
        ) {
            let effect = transition.insertion
            let animation = transition.animation ?? animation
            if effect.opacity != 1 {
                let from = layer.opacity * Float(effect.opacity)
                layer.add(
                    makeAnimation("opacity", from: from, to: layer.opacity, animation),
                    forKey: "opacity"
                )
            } else if replacing {
                layer.removeAnimation(forKey: "opacity")
            }
            if effect.changesGeometry {
                let away = LayerRenderer.transform(
                    effect,
                    size: layer.bounds.size,
                    base: layer.transform,
                    rightToLeft: pass.rightToLeft
                )
                layer.add(
                    makeAnimation("transform", from: away, to: layer.transform, animation),
                    forKey: "transform"
                )
            }
        }

        /// Adds the animations that take `layer` out to where `effect` has it, from what it
        /// `shown`: its model is already there, and fully transparent, so it does not show
        /// once they are over. The opacity always animates, if only from a value to itself:
        /// a layer on its way out is one with that animation.
        private func goOut(
            _ layer: CALayer,
            _ effect: Transition.Effect,
            _ animation: Animation,
            shown: Look,
            pass: Pass
        ) {
            layer.opacity = 0
            layer.add(
                makeAnimation(
                    "opacity",
                    from: shown.opacity,
                    to: shown.opacity * Float(effect.opacity),
                    animation
                ),
                forKey: "opacity"
            )
            guard effect.changesGeometry else { return }

            layer.add(
                makeAnimation("transform", from: shown.transform, to: layer.transform, animation),
                forKey: "transform"
            )
        }

        /// `base` with `effect` applied after it, for a layer of `size`: the node as it is
        /// while away.
        static func transform(
            _ effect: Transition.Effect,
            size: CGSize,
            base: CATransform3D,
            rightToLeft: Bool
        ) -> CATransform3D {
            guard effect.changesGeometry else { return base }

            // Leading is on the right from the right: moves across, turns about the vertical
            // line and anchors across go the other way.
            let across: CGFloat = rightToLeft ? -1 : 1
            let anchorX = rightToLeft ? 1 - effect.anchor.x : effect.anchor.x
            let pivot = CGPoint(
                x: (CGFloat(anchorX) - 0.5) * size.width,
                y: (CGFloat(effect.anchor.y) - 0.5) * size.height
            )
            // Core Animation cannot take a scale of zero apart to animate it.
            let scaleX = max(CGFloat(effect.scaleX), 0.001)
            let scaleY = max(CGFloat(effect.scaleY), 0.001)
            var turn = CATransform3DMakeScale(scaleX, scaleY, 1)
            if effect.rotation != 0 {
                turn = CATransform3DRotate(turn, CGFloat(effect.rotation * .pi / 180), 0, 0, 1)
            }
            if effect.flipX != 0 || effect.flipY != 0 {
                turn = CATransform3DRotate(turn, CGFloat(effect.flipX * .pi / 180), 1, 0, 0)
                turn = CATransform3DRotate(
                    turn,
                    across * CGFloat(effect.flipY * .pi / 180),
                    0,
                    1,
                    0
                )
                // Seen from twice the node's size away, so the near side looks bigger.
                var perspective = CATransform3DIdentity
                perspective.m34 = -1 / (2 * max(size.width, size.height, 1))
                turn = CATransform3DConcat(turn, perspective)
            }
            let about = CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), turn),
                CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            )
            let move = CATransform3DMakeTranslation(
                across * CGFloat(effect.offset.x + effect.sizeOffset.x * Double(size.width)),
                CGFloat(effect.offset.y + effect.sizeOffset.y * Double(size.height)),
                0
            )
            return CATransform3DConcat(CATransform3DConcat(base, about), move)
        }

        /// Decides what happens to the layers taken out of their superlayers by this render:
        /// a layer whose node left goes out the way its transition says, from where it was,
        /// when the render is animated, and so does one still going out from before; any
        /// other is dropped.
        private func settle(
            _ detached: [(layer: CALayer, superlayer: CALayer, index: Int)],
            gone: [ObjectIdentifier: (id: NodeID, transition: Transition)],
            pass: Pass
        ) {
            var fading: [NodeID: CALayer] = [:]
            for entry in detached {
                let layer = entry.layer
                if let (id, transition) = gone[ObjectIdentifier(layer)],
                    let animation = pass.animation
                {
                    guard !transition.removal.isIdentity else { continue }

                    let shown = Look(presentedBy: layer)
                    layer.transform = LayerRenderer.transform(
                        transition.removal,
                        size: layer.bounds.size,
                        base: layer.transform,
                        rightToLeft: pass.rightToLeft
                    )
                    goOut(
                        layer,
                        transition.removal,
                        transition.animation ?? animation,
                        shown: shown,
                        pass: pass
                    )
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
            drawing.prepareDrawing(size: size, scale: scale)
            let wanted = Drawing(revision: drawing.drawingRevision, size: size, scale: scale)
            let before = drawn[node.id]
            if let shown = drawing.layerImage {
                show(shown, as: wanted, of: node, in: layer, animation: animation)
                return
            }
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
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
            let interval = Trace.begin(
                .draw,
                "\(pixelWidth)x\(pixelHeight) \(type(of: drawing))"
            )
            drawing.draw(in: context, size: size)
            Trace.end(interval)
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

        /// Shows `shown` as the layer's contents, scaled by Core Animation into the frame: a
        /// new size or scale needs no new bitmap, only a new placement. `fill` crops through
        /// `contentsRect` rather than `masksToBounds`, which would clip the layer's shadow.
        private func show(
            _ shown: LayerImage,
            as wanted: Drawing,
            of node: Node,
            in layer: CALayer,
            animation: Animation?
        ) {
            let image = shown.image
            switch shown.contentMode {
            case .fit:
                layer.contentsGravity = .resizeAspect
                layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            case .stretch:
                layer.contentsGravity = .resize
                layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            case .fill:
                layer.contentsGravity = .resize
                layer.contentsRect = LayerRenderer.fillCrop(
                    image: CGSize(width: image.width, height: image.height),
                    frame: wanted.size
                )
            }
            layer.contentsScale = CGFloat(wanted.scale)

            let before = drawn[node.id]
            drawn[node.id] = wanted
            let current = layer.contents.map { $0 as AnyObject }
            guard current !== image else { return }

            layer.contents = image
            if let animation, let before, before.revision != wanted.revision, let current {
                let curve =
                    if case .spring = animation.curve {
                        Animation.easeInOut(duration: animation.duration)
                    } else {
                        animation
                    }
                layer.add(
                    makeAnimation("contents", from: current, to: image, curve),
                    forKey: "contents"
                )
            }
        }

        /// The centered part of an image that covers `frame` at the image's proportions, in
        /// unit coordinates of the image.
        nonisolated static func fillCrop(image: CGSize, frame: CGSize) -> CGRect {
            guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else {
                return CGRect(x: 0, y: 0, width: 1, height: 1)
            }

            let imageRatio = image.width / image.height
            let frameRatio = frame.width / frame.height
            if imageRatio > frameRatio {
                let width = frameRatio / imageRatio
                return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
            }

            let height = imageRatio / frameRatio
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
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
            applySpin(appearance.spin, to: layer)
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

        /// Keeps `layer` turning `spin` times a second, or stops it. The turn is added to the
        /// layer's transform rather than set, so a scale or a transition moves it as well.
        private func applySpin(_ spin: Double, to layer: CALayer) {
            let key = "spin"
            guard spin != 0 else {
                layer.removeAnimation(forKey: key)
                return
            }

            let duration = 1 / abs(spin)
            if let running = layer.animation(forKey: key), running.duration == duration {
                return
            }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = spin > 0 ? 2 * Double.pi : -2 * Double.pi
            turn.duration = duration
            turn.repeatCount = .infinity
            turn.isAdditive = true
            layer.add(turn, forKey: key)
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
