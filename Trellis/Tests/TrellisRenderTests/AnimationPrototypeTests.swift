import Foundation
import QuartzCore
import Testing

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// M02 — маленький нативный прототип до инфраструктуры (implementation-plan-5.md,
// docs/validation/m02-animation-prototype.md). Как и T02
// (TextRasterPrototypeTests.swift), код здесь не претендует на production API — Node/
// RenderCoordinator/LayerRenderer не меняются этой карточкой (M03+). Проверяется только
// платформенный механизм: explicit CABasicAnimation, retarget от presentation (D66),
// completion cleanup по token без unsafe concurrency (D66/D67), и D65 two-layer раскладка
// под анимацией (совместно с T02's RasterHarness-подходом), без TrellisCore/TrellisRender.
//
// Найдено при подготовке этой карточки (docs/validation/m02-animation-prototype.md §1):
// `CALayer.add(_:forKey:)`/`animation(forKey:)` ненадёжны на слое, который никогда не был
// частью смонтированного (имеющего superlayer, в реальном окне) дерева, ПОКА хотя бы один
// смонтированный слой где-то в процессе не зарегистрировал явную анимацию первым —
// глобальный, не per-keypath, one-time прогрев процесса. Каждый тест здесь монтирует свой
// слой под `WindowHost.containerLayer` (реальное окно, не просто `CALayer().addSublayer`),
// кроме теста, который намеренно проверяет именно detached-слой.

/// A real, on-screen window+view — not just `rootLayer.addSublayer(_:)` — because genuine
/// `presentation()` progress requires CoreAnimation's actual per-frame commit machinery,
/// which only runs for a layer tree connected to a live render server (a window that is
/// key/visible), not for a bare or merely-superlayer-linked `CALayer` graph. `swift test`
/// does not pump a run loop on its own the way an app does — `pump(for:)` spins one
/// explicitly, which is what actually advances CA's internal animation clock here.
@MainActor
private final class WindowHost {
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
            containerLayer = view.layer!
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

/// One explicit CABasicAnimation per (layer, keyPath) — the D61/D66 shape: no implicit
/// actions, addressable replace/remove by key, retarget from `presentation()` when one
/// exists. `token` identifies one animation instance across its own lifetime so a stale
/// completion (from a since-replaced or since-removed animation) can be told apart from
/// the current one — the D64/D66 "own monotonic token" requirement.
@MainActor
private final class AnimationHarness {
    private(set) var completedTokens: [UInt64] = []
    private(set) var staleCompletionsIgnored: [UInt64] = []
    private var activeTokens: [String: UInt64] = [:]
    private var nextToken: UInt64 = 0

    /// D66: (1) from presentation if an animation is active, else from prior model value;
    /// (2) sets the model value with actions disabled; (3) replaces/removes the explicit
    /// animation by key. `duration <= 0` is `.none` (D61) — snap, no CAAnimation at all.
    @discardableResult
    func animate(
        _ layer: CALayer,
        keyPath: String,
        to target: CGFloat,
        duration: CFTimeInterval
    ) -> UInt64? {
        let hasActiveAnimation = layer.animation(forKey: keyPath) != nil
        let fromValue: CGFloat
        if hasActiveAnimation, let presentation = layer.presentation() {
            fromValue = (presentation.value(forKeyPath: keyPath) as? CGFloat) ?? target
        } else {
            fromValue = (layer.value(forKeyPath: keyPath) as? CGFloat) ?? target
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: keyPath)

        guard duration > 0 else {
            layer.removeAnimation(forKey: keyPath)
            activeTokens[keyPath] = nil
            CATransaction.commit()
            return nil
        }

        // Same-target repeat while already animating toward it (D64): leave the active
        // animation alone — no restart, no new token — rather than replace it with an
        // identical one that would reset its elapsed time.
        if hasActiveAnimation, let existing = layer.animation(forKey: keyPath) as? CABasicAnimation,
            let existingTo = existing.toValue as? CGFloat, existingTo == target
        {
            CATransaction.commit()
            return activeTokens[keyPath]
        }

        let token = nextToken
        nextToken += 1
        activeTokens[keyPath] = token

        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = fromValue
        animation.toValue = target
        animation.duration = duration
        animation.isRemovedOnCompletion = true

        // D66 completion cleanup: the block is `@MainActor`-isolated and captures only
        // Sendable values (token, keyPath) plus `weak self` — CATransaction's completion
        // block type carries no Sendable requirement of its own, so this compiles under
        // strict concurrency without @unchecked Sendable/nonisolated(unsafe)/@preconcurrency
        // (AGENTS ban). `CATransaction`'s own docs note the completion fires even after the
        // animation was removed (D66) — checked below by comparing against the *current*
        // token for this keyPath, not assuming this callback is the last word.
        CATransaction.setCompletionBlock { @MainActor [weak self] in
            self?.completeIfCurrent(keyPath: keyPath, token: token)
        }
        layer.add(animation, forKey: keyPath)
        CATransaction.commit()
        return token
    }

