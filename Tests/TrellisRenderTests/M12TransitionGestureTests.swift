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

// M12 — общий progress и отменяемый жест (implementation-plan-5.md §6, settled by
// docs/validation/m10-transition-contract.md §1.3/D72, implemented in docs/validation/
// m12-progress-and-gesture.md). These tests drive `NodeHostBridge.beginTransitionGesture()`/
// `updateTransitionGesture(deltaProgress:)`/`endTransitionGesture(velocity:)`/
// `cancelTransitionGestureSystemInterrupted()` directly — the deterministic-unit-test half of
// the acceptance line ("нативный прогон жеста дополняет детерминированные тесты, не заменяется
// ими"). The complementary real-touch run — an actual `UIPanGestureRecognizer` recognized from
// real Simulator touch events driving `TrellisUIKit.TransitionGestureController` — is not
// reproducible inside this XCTest/Swift-Testing process (no touch delivery, no live run loop
// tracking real gesture state, the same class of limitation M02 §1.4 documents for CA completion
// callbacks); it is instead exercised through the Playground app on a real iOS Simulator and
// documented with its own evidence in docs/validation/m12-progress-and-gesture.md, not faked
// here with a private-API `state` injection into a real recognizer instance.

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

/// Same `.expand` composition M11's own harness uses (`hero` + `title` roles) — a separate copy
/// in this file, the same precedent M10/M11 already set for a per-file harness copy.
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
    let host = TransitionWindowHost()

    init(duration: Duration = .milliseconds(2000)) {
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
        root.addSubnode(page)

        self.duration = duration
        _ = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 390, height: 700),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
    }

    private let duration: Duration

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
            duration: duration
        )
    }

    /// Presents and force-completes to `.presented` — the starting point for every test that
    /// exercises a fresh dismiss gesture (`.closingFromPresented`).
    func presentAndComplete() async {
        await waitForCommit()
        #expect(bridge.presentTransition(request))
        bridge.forceCompleteTransitionMotionForTesting()
    }
}

@Test @MainActor
func m12_gestureGrabbingAnInFlightOpenContinuesProgressWithoutResettingOrJumping() async throws {
    // A duration no machine load can outrun (defect #60): with 2 s, a busy full-suite run kept
    // the main actor away long enough for the automatic open to finish before the grab.
    let harness = ExpandTransitionHarness(duration: .seconds(60))
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(harness.bridge.transitionSession?.state == .opening)

    let overlay = try #require(harness.bridge.transitionSession?.overlayLayer)
    // Let real automatic playback advance partway through the long duration.
    try await Task.sleep(for: .milliseconds(150))
    let beforeGrab =
        (overlay.presentation()?.value(forKeyPath: "position.x") as? CGFloat)
        ?? overlay.position.x

    #expect(harness.bridge.beginTransitionGesture())
    let session = try #require(harness.bridge.transitionSession)
    #expect(session.state == .interactiveClosing)
    #expect(
        session.progress > 0 && session.progress < 1,
        "D72: progress continues from wherever automatic opening had gotten to, not reset to 0"
    )

    let afterGrab =
        (overlay.presentation()?.value(forKeyPath: "position.x") as? CGFloat) ?? overlay.position.x
    #expect(
        abs(afterGrab - beforeGrab) < 1,
        "freezing an in-flight open into gesture control must not visually jump"
    )
    #expect(
        harness.bridge.sceneReadiness?.animationReady == false,
        "D69: still busy while a gesture holds the session"
    )
}

@Test @MainActor
func m12_manualScrubReversalStaysOnTheSameSessionAndOverlay() async throws {
    let harness = ExpandTransitionHarness()
    await harness.presentAndComplete()

    #expect(harness.bridge.beginTransitionGesture())
    #expect(harness.bridge.transitionSession?.progress == 0)
    // Captured after `beginTransitionGesture()`, which — like `closeTransition()` — mints a
    // fresh overlay/token when it starts a new dismiss from `.presented` (M11's own pattern);
    // what this test actually checks is that *scrubbing* afterward never mints another one.
    let overlay = try #require(harness.bridge.transitionSession?.overlayLayer)
    let token = try #require(harness.bridge.transitionSession?.token)

    harness.bridge.updateTransitionGesture(deltaProgress: 0.3)
    let atThirty = try #require(harness.bridge.transitionSession?.progress)
    #expect(abs(atThirty - 0.3) < 0.0001)

    harness.bridge.updateTransitionGesture(deltaProgress: 0.4)
    let atSeventy = try #require(harness.bridge.transitionSession?.progress)
    #expect(abs(atSeventy - 0.7) < 0.0001)

    // Reversal (D72): dragging back is the same driver scrubbed the other way, not a rearm.
    harness.bridge.updateTransitionGesture(deltaProgress: -0.5)
    let afterReverse = try #require(harness.bridge.transitionSession?.progress)
    #expect(abs(afterReverse - 0.2) < 0.0001)

    #expect(harness.bridge.transitionSession?.overlayLayer === overlay, "same overlay throughout")
    #expect(harness.bridge.transitionSession?.token == token, "no rearm/new token from scrubbing")
    #expect(
        harness.bridge.transitionRasterLayerCountForTesting == 2,
        "reversal does not re-measure/re-raster the title endpoints"
    )
}

