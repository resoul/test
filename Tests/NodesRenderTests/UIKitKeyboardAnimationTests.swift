#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import QuartzCore
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Empty: Node {}

    @MainActor
    private func keyboardView() -> NodeView {
        let view = NodeView(root: Empty())
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        view.layoutIfNeeded()
        return view
    }

    @Test @MainActor
    func theTreeMovesWithTheKeyboardsOwnSpringWhenTheSystemGivesOne() throws {
        let view = keyboardView()
        // A TV has no keyboard over the screen, and no view following it.
        guard let probe = view.keyboardProbe else { return }

        // What the system gives the view tied to the keyboard's guide on current systems.
        let spring = CASpringAnimation(keyPath: "position")
        spring.mass = 1
        spring.stiffness = 555.0265
        spring.damping = 47.118
        spring.duration = 0.3833
        probe.layer.add(spring, forKey: "position")

        let animation = try #require(view.keyboardAnimation(duration: 0.3833))
        guard case .spring(let response, let ratio) = animation.curve else {
            Issue.record("not a spring: \(animation)")
            return
        }
        #expect(abs(response - 0.2667) < 0.001)
        #expect(abs(ratio - 1) < 0.001)
        // It runs as long as the system gives the spring to settle, not as long as the block.
        #expect(animation.duration == spring.settlingDuration)
        view.host.detach()
    }

    @Test @MainActor
    func withoutASpringTheBlocksDurationWithAnEaseIsUsedAndOutsideABlockNothing() throws {
        let view = keyboardView()
        guard view.keyboardProbe != nil else { return }

        #expect(view.keyboardAnimation(duration: 0.4) == .easeInOut(duration: 0.4))
        #expect(view.keyboardAnimation(duration: 0) == nil)
        view.host.detach()
    }

    @Test @MainActor
    func aFloatingKeyboardDoesNotPushThePage() throws {
        let view = keyboardView()
        guard view.keyboardProbe != nil else { return }

        if #available(iOS 17, *) {
            #expect(!view.keyboardLayoutGuide.followsUndockedKeyboard)
        }
        view.host.detach()
    }
#endif
