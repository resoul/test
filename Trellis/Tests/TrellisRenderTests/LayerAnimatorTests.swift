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

// M04 — маленький explicit animator внутри renderer (implementation-plan-5.md §5,
// docs/validation/m04-layer-animator.md). Проверяет `LayerAnimator` напрямую — diff
// D61's таблицы свойств, retarget/snap по D66, адресные ключи `(mountEpoch, NodeID,
// property)` по D64, и presentation-reader/completion adapter отдельно от реальной
// доставки CA-колбэка (M02 §1.4: доставка не воспроизводится в XCTest-хостинге, здесь
// `completeIfCurrent` вызывается напрямую, как `AnimationHarness.completeIfCurrent`).

/// A real, on-screen window+layer — M02 found `CALayer.add(_:forKey:)`/`presentation()`
/// unreliable off a mounted tree until a process-wide one-time warm-up; every test here
/// mounts its layer the same way M02's `WindowHost` did.
@MainActor
private final class AnimatorWindowHost {
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
private func mountedLayer(under host: AnimatorWindowHost) -> CALayer {
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
func m04_changedPropertyUnderAnIntentCreatesFromToKeyAndDuration() throws {
    let host = AnimatorWindowHost()
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
        intent: intent(.easeOut(duration: .milliseconds(300))),
        host: nil,
        generation: nil
    )

    let animation = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation)
    #expect((animation.fromValue as? Float) == 1)
    #expect((animation.toValue as? Float) == 0.4)
    #expect(animation.duration == 0.3)
    #expect(layer.opacity == 0.4, "model value already applied, actions disabled by the caller")
}

@Test @MainActor
func m04_unchangedPropertyLeavesAnActiveAnimationCompletelyUntouched() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    var before = animator.captureBeforeState(layer: layer)
    layer.position = CGPoint(x: 100, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )
    let original = layer.animation(forKey: "position.x")
    #expect(original != nil)

    // Same target repeat (D64) falls out of the before/after equality check: the write is
    // a no-op from the animator's point of view, so the active animation is never touched.
    before = animator.captureBeforeState(layer: layer)
    layer.position = CGPoint(x: 100, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )

    #expect(layer.animation(forKey: "position.x") === original)
}

@Test @MainActor
func m04_retargetMidFlightStartsFromThePresentationValueNotTheOldOrNewModel() throws {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.position = CGPoint(x: 100, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.easeInOut(duration: .milliseconds(1000))),
        host: nil,
        generation: nil
    )

    host.pump(for: 0.25)
    let midpoint = try #require(layer.presentation()?.position.x)
    #expect(midpoint > 0)
    #expect(midpoint < 100)

    let secondBefore = animator.captureBeforeState(layer: layer)
    layer.position = CGPoint(x: 50, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: secondBefore,
        mountEpoch: 1,
        intent: intent(.easeInOut(duration: .milliseconds(1000))),
        host: nil,
        generation: nil
    )

    let retargeted = try #require(layer.animation(forKey: "position.x") as? CABasicAnimation)
    let from = try #require(retargeted.fromValue as? CGFloat)
    #expect(abs(from - midpoint) < 5)
    #expect((retargeted.toValue as? CGFloat) == 50)
}

@Test @MainActor
func m04_noIntentSnapsAndCreatesNoAnimationObject() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.cornerRadius = 8
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: nil,
        host: nil,
        generation: nil
    )

    #expect(layer.animation(forKey: "cornerRadius") == nil)
    #expect(layer.cornerRadius == 8)
}

@Test @MainActor
func m04_lateNoneOverridesAPriorAnimationAndRemovesOnlyItsOwnKey() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    var before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.5
    layer.position = CGPoint(x: 10, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )
    #expect(layer.animation(forKey: "opacity") != nil)
    let positionAnimation = layer.animation(forKey: "position.x")
    #expect(positionAnimation != nil)

    before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.2
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.none),
        host: nil,
        generation: nil
    )

    #expect(layer.animation(forKey: "opacity") == nil, "addressed removal for the .none property")
    #expect(layer.opacity == 0.2)
    #expect(
        layer.animation(forKey: "position.x") === positionAnimation,
        "an unrelated property's active animation is never disturbed"
    )
}

@Test @MainActor
func m04_snapAllRemovesEveryTrackedAnimationForANewOrReparentedLayer() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.5
    layer.position = CGPoint(x: 10, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )
    #expect(layer.animation(forKey: "opacity") != nil)
    #expect(layer.animation(forKey: "position.x") != nil)

    animator.snapAll(nodeID: nodeID, layer: layer, mountEpoch: 1, host: nil, generation: nil)

    #expect(layer.animation(forKey: "opacity") == nil)
    #expect(layer.animation(forKey: "position.x") == nil)
}

@Test @MainActor
func m04_forgetNodeDropsBookkeepingSoALaterReconcileNoLongerTreatsItAsActive() throws {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    var before = animator.captureBeforeState(layer: layer)
    layer.position = CGPoint(x: 100, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.easeInOut(duration: .milliseconds(1000))),
        host: nil,
        generation: nil
    )
    host.pump(for: 0.2)

    animator.forgetNode(nodeID, mountEpoch: 1)

    before = animator.captureBeforeState(layer: layer)
    layer.position = CGPoint(x: 40, y: 0)
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.easeInOut(duration: .milliseconds(1000))),
        host: nil,
        generation: nil
    )

    let animation = try #require(layer.animation(forKey: "position.x") as? CABasicAnimation)
    let from = try #require(animation.fromValue as? CGFloat)
    #expect(
        from == 100,
        "no longer 'active' after forgetNode, fromValue is the model value again"
    )
}