@Test @MainActor
func m12_progressClampsToZeroAndOneAndDoesNotOverOrUndershoot() async throws {
    let harness = ExpandTransitionHarness()
    await harness.presentAndComplete()
    #expect(harness.bridge.beginTransitionGesture())

    harness.bridge.updateTransitionGesture(deltaProgress: -0.5)
    #expect(harness.bridge.transitionSession?.progress == 0, "clamped at the lower bound")

    harness.bridge.updateTransitionGesture(deltaProgress: 2.0)
    #expect(harness.bridge.transitionSession?.progress == 1, "clamped at the upper bound")
}

@Test @MainActor
func m12_repeatedGestureBeginOnAnAlreadyInteractiveSessionIsIdempotent() async throws {
    let harness = ExpandTransitionHarness()
    await harness.presentAndComplete()
    #expect(harness.bridge.beginTransitionGesture())
    let overlay = try #require(harness.bridge.transitionSession?.overlayLayer)
    let token = try #require(harness.bridge.transitionSession?.token)
    harness.bridge.updateTransitionGesture(deltaProgress: 0.4)

    // "Starting a close gesture again on an already-closing session" (checklist) — no second
    // overlay, no new token, no lost progress.
    #expect(harness.bridge.beginTransitionGesture())
    #expect(harness.bridge.transitionSession?.overlayLayer === overlay)
    #expect(harness.bridge.transitionSession?.token == token)
    #expect(abs((harness.bridge.transitionSession?.progress ?? -1) - 0.4) < 0.0001)
    #expect(harness.bridge.transitionRasterLayerCountForTesting == 2)
}

@Test @MainActor
func m12_boundaryProgressAtThresholdSettlesClosedJustBelowSettlesPresented() async throws {
    // At the threshold (0.5): decides closed.
    let atThreshold = ExpandTransitionHarness()
    await atThreshold.presentAndComplete()
    #expect(atThreshold.bridge.beginTransitionGesture())
    atThreshold.bridge.updateTransitionGesture(deltaProgress: 0.5)
    #expect(atThreshold.bridge.endTransitionGesture(velocity: 0))
    guard case let .settling(target) = atThreshold.bridge.transitionSession?.state else {
        Issue.record("expected settling")
        return
    }
    #expect(target == .closed, "D72: threshold is inclusive")

    // Just below the threshold (0.499): decides presented.
    let justBelow = ExpandTransitionHarness()
    await justBelow.presentAndComplete()
    #expect(justBelow.bridge.beginTransitionGesture())
    justBelow.bridge.updateTransitionGesture(deltaProgress: 0.499)
    #expect(justBelow.bridge.endTransitionGesture(velocity: 0))
    guard case let .settling(target) = justBelow.bridge.transitionSession?.state else {
        Issue.record("expected settling")
        return
    }
    #expect(target == .presented)
}

@Test @MainActor
func m12_boundaryVelocityAtThresholdSettlesClosedJustBelowSettlesPresented() async throws {
    // Progress alone (0.1) is nowhere near the 0.5 progress threshold — only velocity decides.
    let atThreshold = ExpandTransitionHarness()
    await atThreshold.presentAndComplete()
    #expect(atThreshold.bridge.beginTransitionGesture())
    atThreshold.bridge.updateTransitionGesture(deltaProgress: 0.1)
    #expect(atThreshold.bridge.endTransitionGesture(velocity: 1.2))
    guard case let .settling(target) = atThreshold.bridge.transitionSession?.state else {
        Issue.record("expected settling")
        return
    }
    #expect(target == .closed, "D72: velocity threshold is inclusive too")

    let justBelow = ExpandTransitionHarness()
    await justBelow.presentAndComplete()
    #expect(justBelow.bridge.beginTransitionGesture())
    justBelow.bridge.updateTransitionGesture(deltaProgress: 0.1)
    #expect(justBelow.bridge.endTransitionGesture(velocity: 1.199))
    guard case let .settling(target) = justBelow.bridge.transitionSession?.state else {
        Issue.record("expected settling")
        return
    }
    #expect(target == .presented)
}

