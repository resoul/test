#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import NodesRender
    import QuartzCore
    import StateCore
    import Testing

    // Animations are checked by what the renderer adds to the layers, before Core Animation
    // commits them: on layers outside a window a commit drops them. So a scene keeps a
    // transaction open, around every render, until `close()` — deferred, so that a failed
    // `#require` does not leave it open for the next test.

    @MainActor
    private final class Dot: Node {
        var width: Double {
            didSet { setNeedsLayout() }
        }

        init(width: Double) {
            self.width = width
        }

        override var layoutContent: LeafContent? {
            .size(LayoutSize(width: width, height: 10))
        }
    }

    @MainActor
    private final class Row: Node {
        let spacer = Dot(width: 20)
        let dot = Dot(width: 10)
        let badge = Dot(width: 10)
        let showsBadge = State(false)
        let dotIsInvisible = State(false)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                spacer
                dot.invisible(dotIsInvisible.value)
                if showsBadge.value { badge }
            }
            .alignItems(.start)
        }
    }

    /// A row laid out and drawn once, without animation.
    @MainActor
    private struct Scene {
        let row = Row()
        let host: NodeHost
        let renderer = LayerRenderer()
        let container = CALayer()

        init() {
            host = NodeHost(root: row, size: LayoutSize(width: 200, height: 50))
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
    }

    @Test @MainActor
    func aTreeDrawnForTheFirstTimeDoesNotAnimate() {
        let row = Row()
        let host = NodeHost(root: row, size: LayoutSize(width: 200, height: 50))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()

        renderer.render(row, in: CALayer(), animation: .default)

        for node in [row, row.spacer, row.dot] {
            #expect(renderer.layer(for: node)?.animationKeys() == nil)
        }
        host.detach()
    }

    @Test @MainActor
    func anAnimatedRenderMovesLayersFromWhereTheyWere() throws {
        let scene = Scene()
        defer { scene.close() }

        withAnimation {
            scene.row.spacer.width = 60
        }
        scene.render()

        let dot = try #require(scene.layer(scene.row.dot))
        let move = try #require(dot.animation(forKey: "position") as? CABasicAnimation)
        #expect(move.fromValue as? CGPoint == CGPoint(x: 25, y: 5))
        #expect(move.toValue as? CGPoint == CGPoint(x: 65, y: 5))
        #expect(move.duration == 0.25)
        #expect(dot.frame == CGRect(x: 60, y: 0, width: 10, height: 10))
        let spacer = try #require(scene.layer(scene.row.spacer))
        let resize = try #require(spacer.animation(forKey: "bounds") as? CABasicAnimation)
        #expect(resize.fromValue as? CGRect == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(resize.toValue as? CGRect == CGRect(x: 0, y: 0, width: 60, height: 10))
    }

    @Test @MainActor
    func aRenderWithoutAnimationShowsChangesAtOnce() {
        let scene = Scene()
        defer { scene.close() }

        scene.row.spacer.width = 60
        scene.render()

        #expect(scene.layer(scene.row.dot)?.animationKeys() == nil)
        #expect(scene.layer(scene.row.dot)?.frame.origin.x == 60)
    }

    @Test @MainActor
    func aRenderWithoutAnimationLeavesRunningAnimationsOfUnchangedValues() {
        let scene = Scene()
        defer { scene.close() }
        withAnimation {
            scene.row.spacer.width = 60
        }
        scene.render()

        scene.row.appearance.opacity = 0.5
        scene.render()

        #expect(scene.layer(scene.row.dot)?.animation(forKey: "position") != nil)
    }

    @Test @MainActor
    func aNodeComingInFadesIn() throws {
        let scene = Scene()
        defer { scene.close() }

        withAnimation {
            scene.row.showsBadge.value = true
        }
        scene.render()

        let badge = try #require(scene.layer(scene.row.badge))
        let fade = try #require(badge.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(fade.fromValue as? Float == 0)
        #expect(fade.toValue as? Float == 1)
        #expect(badge.animation(forKey: "position") == nil)
    }

    @Test @MainActor
    func aNodeLeavingFadesOutWhereItWasAndIsDroppedAfterwards() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.showsBadge.value = true
        scene.render()
        let badge = try #require(scene.layer(scene.row.badge))

        withAnimation {
            scene.row.showsBadge.value = false
        }
        scene.render()

        #expect(scene.layer(scene.row.badge) == nil)
        #expect(badge.superlayer === scene.layer(scene.row))
        #expect(badge.opacity == 0)
        let fade = try #require(badge.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(fade.fromValue as? Float == 1)
        #expect(fade.toValue as? Float == 0)

        badge.removeAnimation(forKey: "opacity")
        scene.row.appearance.opacity = 0.5
        scene.render()

        #expect(badge.superlayer == nil)
    }

    @Test @MainActor
    func aNodeComingBackWhileFadingOutKeepsItsLayer() throws {
        let scene = Scene()
        defer { scene.close() }
        scene.row.showsBadge.value = true
        scene.render()
        let badge = try #require(scene.layer(scene.row.badge))
        withAnimation {
            scene.row.showsBadge.value = false
        }
        scene.render()

        withAnimation {
            scene.row.showsBadge.value = true
        }
        scene.render()

        #expect(scene.layer(scene.row.badge) === badge)
        #expect(badge.opacity == 1)
        #expect(scene.layer(scene.row)?.sublayers?.count == 3)
    }

    @Test @MainActor
    func aNodeHiddenWithAnimationFadesOutBeforeItIsHidden() throws {
        let scene = Scene()
        defer { scene.close() }
        let dot = try #require(scene.layer(scene.row.dot))

        withAnimation {
            scene.row.dotIsInvisible.value = true
        }
        scene.render()

        #expect(!dot.isHidden)
        #expect(dot.opacity == 0)
        #expect(dot.animation(forKey: "opacity") != nil)

        dot.removeAnimation(forKey: "opacity")
        scene.row.appearance.opacity = 0.5
        scene.render()

        #expect(dot.isHidden)
    }

    @Test @MainActor
    func appearanceChangesAnimateToo() throws {
        let scene = Scene()
        defer { scene.close() }

        withAnimation {
            scene.row.dot.appearance.background = Color(red: 0, green: 0, blue: 1)
            scene.row.dot.appearance.cornerRadius = 5
        }
        scene.render()

        let dot = try #require(scene.layer(scene.row.dot))
        let color = try #require(dot.animation(forKey: "backgroundColor") as? CABasicAnimation)
        let from = color.fromValue as! CGColor
        #expect(from.alpha == 0)
        #expect(dot.animation(forKey: "cornerRadius") != nil)
    }

    @Test @MainActor
    func aSpringIsASpringAnimation() {
        let scene = Scene()
        defer { scene.close() }

        withAnimation(.spring(response: 0.4, dampingRatio: 0.7)) {
            scene.row.spacer.width = 60
        }
        scene.render()

        let move = scene.layer(scene.row.dot)?.animation(forKey: "position")
        #expect(move is CASpringAnimation)
        #expect(move?.duration == Animation.spring(response: 0.4, dampingRatio: 0.7).duration)
    }
#endif
