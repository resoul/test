#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing
    import UIKit

    @testable import NodesUIKit

    /// A button and a plain box with a tip, side by side.
    @MainActor
    private final class Bar: Node {
        let button = Button("Send") {}
        let box = Box()

        final class Box: Node {
            override var layoutContent: LeafContent? {
                .size(LayoutSize(width: 100, height: 40))
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                button
                box
            }
            .alignItems(.start)
        }
    }

    @Test @MainActor
    func aPointerIsFollowedWhereTheDeviceHasOneAndATipCoversItsNode() throws {
        let bar = Bar()
        bar.box.toolTip = "A box"
        let view = NodeView(root: bar)
        view.zoom = 2
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
        view.layoutIfNeeded()

        let recognizers = (view.gestureRecognizers ?? []).map { NSStringFromClass(type(of: $0)) }
        let interactions = view.interactions.map { NSStringFromClass(type(of: $0)) }
        guard view.traitCollection.userInterfaceIdiom != .tv else {
            // A TV has no pointer, and the classes are not there to find.
            #expect(!recognizers.contains("UIHoverGestureRecognizer"))
            #expect(!interactions.contains("UIToolTipInteraction"))
            #expect(view.pointer == nil)
            return
        }

        #expect(recognizers.contains("UIHoverGestureRecognizer"))
        let tips = try #require(
            view.interactions.first { NSStringFromClass(type(of: $0)) == "UIToolTipInteraction" }
                as? NSObject
        )
        let pointer = try #require(view.pointer)
        #expect(tips.value(forKey: "delegate") as? PointerTracker === pointer)

        // The box is at x 100 in the tree's points, 200 in the view's at zoom 2.
        let box = CGFloat(bar.box.frame.origin.x) * 2
        let configuration = try #require(pointer.toolTip(tips, at: CGPoint(x: box + 20, y: 20)))
        #expect(configuration.value(forKey: "toolTip") as? String == "A box")
        let rect = try #require(configuration.value(forKey: "sourceRect") as? CGRect)
        #expect(rect == CGRect(x: box, y: 0, width: 200, height: 80))
        #expect(pointer.toolTip(tips, at: CGPoint(x: 20, y: 20)) == nil)
    }
#endif