@Test @MainActor
func m12_gestureGrabbedDuringOpeningUsesTheOpeningRelativeThresholdOrientation() async throws {
    // A gesture that grabs an in-flight open runs progress 0(closed)...1(presented) — the
    // OPPOSITE local orientation from a fresh dismiss started at `.presented`. Dragging it back
    // toward the source (closing direction) is a *decreasing* `progress`/negative `velocity`;
    // this test pins down that `endTransitionGesture` converts correctly for this origin, not
    // only for the `.closingFromPresented` origin the boundary tests above exercise.
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(harness.bridge.beginTransitionGesture())
    // Force a known progress regardless of how far automatic playback had already gotten.
    let grabbed = try #require(harness.bridge.transitionSession?.progress)
    harness.bridge.updateTransitionGesture(deltaProgress: 0.5 - grabbed)
    #expect(abs((harness.bridge.transitionSession?.progress ?? -1) - 0.5) < 0.0001)

    // At exactly progress 0.5, "how close to closed" is 1 - 0.5 = 0.5 — at the threshold, and a
    // strongly negative velocity (dragging back toward source fast) pushes closing velocity
    // (-velocity) well past 1.2 too, so this must decide closed either way.
    #expect(harness.bridge.endTransitionGesture(velocity: -2.0))
    guard case let .settling(target) = harness.bridge.transitionSession?.state else {
        Issue.record("expected settling")
        return
    }
    #expect(target == .closed)
}

@Test @MainActor
func m12_systemCancelledGestureAlwaysResolvesToPresentedAndIsNotStuck() async throws {
    let harness = ExpandTransitionHarness()
    await harness.presentAndComplete()
    #expect(harness.bridge.beginTransitionGesture())
    // Scrubbed well past the dismissal threshold — a naive "cancel returns you to where you
    // started only if you hadn't crossed the threshold" rule would send this to `.closed`, but
    // a system interruption is not a confirmed dismissal intent (M12's documented choice for an
    // event D72's own table does not enumerate).
    harness.bridge.updateTransitionGesture(deltaProgress: 0.9)

    #expect(harness.bridge.cancelTransitionGestureSystemInterrupted())
    guard case let .settling(target) = harness.bridge.transitionSession?.state else {
        Issue.record("expected settling, not stuck in interactiveClosing")
        return
    }
    #expect(target == .presented)

    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession?.state == .presented)
    #expect(harness.bridge.transitionSession != nil, "session survives — this was not a close")
}

@Test @MainActor
func m12_endToEndFinishAndCancelReachTheDecidedEndpointWithRealText() async throws {
    // Finish path (below threshold -> presented): the session survives, still at .presented.
    let finishHarness = ExpandTransitionHarness()
    await finishHarness.presentAndComplete()
    #expect(finishHarness.bridge.beginTransitionGesture())
    finishHarness.bridge.updateTransitionGesture(deltaProgress: 0.2)
    #expect(finishHarness.bridge.endTransitionGesture(velocity: 0))
    finishHarness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(finishHarness.bridge.transitionSession?.state == .presented)
    #expect(finishHarness.bridge.layer(for: finishHarness.page.id)?.opacity == 1)
    #expect(finishHarness.bridge.layer(for: finishHarness.card.id)?.opacity == 0)

    // Cancel path (above threshold -> closed): the session ends entirely, source restored.
    let cancelHarness = ExpandTransitionHarness()
    await cancelHarness.presentAndComplete()
    #expect(cancelHarness.bridge.beginTransitionGesture())
    cancelHarness.bridge.updateTransitionGesture(deltaProgress: 0.8)
    #expect(cancelHarness.bridge.endTransitionGesture(velocity: 0))
    cancelHarness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(cancelHarness.bridge.transitionSession == nil)
    #expect(cancelHarness.bridge.layer(for: cancelHarness.card.id)?.opacity == 1)
    #expect(cancelHarness.bridge.layer(for: cancelHarness.page.id)?.opacity == 0)
    #expect(!cancelHarness.bridge.hasTransitionOverlayForTesting)
    #expect(cancelHarness.bridge.transitionRasterLayerCountForTesting == 0)
}

@Test @MainActor
func m12_gestureOutsideAnyValidStateIsRejectedWithoutTouchingAnySession() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()
    // No session at all yet.
    #expect(harness.bridge.beginTransitionGesture() == false)
    harness.bridge.updateTransitionGesture(deltaProgress: 0.5)  // no-op, must not crash/create
    #expect(harness.bridge.transitionSession == nil)
    #expect(harness.bridge.endTransitionGesture(velocity: 0) == false)
    #expect(harness.bridge.cancelTransitionGestureSystemInterrupted() == false)

    // `.preparing`: destination not measured yet.
    let preparingHarness = ExpandTransitionHarness()
    preparingHarness.page.removeFromSupernode()
    await preparingHarness.waitForCommit()
    preparingHarness.root.addSubnode(preparingHarness.page)
    #expect(preparingHarness.bridge.presentTransition(preparingHarness.request))
    #expect(preparingHarness.bridge.transitionSession?.state == .preparing)
    #expect(preparingHarness.bridge.beginTransitionGesture() == false)
    #expect(preparingHarness.bridge.transitionSession?.state == .preparing, "untouched")
}