    /// Internal, not private: `m02_completionLogicIgnoresAStaleTokenAndAcceptsTheCurrentOne`
    /// calls this directly to simulate a CA callback firing, because — found while writing
    /// that test, docs/validation/m02-animation-prototype.md §1 — neither
    /// `CATransaction.setCompletionBlock` nor `CAAnimationDelegate.animationDidStop` ever
    /// fires inside an XCTest-hosted process on this toolchain (`swift test` and
    /// `xcodebuild test` both reproduce it; a plain non-test executable does not), even
    /// though `presentation()` readback works fine there (proven by the retarget test
    /// above). This is the real cleanup contract under test; genuine end-to-end delivery of
    /// the callback itself is evidence for Playground/M06+, not something this suite can
    /// exercise.
    func completeIfCurrent(keyPath: String, token: UInt64) {
        guard activeTokens[keyPath] == token else {
            staleCompletionsIgnored.append(token)
            return
        }
        activeTokens[keyPath] = nil
        completedTokens.append(token)
    }

    func currentToken(forKeyPath keyPath: String) -> UInt64? {
        activeTokens[keyPath]
    }
}

@Test @MainActor
func m02_explicitAnimationRetargetsFromPresentationNotFromOriginalModelValue() throws {
    let host = WindowHost()
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    host.containerLayer.addSublayer(layer)
    layer.position = CGPoint(x: 0, y: 0)

    let harness = AnimationHarness()
    harness.animate(layer, keyPath: "position.x", to: 100, duration: 1.0)

    // Let the animation run partway (real run loop pumped, §1 above) so presentation()
    // has moved away from both the original (0) and the final (100) value.
    host.pump(for: 0.25)
    let midFlight = layer.presentation()?.value(forKeyPath: "position.x") as? CGFloat
    let midpoint = try #require(midFlight)
    #expect(midpoint > 0)
    #expect(midpoint < 100)

    // Retarget mid-motion (repeated tap, §1 implementation-plan-5.md): new animation must
    // start from the visible (presentation) value, not jump back to 0 or to the old target.
    let previousAnimation = layer.animation(forKey: "position.x")
    harness.animate(layer, keyPath: "position.x", to: 50, duration: 1.0)
    let retargeted = layer.animation(forKey: "position.x") as? CABasicAnimation
    let retargetedFrom = try #require(retargeted?.fromValue as? CGFloat)
    #expect(
        abs(retargetedFrom - midpoint) < 5,
        "retarget must start near the presentation value, not from 0 or 100"
    )
    #expect((retargeted?.toValue as? CGFloat) == 50)
    // A genuinely new animation instance replaced the old one for this key (D66 point 3).
    #expect(retargeted !== previousAnimation)
}

@Test @MainActor
func m02_detachedLayerHasNoPresentationSoRetargetFallsBackToModelValue() {
    // Never added to any superlayer/window — CA never runs a display cycle for it, so
    // presentation() stays nil (D66 point 1's "при отсутствии presentation" branch). This
    // is the one test in this file that must NOT mount its layer (see file-level note).
    let detached = CALayer()
    detached.position = CGPoint(x: 7, y: 7)
    #expect(detached.presentation() == nil)

    let harness = AnimationHarness()
    harness.animate(detached, keyPath: "position.x", to: 40, duration: 1.0)
    let animation = detached.animation(forKey: "position.x") as? CABasicAnimation
    // Falls back to the prior *model* value (7), not to 0 or some other default. A
    // detached layer's own `add(_:forKey:)` may itself be unreliable in a cold process
    // (file-level note) — that risk is orthogonal to what this test checks (the *value*
    // used for `fromValue` when there is no presentation), so the animation object itself
    // is required to exist before asserting on its `fromValue`.
    #expect(animation != nil)
    #expect((animation?.fromValue as? CGFloat) == 7)
}

@Test @MainActor
func m02_sameTargetRepeatDoesNotRestartTheActiveAnimation() {
    let host = WindowHost()
    let layer = CALayer()
    host.containerLayer.addSublayer(layer)
    let harness = AnimationHarness()

    let firstToken = harness.animate(layer, keyPath: "opacity", to: 0.5, duration: 1.0)
    let firstAnimation = layer.animation(forKey: "opacity")

    // Re-fired with the identical target — D64: must not restart or interrupt.
    let secondToken = harness.animate(layer, keyPath: "opacity", to: 0.5, duration: 1.0)
    let secondAnimation = layer.animation(forKey: "opacity")

    #expect(firstToken == secondToken)
    #expect(
        firstAnimation === secondAnimation,
        "identical animation instance, not a fresh one with reset elapsed time"
    )
}

