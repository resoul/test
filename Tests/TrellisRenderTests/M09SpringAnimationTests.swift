import Foundation
import QuartzCore
import Testing

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@testable import TrellisCore
@testable import TrellisRender

// M09 — следующий самостоятельный шаг: настоящая пружина (implementation-plan-5.md §5,
// docs/validation/m09-spring-animation.md). `LayerAnimator` already proved D66's retarget/
// token contract generically for the four eased curves (LayerAnimatorTests.swift) — these
// tests prove the same mechanism holds for `.spring`, and that a spring is a real
// `CASpringAnimation` (defect #41: the ported source faked `.spring` as `.easeInEaseOut`),
// never a `CABasicAnimation` standing in for one.

@MainActor
private final class SpringWindowHost {
    let containerLayer: CALayer
    #if canImport(AppKit)
        private let window: NSWindow
    #elseif canImport(UIKit)
        private let window: UIWindow
    #endif

    init() {
        #if canImport(AppKit)
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
            view.wantsLayer = true
            window = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            containerLayer = view.layer ?? CALayer()
        #elseif canImport(UIKit)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
            let view = UIView(frame: window.bounds)
            window.addSubview(view)
            window.makeKeyAndVisible()
            containerLayer = view.layer
        #endif
    }

    func pump(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

@MainActor
private func mountedLayer(under host: SpringWindowHost) -> CALayer {
    let layer = CALayer()
    host.containerLayer.addSublayer(layer)
    return layer
}

@MainActor
private func intent(
    _ animation: Animation,
    scope: NodeID = NodeIDAllocator.allocate(),
    sequence: UInt64 = 1,
    epoch: UInt64 = 1
) -> AnimationIntent {
    AnimationIntent(scopeNodeID: scope, sequence: sequence, epoch: epoch, animation: animation)
}

@Test @MainActor
func m09_springIntentCreatesARealCASpringAnimationNotAnEasedStandIn() throws {
    let host = SpringWindowHost()
    let layer = mountedLayer(under: host)
    layer.opacity = 1
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.4
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.spring(response: 0.4, dampingFraction: 0.8)),
        host: nil,
        generation: nil
    )

    let spring = try #require(layer.animation(forKey: "opacity") as? CASpringAnimation)
    #expect((spring.fromValue as? Float) == 1)
    #expect((spring.toValue as? Float) == 0.4)
    #expect(spring.mass == 1)
    // response/dampingFraction → mass/stiffness/damping, the same conversion SwiftUI's own
    // two-parameter spring API is built on — checked directly against the formula, not just
    // "some positive number", so a future refactor cannot silently drift the physics.
    let expectedStiffness = pow(2 * Double.pi / 0.4, 2)
    let expectedDamping = 4 * Double.pi * 0.8 / 0.4
    #expect(abs(spring.stiffness - expectedStiffness) < 0.001)
    #expect(abs(spring.damping - expectedDamping) < 0.001)
    #expect(spring.initialVelocity == 0)
    // Never guessed upstream — read back from the SDK's own computed estimate (M09's
    // acceptance: settling is verified on the SDK, not asserted from a hand-written formula).
    #expect(spring.duration == spring.settlingDuration)
    #expect(spring.duration > 0)
}

@Test @MainActor
func m09_springRetargetsMidFlightFromThePresentationValueNotTheOriginalModel() throws {
    let host = SpringWindowHost()
    let layer = mountedLayer(under: host)
    layer.opacity = 1
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    var before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.4
    // Long enough that a real, positive amount of the transition remains after the 0.25s pump
    // below — `host.pump` is real wall-clock time, the same technique
    // `m04_retargetMidFlightStartsFromThePresentationValueNotTheOldOrNewModel` uses.
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.spring(response: 2, dampingFraction: 0.9)),
        host: nil,
        generation: nil
    )
    #expect(layer.animation(forKey: "opacity") is CASpringAnimation)

    host.pump(for: 0.25)
    let midpoint = try #require(layer.presentation()?.opacity)
    #expect(midpoint < 1)
    #expect(midpoint > 0.4)

    before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.9
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.spring(response: 2, dampingFraction: 0.9)),
        host: nil,
        generation: nil
    )

    let retargeted = try #require(layer.animation(forKey: "opacity") as? CASpringAnimation)
    #expect((retargeted.toValue as? Float) == 0.9)
    let fromValue = try #require(retargeted.fromValue as? Float)
    // D66: starts from the live presentation value at the moment of retarget, not `before`'s
    // stale 0.4 — allow a little more drift than `midpoint` since more real time elapsed
    // running this test's own assertions between the two samples.
    #expect(abs(fromValue - midpoint) < 0.2)
    #expect(fromValue != 0.4, "must retarget from the live presentation, not the pre-press model")
}

