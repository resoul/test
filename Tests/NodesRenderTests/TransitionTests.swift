#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import QuartzCore
    import StateCore
    import Testing

    @testable import NodesRender

    // As in the other animation tests, a scene keeps a transaction open around its renders
    // until `close()`: a commit drops the animations of layers outside a window.

    @MainActor
    private final class Box: Node {
        override var layoutContent: LeafContent? {
            .size(LayoutSize(width: 40, height: 20))
        }
    }

    @MainActor
    private final class Row: Node {
        let first = Box()
        let badge = Box()
        let hides = Box()
        let showsBadge = State(false)
        let hidesBox = State(false)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                first
                hides.invisible(hidesBox.value)
                if showsBadge.value { badge }
            }
            .alignItems(.start)
        }
    }

    @MainActor
    private struct Scene {
        let row = Row()
        let host: NodeHost
        let renderer = LayerRenderer()
        let container = CALayer()

        init(direction: LayoutDirection = .leftToRight) {
            host = NodeHost(root: row, size: LayoutSize(width: 200, height: 50))
            host.direction = direction
            CATransaction.begin()
            render()
        }

        func close() {
            host.detach()
            CATransaction.commit()
        }

        func render() {
            host.layoutIfNeeded()
            renderer.render(row, in: container, animation: host.renderAnimation)
            host.didRender()
        }

        func layer(_ node: Node) -> CALayer? {
            renderer.layer(for: node)
        }

        /// Shows the badge in an animated change.
        func showBadge(_ shows: Bool = true, _ animation: Animation = .default) {
            withAnimation(animation) {
                row.showsBadge.value = shows
            }
            render()
        }
    }

    /// Where `transform` takes the point `x`, `y` of a layer, from its center.
    private func applied(_ transform: CATransform3D, x: CGFloat, y: CGFloat) -> CGPoint {
        let w = x * transform.m14 + y * transform.m24 + transform.m44
        return CGPoint(
            x: (x * transform.m11 + y * transform.m21 + transform.m41) / w,
            y: (x * transform.m12 + y * transform.m22 + transform.m42) / w
        )
    }

    private func transform(_ animation: CAAnimation?, _ key: String) -> CATransform3D? {
        ((animation as? CABasicAnimation)?.value(forKey: key) as? NSValue)?.caTransform3DValue
    }

    @Test @MainActor
    func aNodeWithAScaleGrowsInFromItsCenterWithoutFading() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.badge.transition = .scale

        scene.showBadge()

        let badge = try #require(scene.layer(scene.row.badge))
        let grow = badge.animation(forKey: "transform")
        let from = try #require(transform(grow, "fromValue"))
        let to = try #require(transform(grow, "toValue"))
        #expect(CATransform3DEqualToTransform(to, CATransform3DIdentity))
        #expect(abs(from.m11) < 0.01 && abs(from.m22) < 0.01)
        #expect(badge.animation(forKey: "opacity") == nil)
    }

    @Test @MainActor
    func aNodeMovingInComesFromItsLeadingEdge() throws {
        for (direction, x) in [(LayoutDirection.leftToRight, -40.0), (.rightToLeft, 40)] {
            let scene = Scene(direction: direction)
            defer { scene.close() }
            scene.row.badge.transition = .move(edge: .leading)

            scene.showBadge()

            // Its own width toward the leading side: the left, or the right from the right.
            let badge = try #require(scene.layer(scene.row.badge))
            let from = try #require(transform(badge.animation(forKey: "transform"), "fromValue"))
            #expect(from.m41 == CGFloat(x), "\(direction)")
            #expect(from.m42 == 0)
        }
    }

    @Test @MainActor
    func aNodeMovingOutGoesToItsEdgeAndDoesNotShowAfterwards() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.badge.transition = .move(edge: .bottom)
        scene.row.showsBadge.value = true
        scene.render()
        let badge = try #require(scene.layer(scene.row.badge))

        scene.showBadge(false)

        // Out by its height, not fading on the way, and transparent once there.
        #expect(badge.superlayer === scene.layer(scene.row))
        let move = try #require(transform(badge.animation(forKey: "transform"), "toValue"))
        #expect(move.m42 == 20)
        let fade = try #require(badge.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(fade.fromValue as? Float == 1)
        #expect(fade.toValue as? Float == 1)
        #expect(badge.opacity == 0)

        badge.removeAnimation(forKey: "opacity")
        scene.row.appearance.opacity = 0.5
        scene.render()

        #expect(badge.superlayer == nil)
    }

    @Test @MainActor
    func anIdentityTransitionComesAndGoesAtOnce() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.badge.transition = .identity

        scene.showBadge()
        let badge = try #require(scene.layer(scene.row.badge))
        #expect(badge.animationKeys() == nil)

        scene.showBadge(false)
        #expect(badge.superlayer == nil)
    }

    @Test @MainActor
    func anAsymmetricTransitionComesInOneWayAndGoesOutAnother() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.badge.transition = .asymmetric(
            insertion: .push(from: .trailing),
            removal: .opacity
        )

        scene.showBadge()
        let badge = try #require(scene.layer(scene.row.badge))
        let push = try #require(transform(badge.animation(forKey: "transform"), "fromValue"))
        #expect(push.m41 == 40)
        #expect((badge.animation(forKey: "opacity") as? CABasicAnimation)?.fromValue as? Float == 0)

        // Stops coming in: it goes out by fading only.
        badge.removeAllAnimations()
        scene.showBadge(false)
        #expect(badge.animation(forKey: "transform") == nil)
        #expect((badge.animation(forKey: "opacity") as? CABasicAnimation)?.toValue as? Float == 0)
    }

    @Test @MainActor
    func aTransitionWithItsOwnAnimationMovesWithIt() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.badge.transition = .move(edge: .top).animation(.spring())

        scene.showBadge(true, .linear(duration: 0.1))

        let badge = try #require(scene.layer(scene.row.badge))
        #expect(badge.animation(forKey: "transform") is CASpringAnimation)
    }

    @Test @MainActor
    func aHiddenNodeGoesOutAndComesBackTheWayItsTransitionSays() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.hides.transition = .scale(0.5)
        let hides = try #require(scene.layer(scene.row.hides))

        withAnimation {
            scene.row.hidesBox.value = true
        }
        scene.render()

        // Shrinks without fading, then is hidden.
        #expect(!hides.isHidden)
        let shrink = try #require(transform(hides.animation(forKey: "transform"), "toValue"))
        #expect(shrink.m11 == 0.5)
        #expect((hides.animation(forKey: "opacity") as? CABasicAnimation)?.toValue as? Float == 1)
        hides.removeAllAnimations()
        scene.row.appearance.opacity = 0.5
        scene.render()
        #expect(hides.isHidden)

        withAnimation {
            scene.row.hidesBox.value = false
        }
        scene.render()

        // Grows back, without the fade in a shown layer would get.
        #expect(!hides.isHidden)
        #expect(hides.opacity == 1)
        let grow = try #require(transform(hides.animation(forKey: "transform"), "fromValue"))
        #expect(grow.m11 == 0.5)
        #expect(hides.animation(forKey: "opacity") == nil)
    }

    @Test @MainActor
    func aNodePlacedWithATransitionInTheLayoutUsesIt() throws {
        final class Placed: Node {
            let badge = Box()
            let shows = State(false)

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.row) {
                    if shows.value { badge.transition(.pop) }
                }
            }
        }
        let placed = Placed()
        let host = NodeHost(root: placed, size: LayoutSize(width: 200, height: 50))
        let renderer = LayerRenderer()
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        host.layoutIfNeeded()
        renderer.render(placed, in: CALayer())

        withAnimation {
            placed.shows.value = true
        }
        host.layoutIfNeeded()
        renderer.render(placed, in: CALayer(), animation: host.renderAnimation)

        let badge = try #require(renderer.layer(for: placed.badge))
        // A pop springs in from a little smaller, fading in.
        #expect(badge.animation(forKey: "transform") is CASpringAnimation)
        #expect((badge.animation(forKey: "opacity") as? CABasicAnimation)?.fromValue as? Float == 0)
    }

    @Test @MainActor
    func aScaleAboutAnAnchorKeepsThatPointInPlace() {
        let size = CGSize(width: 40, height: 20)
        let effect = Transition.scale(0.5, anchor: .topLeading).insertion

        let left = LayerRenderer.transform(
            effect,
            size: size,
            base: CATransform3DIdentity,
            rightToLeft: false
        )
        let right = LayerRenderer.transform(
            effect,
            size: size,
            base: CATransform3DIdentity,
            rightToLeft: true
        )

        // The top leading corner, from the center: the top left, or from the right, the top
        // right.
        #expect(applied(left, x: -20, y: -10) == CGPoint(x: -20, y: -10))
        #expect(applied(left, x: 20, y: 10) == CGPoint(x: 0, y: 0))
        #expect(applied(right, x: 20, y: -10) == CGPoint(x: 20, y: -10))
    }

    @Test @MainActor
    func aTurnAndAFlipTurnTheLayer() {
        let size = CGSize(width: 40, height: 20)
        let turn = LayerRenderer.transform(
            Transition.rotation(degrees: 90).insertion,
            size: size,
            base: CATransform3DIdentity,
            rightToLeft: false
        )
        let flip = LayerRenderer.transform(
            Transition.flip().insertion,
            size: size,
            base: CATransform3DIdentity,
            rightToLeft: false
        )

        // A quarter turn clockwise takes the right to the bottom.
        let point = applied(turn, x: 10, y: 0)
        #expect(abs(point.x) < 0.001 && abs(point.y - 10) < 0.001)
        // Edge on: every point across goes to the middle line; in perspective, how far a
        // point looks depends on where across it is.
        #expect(flip.m14 != 0)
        #expect(abs(applied(flip, x: 20, y: 0).x) < 0.001)
    }
#endif
