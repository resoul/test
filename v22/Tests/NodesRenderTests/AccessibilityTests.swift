#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesAppKit
    import NodesRender
    import Testing

    @MainActor
    private final class Presses {
        var count = 0
    }

    @MainActor
    private final class Toolbar: Node {
        let title = Text("Profile")
        let follow: Button

        init(presses: Presses) {
            follow = Button("Follow") { presses.count += 1 }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                title; follow
            }
            .gap(10)
            .padding(10)
        }
    }

    @Test @MainActor
    func aNodeViewOffersItsTreeToVoiceOver() throws {
        let presses = Presses()
        let view = NodeNSView(root: Toolbar(presses: presses))
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        view.layout()

        let elements = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(!view.isAccessibilityElement())
        #expect(elements.map { $0.accessibilityLabel() } == ["Profile", "Follow"])
        #expect(elements.map { $0.accessibilityRole() } == [.staticText, .button])
        #expect(elements[1].accessibilityPerformPress())
        #expect(presses.count == 1)
        view.host.detach()
    }
#endif