@Test @MainActor
func m09_reduceMotionSnapsASpringIntentTheSameWayItSnapsAnyOtherCurve() throws {
    let host = SpringWindowHost()
    let layer = mountedLayer(under: host)
    layer.opacity = 1
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.4
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.spring(response: 30, dampingFraction: 0.9)),
        host: nil,
        generation: nil
    )
    #expect(layer.animation(forKey: "opacity") is CASpringAnimation)

    // `LayerRenderer.resolvedIntent` resolves Reduce Motion to a `nil` intent before this ever
    // runs (D67) — `reconcile` itself does not know or care what curve a `nil` intent would
    // have carried, which this test makes explicit for `.spring` specifically.
    let afterReduceMotion = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.9
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: afterReduceMotion,
        mountEpoch: 1,
        intent: nil,
        host: nil,
        generation: nil
    )

    #expect(layer.animation(forKey: "opacity") == nil)
    #expect(layer.opacity == 0.9)
}

@Test @MainActor
func m09_physicallyBoundedPropertiesBuildTheSameSpringPhysicsAsUnboundedOnes() throws {
    // D61's opacity/cornerRadius are clamped by CALayer itself (opacity visually saturates
    // outside 0...1, cornerRadius negative is meaningless) — an underdamped spring can overshoot
    // past its target before settling, which is a real, accepted visual characteristic of a
    // bouncy preset on these two properties (documented in m09-spring-animation.md), not
    // something this layer clamps away. What must hold regardless is that construction itself
    // is identical to any other property: real physics, not a silently-downgraded ease.
    let host = SpringWindowHost()
    let layer = mountedLayer(under: host)
    layer.opacity = 1
    layer.cornerRadius = 0
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0
    layer.cornerRadius = 20
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        // Deliberately bouncy (low damping) — the case most likely to overshoot.
        intent: intent(.spring(response: 0.3, dampingFraction: 0.4)),
        host: nil,
        generation: nil
    )

    let opacitySpring = try #require(layer.animation(forKey: "opacity") as? CASpringAnimation)
    let radiusSpring = try #require(layer.animation(forKey: "cornerRadius") as? CASpringAnimation)
    for spring in [opacitySpring, radiusSpring] {
        #expect(spring.mass == 1)
        #expect(spring.damping > 0)
        #expect(spring.stiffness > 0)
        #expect(spring.duration > 0)
    }
}

@Test @MainActor
func m09_completionTokenCleanupWorksForASpringExactlyLikeAnEasedAnimation() throws {
    let host = SpringWindowHost()
    let layer = mountedLayer(under: host)
    layer.opacity = 1
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.4
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 7,
        intent: intent(.snappy),
        host: nil,
        generation: nil
    )
    #expect(animator.activeCount(mountEpoch: 7) == 1)

    // The real `CATransaction` completion callback is not delivered inside XCTest on this
    // toolchain (m02-animation-prototype.md §1.4) — `completeIfCurrent` is invoked directly,
    // as if it had arrived, the same technique LayerAnimatorTests.swift uses throughout.
    animator.completeIfCurrent(nodeID: nodeID, mountEpoch: 7, property: .opacity, token: 0)
    #expect(animator.activeCount(mountEpoch: 7) == 0)
}