@Test @MainActor
func m04_completeIfCurrentIgnoresAStaleTokenAndAcceptsTheCurrentOne() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    var before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.5
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.easeInOut(duration: .milliseconds(500))),
        host: nil,
        generation: nil
    )

    before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.1
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.easeInOut(duration: .milliseconds(500))),
        host: nil,
        generation: nil
    )
    let afterRetarget = layer.animation(forKey: "opacity")
    #expect(afterRetarget != nil)

    // Token 0 belonged to the first (now replaced) animation. Its eventual completion must
    // not disturb the currently active one (D66 point 3).
    animator.completeIfCurrent(nodeID: nodeID, mountEpoch: 1, property: .opacity, token: 0)
    #expect(layer.animation(forKey: "opacity") === afterRetarget)

    animator.completeIfCurrent(nodeID: nodeID, mountEpoch: 1, property: .opacity, token: 1)
    // Bookkeeping cleared; a later unrelated snap for the same key is a no-op, not a crash.
    animator.snapAll(nodeID: nodeID, layer: layer, mountEpoch: 1, host: nil, generation: nil)
}

@Test @MainActor
func m04_rotationChangeSnapsTransformButScaleAndTranslationAnimate() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()

    var before = animator.captureBeforeState(layer: layer)
    layer.setAffineTransform(CGAffineTransform(scaleX: 2, y: 2))
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )
    #expect(layer.animation(forKey: "transform") != nil, "scale-only change animates")

    before = animator.captureBeforeState(layer: layer)
    layer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 4))
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )
    #expect(
        layer.animation(forKey: "transform") == nil,
        "D61: rotation between matrix representations snaps, a documented first-version limit"
    )
    #expect(
        layer.affineTransform().b != 0,
        "model value is applied regardless of the animation limit"
    )
}

@Test @MainActor
func m04_missingBackgroundColorNormalizesToATransparentCounterpartNotANilAnimationEndpoint() throws
{
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()
    let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    let before = animator.captureBeforeState(layer: layer)
    layer.backgroundColor = red
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )

    let animation = try #require(layer.animation(forKey: "backgroundColor") as? CABasicAnimation)
    let from = try #require(animation.fromValue) as! CGColor
    let to = try #require(animation.toValue) as! CGColor
    #expect(from.alpha == 0, "no prior color normalizes to the target color at zero alpha")
    #expect(to == red)
    #expect(
        layer.backgroundColor == red,
        "model value stays exactly what was written, no synthetic color"
    )
}

// MARK: - M05 (D67): finishing active animations without a new commit

@Test @MainActor
func m05_finishAllActiveRemovesEveryTrackedAnimationInThatEpochAcrossNodes() {
    let host = AnimatorWindowHost()
    let firstLayer = mountedLayer(under: host)
    let secondLayer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let firstID = NodeIDAllocator.allocate()
    let secondID = NodeIDAllocator.allocate()
    var layers: [NodeID: CALayer] = [firstID: firstLayer, secondID: secondLayer]

    for (nodeID, layer) in layers {
        let before = animator.captureBeforeState(layer: layer)
        layer.opacity = 0.3
        animator.reconcile(
            nodeID: nodeID,
            layer: layer,
            before: before,
            mountEpoch: 1,
            intent: intent(.smooth),
            host: nil,
            generation: nil
        )
    }
    #expect(firstLayer.animation(forKey: "opacity") != nil)
    #expect(secondLayer.animation(forKey: "opacity") != nil)

    animator.finishAllActive(mountEpoch: 1) { layers[$0] }

    #expect(firstLayer.animation(forKey: "opacity") == nil)
    #expect(secondLayer.animation(forKey: "opacity") == nil)
    #expect(firstLayer.opacity == 0.3, "already-committed model value is untouched")
    #expect(secondLayer.opacity == 0.3)

    // Bookkeeping is actually cleared, not just the layer side: a later reconcile at the same
    // key treats it as fresh (fromValue is the model value, not a stale presentation read).
    layers = [:]
    let before = animator.captureBeforeState(layer: firstLayer)
    firstLayer.opacity = 0.7
    animator.reconcile(
        nodeID: firstID,
        layer: firstLayer,
        before: before,
        mountEpoch: 1,
        intent: intent(.smooth),
        host: nil,
        generation: nil
    )
    #expect(firstLayer.animation(forKey: "opacity") != nil)
}

@Test @MainActor
func m05_finishAllActiveIgnoresADifferentEpochAndSkipsANodeWithNoLayer() {
    let host = AnimatorWindowHost()
    let layer = mountedLayer(under: host)
    let animator = LayerAnimator()
    let nodeID = NodeIDAllocator.allocate()
    let missingNodeID = NodeIDAllocator.allocate()

    let before = animator.captureBeforeState(layer: layer)
    layer.opacity = 0.3
    animator.reconcile(
        nodeID: nodeID,
        layer: layer,
        before: before,
        mountEpoch: 2,
        intent: intent(.smooth, epoch: 2),
        host: nil,
        generation: nil
    )
    #expect(layer.animation(forKey: "opacity") != nil)

    // A stale/different mount epoch — must not touch this animation at all.
    animator.finishAllActive(mountEpoch: 1) { _ in nil }
    #expect(layer.animation(forKey: "opacity") != nil)

    // A node with no materialized layer (already removed) — the closure returning `nil` must
    // not crash or otherwise misbehave.
    animator.finishAllActive(mountEpoch: 2) { $0 == missingNodeID ? nil : layer }
    #expect(layer.animation(forKey: "opacity") == nil)
}
