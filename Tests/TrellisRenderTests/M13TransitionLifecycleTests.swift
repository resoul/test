import CoreGraphics
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

// M13 — lifecycle/AX/platform completeness pass (implementation-plan-5.md §6), covering what
// M11 (`docs/validation/m11-transition-session.md`) and M12
// (`docs/validation/m12-progress-and-gesture.md`) explicitly left open: host resize mid-
// transition, a source that disappears while heading toward `.closed`, and stale-callback/
// released-artifact discipline across prepare-cancellation and closing-interrupted-by-detach.
// Reuses M11's `TransitionWindowHost`/`ExpandTransitionHarness` shape (own copies in this file,
// same precedent M10/M11/M12 each already followed for their own window-host harnesses).

@MainActor
private final class TransitionWindowHost {
    let hostLayer: CALayer
    #if canImport(AppKit)
        private let window: NSWindow
    #elseif canImport(UIKit)
        private let window: UIWindow
    #endif

    init() {
        #if canImport(AppKit)
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            view.wantsLayer = true
            window = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            hostLayer = view.layer ?? CALayer()
        #elseif canImport(UIKit)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            let view = UIView(frame: window.bounds)
            window.addSubview(view)
            window.makeKeyAndVisible()
            hostLayer = view.layer
        #endif
    }
}

@MainActor
private final class ExpandTransitionHarness {
    let root = Node()
    let card = Node()
    let cardTitle = TextNode(text: "Composite transition prototype card")
    let page = Node()
    let pageTitle = TextNode(
        text: "Composite transition prototype card, now on its own page with much more room"
    )
    let bridge: NodeHostBridge
    private let host = TransitionWindowHost()

    init(mountPageImmediately: Bool = true) {
        bridge = NodeHostBridge(hostLayer: host.hostLayer)

        root.style.flexDirection = .column
        card.style.width = 300
        card.style.height = 120
        card.appearance.background = .color(ThemeColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1))
        card.appearance.cornerRadius = 16
        card.addSubnode(cardTitle)
        cardTitle.style.width = 260
        cardTitle.style.height = 40

        page.style.width = 390
        page.style.height = 560
        page.appearance.background = .color(ThemeColor(red: 1, green: 1, blue: 1, alpha: 1))
        page.appearance.cornerRadius = 0
        page.addSubnode(pageTitle)
        pageTitle.style.width = 350
        pageTitle.style.height = 80

        root.addSubnode(card)
        if mountPageImmediately { root.addSubnode(page) }

        _ = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 390, height: 700),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
    }

    func waitForCommit() async {
        let before = bridge.statistics.committed
        for _ in 0..<20_000 where bridge.statistics.committed <= before { await Task.yield() }
    }

    var request: NodeHostBridge.TransitionRequest {
        NodeHostBridge.TransitionRequest(
            source: card.id,
            destinationRoot: page.id,
            roles: [
                .init(role: .hero, source: card.id, destination: page.id),
                .init(role: .title, source: cardTitle.id, destination: pageTitle.id),
            ],
            // Deliberately long: every test in this file either force-completes explicitly
            // (`forceCompleteTransitionMotionForTesting()`) or asserts mid-flight state before
            // any real completion could land — a short duration risks the real `CATransaction`
            // completion actually firing under a slow/parallel full-suite run (unlike a solo
            // `--filter` run) and racing the assertion, exactly the flake class M10/M12's own
            // reports already document for this toolchain's completion-block timing.
            duration: .seconds(30)
        )
    }
}

// MARK: - Host resize during an active transition

@Test @MainActor
func m13_resizeMidOpeningRetargetsUnderNewLayoutWithoutRestarting() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()

    #expect(harness.bridge.presentTransition(harness.request))
    let opening = try #require(harness.bridge.transitionSession)
    #expect(opening.state == .opening)
    let overlay = opening.overlayLayer
    let tokenBeforeResize = opening.token

    // A host resize that changes the destination's committed frame while opening is in flight.
    harness.page.style.width = 500
    harness.page.style.height = 900
    harness.bridge.updateBounds(LayoutFrame(width: 500, height: 900), scale: 2)
    await harness.waitForCommit()

    let resized = try #require(harness.bridge.transitionSession)
    #expect(resized.state == .opening, "resize does not reopen or restart the session")
    #expect(resized.overlayLayer === overlay, "same overlay, not a second copy")
    #expect(resized.token != tokenBeforeResize, "geometry retargeted for the new layout")

    let widthAnimation =
        overlay.animation(forKey: "trellis.transition.bounds.size.width")
        as? CABasicAnimation
    let targetWidth = try #require(widthAnimation?.toValue as? CGFloat)
    #expect(abs(targetWidth - 500) < 1, "armed target now reflects the new destination rect")

    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession?.state == .presented)
}

