#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import NodesUIKit
    import Testing
    import UIKit

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

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                avatar; badge
            }
            .gap(10)
            .padding(10)
        }
    }

    @MainActor
    private final class Presses {
        var count = 0
    }

    @MainActor
    private final class Toolbar: Node {
        let title = Text("Profile")
        let follow: Button
        let more: Button

        init(presses: Presses) {
            follow = Button("Follow") { presses.count += 1 }
            more = Button("More") {}
            super.init()
            isFocusSection = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                title; follow; more
            }
            .gap(10)
            .padding(10)
        }
    }

    @MainActor
    private func laidOut(_ view: NodeView, width: CGFloat, height: CGFloat) -> NodeView {
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    @Test @MainActor
    func aNodeViewLaysOutAndDrawsItsTree() {
        let card = Card()
        let view = laidOut(NodeView(root: card), width: 200, height: 60)
        view.zoom = 1
        view.layoutIfNeeded()

        #expect(
            view.renderedLayer(for: card.avatar)?.frame
                == CGRect(x: 10, y: 10, width: 40, height: 40)
        )
        #expect(view.intrinsicContentSize == CGSize(width: UIView.noIntrinsicMetric, height: 60))
        #expect(view.sizeThatFits(.zero) == CGSize(width: 90, height: 60))
        view.host.detach()
    }

    @Test @MainActor
    func zoomLaysTheTreeOutSmallerAndDrawsItBigger() {
        let card = Card()
        let view = NodeView(root: card)
        view.zoom = 2
        _ = laidOut(view, width: 400, height: 120)

        #expect(view.host.size == LayoutSize(width: 200, height: 60))
        #expect(card.avatar.frame == LayoutRect(x: 10, y: 10, width: 40, height: 40))
        #expect(view.sizeThatFits(.zero) == CGSize(width: 180, height: 120))
        #expect(view.host.scale == Double(view.traitCollection.displayScale) * 2)
        view.host.detach()
    }

    @Test @MainActor
    func addSubnodeEmbedsANodeInAView() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let card = Card()
        let view = parent.addSubnode(card)

        #expect(view.superview === parent)
        #expect(view.root === card)
        view.host.detach()
    }

    @Test @MainActor
    func aNodeViewOffersItsTreeToVoiceOver() throws {
        let presses = Presses()
        let view = NodeView(root: Toolbar(presses: presses))
        view.zoom = 1
        _ = laidOut(view, width: 400, height: 60)

        let elements = try #require(view.accessibilityElements as? [UIAccessibilityElement])
        #expect(!view.isAccessibilityElement)
        #expect(elements.map(\.accessibilityLabel) == ["Profile", "Follow", "More"])
        #expect(elements[0].accessibilityTraits.contains(.staticText))
        #expect(elements[1].accessibilityTraits.contains(.button))
        #expect(elements.allSatisfy { $0.accessibilityFrameInContainerSpace.width > 0 })
        #expect(elements[1].accessibilityActivate())
        #expect(presses.count == 1)
        view.host.detach()
    }

    @Test @MainActor
    func focusItemsAndSectionsFollowThePlatformsFocusSystem() {
        let view = NodeView(root: Toolbar(presses: Presses()))
        _ = laidOut(view, width: 800, height: 120)
        let idiom = view.traitCollection.userInterfaceIdiom
        let items = view.focusItems(in: view.bounds).filter { !($0 is UIView) }

        if idiom == .tv || idiom == .pad {
            // One item per button; the frames are in the view's points, zoomed.
            #expect(items.count == 2)
            #expect(items.allSatisfy { $0.frame.width > 0 && $0.frame.maxX <= view.bounds.width })
            #expect(view.layoutGuides.contains { $0 is UIFocusGuide })
            #expect(view.canBecomeFirstResponder)
        } else {
            // An iPhone has no focus system for parts of a view.
            #expect(items.isEmpty)
            #expect(!view.canBecomeFirstResponder)
        }
        view.host.detach()
    }

    @Test @MainActor
    func aFocusRequestWithoutAFocusSystemFocusesAtOnce() {
        let toolbar = Toolbar(presses: Presses())
        let view = NodeView(root: toolbar)
        _ = laidOut(view, width: 800, height: 120)
        let idiom = view.traitCollection.userInterfaceIdiom
        guard idiom != .tv, idiom != .pad else {
            view.host.detach()
            return
        }

        view.host.requestFocus(toolbar.follow.id)

        #expect(view.host.focusedNode == toolbar.follow.id)
        view.host.detach()
    }
#endif