@Test @MainActor
func m02_noneIsAnImmediateSnapWithNoAnimationObjectAtAll() {
    let host = WindowHost()
    let layer = CALayer()
    host.containerLayer.addSublayer(layer)
    layer.opacity = 1
    let harness = AnimationHarness()

    let token = harness.animate(layer, keyPath: "opacity", to: 0.3, duration: 0)
    #expect(token == nil)
    #expect(layer.animation(forKey: "opacity") == nil)
    #expect(layer.opacity == 0.3, "model value applied synchronously, actions disabled")
}

@Test @MainActor
func m02_twoIndependentPropertiesDoNotInterruptEachOther() {
    let host = WindowHost()
    let layer = CALayer()
    host.containerLayer.addSublayer(layer)
    let harness = AnimationHarness()

    harness.animate(layer, keyPath: "position.x", to: 100, duration: 1.0)
    let positionAnimation = layer.animation(forKey: "position.x")

    // A different property, same layer, same call site pattern (D66: "изменение другого
    // свойства тоже его не отменяет").
    harness.animate(layer, keyPath: "opacity", to: 0.5, duration: 1.0)

    #expect(layer.animation(forKey: "position.x") === positionAnimation)
    #expect(layer.animation(forKey: "opacity") != nil)
}

@Test @MainActor
func m02_completionLogicIgnoresAStaleTokenAndAcceptsTheCurrentOne() {
    // §1 above / AnimationHarness.completeIfCurrent's doc comment: real CA completion
    // delivery (CATransaction.setCompletionBlock and CAAnimationDelegate alike) does not
    // fire inside this XCTest-hosted process on this toolchain, verified by exhausting
    // both mechanisms with generous pump windows before writing this test this way — so
    // this drives the actual cleanup logic directly, simulating exactly the sequence a
    // real retarget produces: token 0 registered, replaced by token 1 (D66 point 3), then
    // both callbacks eventually arrive in issue order.
    let host = WindowHost()
    let layer = CALayer()
    host.containerLayer.addSublayer(layer)
    let harness = AnimationHarness()

    let staleToken = harness.animate(layer, keyPath: "position.x", to: 100, duration: 1.0)!
    let freshToken = harness.animate(layer, keyPath: "position.x", to: 40, duration: 1.0)!
    #expect(staleToken != freshToken)
    #expect(harness.currentToken(forKeyPath: "position.x") == freshToken)

    // The stale animation's own eventual callback, arriving after it was already replaced.
    harness.completeIfCurrent(keyPath: "position.x", token: staleToken)
    #expect(!harness.completedTokens.contains(staleToken))
    #expect(harness.staleCompletionsIgnored.contains(staleToken))
    #expect(
        harness.currentToken(forKeyPath: "position.x") == freshToken,
        "a stale callback must not clear the still-active current token"
    )

    // The fresh animation's own callback.
    harness.completeIfCurrent(keyPath: "position.x", token: freshToken)
    #expect(harness.completedTokens.contains(freshToken))
    #expect(
        harness.currentToken(forKeyPath: "position.x") == nil,
        "cleaned up after completion, not left dangling"
    )
}

@Test @MainActor
func m02_completionBlockCompilesUnderStrictConcurrencyWithoutUnsafeConcurrencyEscapes() {
    // Compile-time proof for D66/D67's "способ безопасного хопа из CA callback на
    // MainActor" — not a behavioral test (real delivery is covered by the previous test's
    // doc comment: it does not fire in this hosted process). `AnimationHarness.animate`
    // above already builds and this whole file compiles clean under
    // `-Xswiftc -warnings-as-errors` with `SWIFT_STRICT_CONCURRENCY=complete`
    // (verify_bootstrap.py/check_all.py) using a plain `@MainActor [weak self] in` closure
    // passed to `CATransaction.setCompletionBlock` — no `@unchecked Sendable`,
    // `nonisolated(unsafe)` or `@preconcurrency` anywhere (AGENTS ban). This test exists so
    // that fact has a named, findable anchor instead of being an implicit side effect of
    // the file merely compiling.
    let host = WindowHost()
    let layer = CALayer()
    host.containerLayer.addSublayer(layer)
    let harness = AnimationHarness()
    harness.animate(layer, keyPath: "opacity", to: 0.5, duration: 0.05)
    #expect(layer.animation(forKey: "opacity") != nil)
}

// MARK: - D65 two-layer contract under an active outer animation (совместно с T02)