@Test @MainActor
func m13_resizeDuringSettlingRetargetsTheSameLogicalEndpoint() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession?.state == .presented)

    #expect(harness.bridge.closeTransition())
    let settling = try #require(harness.bridge.transitionSession)
    guard case let .settling(targetBefore) = settling.state else {
        Issue.record("expected settling, got \(settling.state)")
        return
    }
    #expect(targetBefore == .closed)
    let tokenBeforeResize = settling.token

    harness.page.style.width = 300
    harness.bridge.updateBounds(LayoutFrame(width: 320, height: 700), scale: 2)
    await harness.waitForCommit()

    let resized = try #require(harness.bridge.transitionSession)
    guard case let .settling(targetAfter) = resized.state else {
        Issue.record("resize must not change the decided settle target")
        return
    }
    #expect(targetAfter == .closed, "still settling to the same logical endpoint (D72)")
    #expect(resized.token != tokenBeforeResize, "geometry retargeted under the new layout")

    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession == nil)
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 1)
}

// MARK: - Source disappears mid-closing (M11 covered `preparing` only)

@Test @MainActor
func m13_sourceRemovedDuringInteractiveClosingFadesInsteadOfFlyingToAStaleRect() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession?.state == .presented)

    #expect(harness.bridge.beginTransitionGesture())
    #expect(harness.bridge.transitionSession?.state == .interactiveClosing)
    harness.bridge.updateTransitionGesture(deltaProgress: 0.3)
    let overlay = try #require(harness.bridge.transitionSession?.overlayLayer)

    // The source card disappears from the tree mid-gesture (e.g. removed by a data update)
    // while the user is still dragging.
    harness.card.removeFromSupernode()
    await harness.waitForCommit()

    let reconciled = try #require(harness.bridge.transitionSession)
    #expect(reconciled.state == .interactiveClosing, "gesture stays live, not force-ended")
    #expect(
        overlay.animation(forKey: "trellis.transition.position.x") == nil,
        "no longer flying toward the now-invalid source rect"
    )
    let opacityAnimation =
        overlay.animation(forKey: "trellis.transition.opacity")
        as? CABasicAnimation
    let opacityTarget = try #require(opacityAnimation?.toValue as? Float)
    #expect(opacityTarget == 0, "fades out instead (D72)")

    // Finish the gesture — must complete cleanly even though `source` no longer resolves.
    #expect(harness.bridge.endTransitionGesture(velocity: 5))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession == nil)
    #expect(!harness.bridge.hasTransitionOverlayForTesting)
}

@Test @MainActor
func m13_sourceRemovedDuringNonInteractiveSettlingFadesInsteadOfFlyingToAStaleRect() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession?.state == .presented)

    #expect(harness.bridge.closeTransition())
    let overlay = try #require(harness.bridge.transitionSession?.overlayLayer)
    guard case .settling(.closed) = harness.bridge.transitionSession?.state else {
        Issue.record("expected settling(.closed)")
        return
    }

    harness.card.removeFromSupernode()
    await harness.waitForCommit()

    #expect(harness.bridge.transitionSession != nil, "still settling, not aborted")
    #expect(overlay.animation(forKey: "trellis.transition.position.x") == nil)
    let opacityAnimation =
        overlay.animation(forKey: "trellis.transition.opacity")
        as? CABasicAnimation
    #expect((opacityAnimation?.toValue as? Float) == 0)

    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession == nil)
    #expect(!harness.bridge.hasTransitionOverlayForTesting)
}

// MARK: - Epoch/token discipline for late callbacks and cancellation cleanup

@Test @MainActor
func m13_prepareCancellationReleasesEveryTemporaryArtifact() async throws {
    let harness = ExpandTransitionHarness(mountPageImmediately: false)
    await harness.waitForCommit()

    harness.root.addSubnode(harness.page)
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(harness.bridge.transitionSession?.state == .preparing)
    #expect(harness.bridge.hasTransitionOverlayForTesting, "overlay exists even while preparing")

    harness.card.removeFromSupernode()
    await harness.waitForCommit()

    #expect(harness.bridge.transitionSession == nil, "prepare-cancellation clears the session")
    #expect(!harness.bridge.hasTransitionOverlayForTesting, "overlay released")
    #expect(harness.bridge.transitionRasterLayerCountForTesting == 0, "no leaked title rasters")
}

