#if canImport(QuartzCore)
    import LayoutCore
    import ThemeCore
    import Nodes
    import NodesRender
    import QuartzCore
    import StateCore
    import Testing

    @MainActor
    private final class Box: Node {
        let size: LayoutSize

        init(_ width: Double, _ height: Double) {
            size = LayoutSize(width: width, height: height)
        }

        override var layoutContent: LeafContent? { .size(size) }
    }

    @MainActor
    private final class Card: Node {
        let avatar = Box(40, 40)
        let badge = Box(20, 20)
        let showsBadge = State(true)

        override init() {
            super.init()
            appearance.background = Color(red: 1, green: 0, blue: 0)
            appearance.cornerRadius = 8
            avatar.appearance.opacity = 0.5
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                avatar
                if showsBadge.value { badge }
            }
            .gap(10)
            .padding(10)
        }
    }

    @Test @MainActor
    func layersMirrorTheNodeTree() {
        let card = Card()
        let host = NodeHost(root: card, size: LayoutSize(width: 200, height: 60))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        let container = CALayer()

        renderer.render(card, in: container)

        let cardLayer = renderer.layer(for: card)
        let avatarLayer = renderer.layer(for: card.avatar)
        let badgeLayer = renderer.layer(for: card.badge)
        #expect(container.sublayers?.first === cardLayer)
        #expect(cardLayer?.sublayers?.count == 2)
        #expect(cardLayer?.sublayers?.first === avatarLayer)
        #expect(cardLayer?.cornerRadius == 8)
        #expect(cardLayer?.backgroundColor?.components == [1, 0, 0, 1])
        #expect(avatarLayer?.frame == CGRect(x: 10, y: 10, width: 40, height: 40))
        #expect(avatarLayer?.opacity == 0.5)
        // `align-items` is `stretch`: the badge fills the line's height.
        #expect(badgeLayer?.frame == CGRect(x: 60, y: 10, width: 20, height: 40))
        host.detach()
    }

    @Test @MainActor
    func layersOfUnmountedNodesAreRemoved() {
        let card = Card()
        let host = NodeHost(root: card, size: LayoutSize(width: 200, height: 60))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        let container = CALayer()
        renderer.render(card, in: container)

        card.showsBadge.value = false
        host.layoutIfNeeded()
        renderer.render(card, in: container)

        #expect(renderer.layer(for: card.badge) == nil)
        #expect(renderer.layer(for: card)?.sublayers?.count == 1)
        host.detach()
    }
#endif

#if canImport(QuartzCore)
    /// A node that shows a layer of its own inside its frame, with a badge over it.
    @MainActor
    private final class Screen: Node, LayerHosting {
        let surface = CALayer()
        let badge = Box(20, 20)
        var hostedLayer: CALayer? { surface }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { badge }.size(100).padding(10)
        }
    }

    @Test @MainActor
    func aHostedLayerIsUnderTheSubnodesLayersAndFillsTheFrame() {
        let screen = Screen()
        let host = NodeHost(root: screen, size: LayoutSize(width: 200, height: 120))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        let container = CALayer()

        renderer.render(screen, in: container)
        let layer = renderer.layer(for: screen)
        let badge = renderer.layer(for: screen.badge)
        #expect(layer?.sublayers?.count == 2)
        #expect(layer?.sublayers?.first === screen.surface, "under the subnodes")
        #expect(layer?.sublayers?.last === badge, "the badge is over it")
        #expect(screen.frame.size.width > 0)
        #expect(
            screen.surface.frame
                == CGRect(
                    x: 0,
                    y: 0,
                    width: screen.frame.size.width,
                    height: screen.frame.size.height
                )
        )

        // Rendered again, and after the frame changes, it is the same layer, in place.
        screen.badge.appearance.opacity = 0.5
        renderer.render(screen, in: container)
        #expect(layer?.sublayers?.first === screen.surface)
        #expect(screen.surface.superlayer === layer)
        host.detach()
    }

    @Test @MainActor
    func aHostedLayerFollowsTheNodesClippingAndCornerRadius() {
        let screen = Screen()
        screen.appearance.cornerRadius = 12
        screen.appearance.clipsContent = true
        let host = NodeHost(root: screen, size: LayoutSize(width: 200, height: 120))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.render(screen, in: CALayer())

        let layer = renderer.layer(for: screen)
        #expect(layer?.cornerRadius == 12)
        #expect(layer?.masksToBounds == true, "the surface is cut with the node")
        host.detach()
    }
#endif

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import NodesAppKit

    @Test @MainActor
    func aNodeViewLaysOutAndDrawsItsTree() {
        let card = Card()
        let view = NodeNSView(root: card)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
        view.layout()

        #expect(view.layer?.isGeometryFlipped == true)
        #expect(
            view.renderedLayer(for: card.avatar)?.frame
                == CGRect(x: 10, y: 10, width: 40, height: 40)
        )
        #expect(view.intrinsicContentSize == CGSize(width: NSView.noIntrinsicMetric, height: 60))
        view.host.detach()
    }

    @Test @MainActor
    func zoomLaysTheTreeOutSmallerAndDrawsItBigger() throws {
        let card = Card()
        let view = NodeNSView(root: card)
        view.zoom = 2
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 120)
        view.layout()

        #expect(view.host.size == LayoutSize(width: 200, height: 60))
        #expect(view.host.scale == 2)
        let avatar = try #require(view.renderedLayer(for: card.avatar))
        #expect(avatar.frame == CGRect(x: 10, y: 10, width: 40, height: 40))
        // In the view's own layer the tree is twice as big.
        #expect(
            view.layer?.convert(avatar.bounds, from: avatar)
                == CGRect(x: 20, y: 20, width: 80, height: 80)
        )
        #expect(view.intrinsicContentSize == CGSize(width: NSView.noIntrinsicMetric, height: 120))
        view.host.detach()
    }

    @Test @MainActor
    func addSubnodeEmbedsANodeInAView() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let card = Card()
        let view = parent.addSubnode(card)

        #expect(view.superview === parent)
        #expect(view.root === card)
        view.host.detach()
    }
#endif