/// Extends T02's `RasterHarness` shape (TextRasterPrototypeTests.swift) with an explicit
/// outer-layer animation — T02 only exercised instantaneous (actions-disabled) moves/
/// resizes; this is the same two-layer raster contract while the outer layer is actually
/// mid-flight, which T02 explicitly left to M02 (see t02-raster-prototype.md §2).
@MainActor
private final class AnimatedCardHarness {
    let outer = CALayer()
    let inner = CALayer()
    private let animator = AnimationHarness()
    private(set) var rasterCallCount = 0

    init(mountedUnder container: CALayer) {
        outer.addSublayer(inner)
        container.addSublayer(outer)
    }

    private func raster(text: String, width: CGFloat) -> CGImage {
        rasterCallCount += 1
        return RasterProbe.run(text: text, pointSize: 15, maxWidth: width, scale: 2).image
    }

    func commitInitialContents(text: String, width: CGFloat) {
        let image = raster(text: text, width: width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.contents = image
        CATransaction.commit()
    }

    /// Move: only the outer layer's `position` animates — D65 "внешний слой анимирует
    /// position/bounds ... внутренний слой обновляется без actions" — no raster job, no
    /// change to inner's contents identity, for a pure move.
    func animatedMove(to target: CGFloat, duration: CFTimeInterval) {
        animator.animate(outer, keyPath: "position.x", to: target, duration: duration)
    }

    /// Resize: outer bounds animates explicitly; inner's bounds/content-area tracks the
    /// same animation (mirrored, same duration/curve) so cropping stays correct through
    /// the animated frames — D65 "старый bitmap ... обрезается по content area до
    /// готовности нового" only makes sense if the content area itself is moving in step
    /// with the outer bounds, not snapping ahead of or behind it.
    func animatedResize(toWidth width: CGFloat, duration: CFTimeInterval) {
        animator.animate(outer, keyPath: "bounds.size.width", to: width, duration: duration)
        animator.animate(inner, keyPath: "bounds.size.width", to: width, duration: duration)
    }

    func replaceContentsWhenReady(text: String, width: CGFloat) {
        let fresh = raster(text: text, width: width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.contents = fresh
        CATransaction.commit()
    }

    func currentContentsIdentity() -> ObjectIdentifier? {
        guard let contents = inner.contents else { return nil }
        return ObjectIdentifier(contents as! CGImage)
    }
}

@Test @MainActor
func m02_animatedMoveDoesNotRerasterAndInnerLayerHasNoAnimationOfItsOwn() {
    let host = WindowHost()
    let harness = AnimatedCardHarness(mountedUnder: host.containerLayer)
    harness.commitInitialContents(text: "Move me", width: 200)
    let before = harness.currentContentsIdentity()

    harness.animatedMove(to: 120, duration: 0.5)

    #expect(harness.rasterCallCount == 1)
    #expect(harness.currentContentsIdentity() == before)
    #expect(harness.outer.animation(forKey: "position.x") != nil)
    #expect(
        harness.inner.animation(forKey: "position.x") == nil,
        "raster sublayer never gets its own position animation"
    )
}

@Test @MainActor
func m02_animatedResizeKeepsOldBitmapUntilReplacementWhileBoundsAnimateInStep() {
    let host = WindowHost()
    let harness = AnimatedCardHarness(mountedUnder: host.containerLayer)
    harness.commitInitialContents(text: "Resizable content area", width: 200)
    let old = harness.currentContentsIdentity()

    harness.animatedResize(toWidth: 100, duration: 0.5)
    // Old bitmap is untouched mid-flight — atomic swap only happens when a fresh raster
    // arrives, exactly like T02's non-animated resize test, now with bounds actually
    // mid-animation on both layers rather than snapped instantly.
    #expect(harness.currentContentsIdentity() == old)
    #expect(harness.outer.animation(forKey: "bounds.size.width") != nil)
    #expect(harness.inner.animation(forKey: "bounds.size.width") != nil)

    harness.replaceContentsWhenReady(text: "Resizable content area", width: 100)
    #expect(harness.currentContentsIdentity() != old)
    #expect(harness.rasterCallCount == 2)
}

@Test @MainActor
func m02_textChangeDuringAnAnimatedMoveStillDropsStaleContentsFirst() {
    let host = WindowHost()
    let harness = AnimatedCardHarness(mountedUnder: host.containerLayer)
    harness.commitInitialContents(text: "Original text", width: 200)

    harness.animatedMove(to: 80, duration: 0.5)

    // D65's "temporary emptiness is acceptable, stale text is not" holds regardless of
    // whether the outer layer happens to be mid-animation at the same time.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    harness.inner.contents = nil
    CATransaction.commit()
    #expect(harness.inner.contents == nil)

    harness.replaceContentsWhenReady(text: "Changed text", width: 200)
    #expect(harness.currentContentsIdentity() != nil)
    #expect(
        harness.outer.animation(forKey: "position.x") != nil,
        "unrelated outer motion was not disturbed by the content swap"
    )
}