@Test @MainActor
func m13_closingInterruptedByDetachReleasesEveryTemporaryArtifact() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.closeTransition())
    #expect(harness.bridge.hasTransitionOverlayForTesting)
    #expect(harness.bridge.transitionRasterLayerCountForTesting == 2)

    // Detach lands mid-`settling`, before the automatic close ever completes.
    harness.bridge.detach()

    #expect(harness.bridge.transitionSession == nil)
    #expect(!harness.bridge.hasTransitionOverlayForTesting)
    #expect(harness.bridge.transitionRasterLayerCountForTesting == 0)
}

@Test @MainActor
func m13_lateCompletionAfterDetachIsIgnoredAndANewSessionOnAFreshMountIsUnaffected() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(harness.bridge.transitionSession?.state == .opening)

    // Detach before the automatic open ever completes — bumps `TransitionAnimator`'s own token
    // (`finishInPlace`), so a completion block already queued on the run loop for the old
    // `play()` call would find its captured token stale and become a no-op (D66's rule, applied
    // here at the whole-session token M11/M12 already rely on elsewhere in this file).
    harness.bridge.detach()
    #expect(harness.bridge.transitionSession == nil)

    // A brand-new mount and session on the same bridge must start clean — nothing from the
    // torn-down session leaks forward (stale token, stale overlay, stale AX policy).
    let fresh = ExpandTransitionHarness()
    await fresh.waitForCommit()
    #expect(fresh.bridge.presentTransition(fresh.request))
    #expect(fresh.bridge.transitionSession?.state == .opening)
    #expect(fresh.bridge.transitionRasterLayerCountForTesting == 2)
    fresh.bridge.forceCompleteTransitionMotionForTesting()
    #expect(fresh.bridge.transitionSession?.state == .presented)
    #expect(fresh.card.accessibility.childrenPolicy == .hide)
}

// MARK: - Suspend/detach on every M12-introduced gesture state

@Test @MainActor
func m13_suspendDuringInteractiveClosingStartedFromPresentedFinishesToPresented() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()

    #expect(harness.bridge.beginTransitionGesture())
    harness.bridge.updateTransitionGesture(deltaProgress: 0.6)
    #expect(harness.bridge.transitionSession?.state == .interactiveClosing)

    harness.bridge.suspend()

    #expect(
        harness.bridge.transitionSession?.state == .presented,
        "D73: незавершённый interactiveClosing -> presented, regardless of gesture progress"
    )
    #expect(!harness.bridge.hasTransitionOverlayForTesting)
    #expect(harness.bridge.focusScopeID == harness.page.id, "modal scope holds through suspend")
}

@Test @MainActor
func m13_detachDuringInteractiveClosingStartedFromOpeningClearsTheSessionImmediately()
    async throws
{
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(harness.bridge.transitionSession?.state == .opening)
    #expect(harness.bridge.beginTransitionGesture(), "grabs the in-flight open")
    #expect(harness.bridge.transitionSession?.state == .interactiveClosing)

    harness.bridge.detach()

    #expect(harness.bridge.transitionSession == nil)
    #expect(!harness.bridge.hasTransitionOverlayForTesting)
}

// MARK: - Transition-hidden layers survive an unrelated later commit

@Test @MainActor
func m13_presentedSourceStaysHiddenThroughAnUnrelatedLaterPaintOnlyCommit() async throws {
    // Real bug found running S29 in the iOS Simulator (docs/defects.md): `completeTransitionMotion`
    // used to write `renderer.layer(for:)?.opacity = 0` directly on the source's real `CALayer`,
    // bypassing `Node.style.visual.opacity`. `LayerRenderer.applyPresentation(of:to:)` then
    // unconditionally recomputed `layer.opacity` from the (unchanged) model value on the very
    // next paint-only commit — silently un-hiding the source. Fixed by
    // `LayerRenderer.setTransitionHidden(_:hidden:)`, which makes the hide an input to that same
    // computation instead of a one-shot write something else immediately overwrites.
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession?.state == .presented)
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 0, "hidden once presented")

    // An unrelated paint-only commit — some other node's appearance changes, nothing to do with
    // the transition — must not resurrect the hidden source.
    harness.page.appearance.cornerRadius = 24
    await harness.waitForCommit()

    #expect(
        harness.bridge.layer(for: harness.card.id)?.opacity == 0,
        "source stays hidden through an unrelated later commit"
    )
}

@Test @MainActor
func m13_closedDestinationStaysHiddenThroughAnUnrelatedLaterPaintOnlyCommit() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.closeTransition())
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession == nil)
    #expect(harness.bridge.layer(for: harness.page.id)?.opacity == 0, "hidden once closed")
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 1, "source visible again")

    harness.card.appearance.cornerRadius = 20
    await harness.waitForCommit()

    #expect(
        harness.bridge.layer(for: harness.page.id)?.opacity == 0,
        "destination stays hidden through an unrelated later commit"
    )
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 1)
}

// MARK: - Handing a gesture-frozen layer back to automatic playback must actually resume

@Test @MainActor
func m13_settlingAfterAGestureResumesRealPlaybackInsteadOfStayingFrozen() async throws {
    // Real bug found running S29's real `UIPanGestureRecognizer` in the iOS Simulator
    // (`docs/defects.md`): `arm`/`freezeForGesture` park a layer at `speed = 0` for manual
    // scrubbing; `endManual()` only cleared the internal `isManual` flag, never the layer's own
    // `speed`/`timeOffset` — so the fresh `CABasicAnimation` `play()` added right afterward, to
    // settle automatically, was added to a layer whose own media clock was still frozen. It
    // never advanced: `completion` (and with it `completeTransitionMotion`/`transition-closed`)
    // never fired, confirmed to hang indefinitely in a real run (deterministic tests never
    // caught this — they all use `forceCompleteTransitionMotionForTesting()`, which never
    // depends on the layer's clock actually advancing). Fixed in `TransitionAnimator.play`:
    // every armed layer's `speed`/`timeOffset`/`beginTime` are unconditionally normalized after
    // its animation is added.
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()

    #expect(harness.bridge.beginTransitionGesture())
    harness.bridge.updateTransitionGesture(deltaProgress: 0.6)
    let overlay = try #require(harness.bridge.transitionSession?.overlayLayer)
    #expect(overlay.speed == 0, "parked for manual scrubbing")

    #expect(harness.bridge.endTransitionGesture(velocity: 5))
    #expect(
        overlay.speed == 1,
        "handed back to automatic playback must resume the layer's own clock, not leave it frozen"
    )
    #expect(overlay.timeOffset == 0)

    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession == nil)
}

// MARK: - Focus restoration across every close path

@Test @MainActor
func m13_focusRestoresToTheTriggeringElementAfterGestureFinishCloses() async throws {
    let harness = ExpandTransitionHarness()
    harness.card.focus.isFocusable = true
    await harness.waitForCommit()
    if case .moved = harness.bridge.focus(harness.card.id) {
    } else {
        Issue.record("focus(card) must succeed")
    }
    #expect(harness.bridge.focusedID == harness.card.id)

    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.focusScopeID == harness.page.id)

    #expect(harness.bridge.beginTransitionGesture())
    harness.bridge.updateTransitionGesture(deltaProgress: 0.9)
    #expect(harness.bridge.endTransitionGesture(velocity: 5), "past threshold -> closes")
    harness.bridge.forceCompleteTransitionMotionForTesting()

    #expect(harness.bridge.transitionSession == nil)
    #expect(harness.bridge.focusScopeID == nil, "modal scope cleared")
    #expect(
        harness.bridge.focusedID == harness.card.id,
        "D40 restoration returns focus to the element that opened the transition"
    )
}

@Test @MainActor
func m13_focusRestoresToTheTriggeringElementAfterSystemCancelledGestureBouncesBackToPresented()
    async throws
{
    let harness = ExpandTransitionHarness()
    harness.card.focus.isFocusable = true
    await harness.waitForCommit()
    if case .moved = harness.bridge.focus(harness.card.id) {
    } else {
        Issue.record("focus(card) must succeed")
    }

    #expect(harness.bridge.presentTransition(harness.request))
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.beginTransitionGesture())
    harness.bridge.updateTransitionGesture(deltaProgress: 0.8)

    #expect(harness.bridge.cancelTransitionGestureSystemInterrupted())
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(
        harness.bridge.transitionSession?.state == .presented,
        "system interruption bounces back to presented, not stuck"
    )
    #expect(harness.bridge.focusScopeID == harness.page.id, "still modally scoped to the page")

    #expect(harness.bridge.closeTransition())
    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.focusedID == harness.card.id)
}
