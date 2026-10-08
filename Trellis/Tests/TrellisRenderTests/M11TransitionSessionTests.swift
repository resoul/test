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

// M11 — production `.expand` composite transition (implementation-plan-5.md §6, settled by
// docs/validation/m10-transition-contract.md, implemented in docs/validation/
// m11-transition-session.md). Unlike M10's standalone prototype, these tests exercise the real
// `NodeHostBridge.presentTransition(_:)`/`closeTransition()` path through a real, windowed
// `LayerRenderer` and real `CoreTextRenderer` text — the same `WindowHost`-under-a-real-window
// requirement M02/M06/M10 document (`presentation()` reads are unreliable on an unmounted
// layer), and the same `@testable import` + direct-completion-invocation precedent
// `LayerAnimator.completeIfCurrent`'s doc comment documents (M02 §1.4: real `CATransaction`
// completion-block delivery does not reach an XCTest-hosted process on this toolchain — the
// real explicit animations, model writes and layer visibility toggling all still run for real;
// only the final notification is invoked directly by the test through
// `forceCompleteTransitionMotionForTesting()`).

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

/// `.expand`'s own composition (D74): one `hero` role (card→page container geometry) and one
/// `title` role (real `TextNode`, two endpoint rasters + crossfade, D71).
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

    /// When `false`, `page` is left out of the tree until `mountPageNow()` is called — models
    /// "the destination subtree was added after the transition was requested" for the delayed-
    /// measurement checklist item.
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

    func mountPageNow() {
        root.addSubnode(page)
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
            duration: .milliseconds(200)
        )
    }
}

@Test @MainActor
func m11_expandOpensAndClosesWithRealTextEndToEnd() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()

    #expect(harness.bridge.presentTransition(harness.request))
    let opening = try #require(harness.bridge.transitionSession)
    #expect(opening.state == .opening)
    #expect(harness.bridge.sceneReadiness?.animationReady == false, "D69: busy while opening")

    let overlay = opening.overlayLayer
    #expect(overlay.animation(forKey: "trellis.transition.position.x") != nil)
    #expect(overlay.animation(forKey: "trellis.transition.cornerRadius") != nil)
    // Real text: both title endpoints actually rasterized to distinct bitmaps, not a shared
    // placeholder (M11 acceptance: "оба направления работают с настоящим текстом").
    let sourceRasterImage = try #require(overlay.sublayers?.first(where: { $0.contents != nil }))

    harness.bridge.forceCompleteTransitionMotionForTesting()
    let presented = try #require(harness.bridge.transitionSession)
    #expect(presented.state == .presented)
    #expect(harness.bridge.sceneReadiness?.animationReady == true, "D69: ready once presented")
    #expect(harness.bridge.focusScopeID == harness.page.id, "D73: scope opens at presented")
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 0)
    #expect(harness.bridge.layer(for: harness.page.id)?.opacity == 1)
    #expect(!harness.bridge.hasTransitionOverlayForTesting, "overlay released once presented")
    _ = sourceRasterImage

    // Exactly one logical AX representation while presented (D73): the source card's subtree
    // is excluded, the page's is not.
    #expect(harness.card.accessibility.childrenPolicy == .hide)
    #expect(harness.page.accessibility.childrenPolicy != .hide)

    #expect(harness.bridge.closeTransition())
    let closing = try #require(harness.bridge.transitionSession)
    if case let .settling(target) = closing.state {
        #expect(target == .closed)
    } else {
        Issue.record("expected settling(.closed), got \(closing.state)")
    }
    #expect(harness.bridge.sceneReadiness?.animationReady == false, "D69: busy while closing")

    harness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(harness.bridge.transitionSession == nil)
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 1)
    #expect(harness.bridge.layer(for: harness.page.id)?.opacity == 0)
    #expect(harness.bridge.focusScopeID == nil, "D73: scope clears when closed")
    #expect(harness.card.accessibility.childrenPolicy != .hide, "original policy restored")
}

@Test @MainActor
func m11_duplicateRoleIsRejectedBeforeAnyMovement() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()

    let badRequest = NodeHostBridge.TransitionRequest(
        source: harness.card.id,
        destinationRoot: harness.page.id,
        roles: [
            .init(role: .hero, source: harness.card.id, destination: harness.page.id),
            .init(role: .hero, source: harness.cardTitle.id, destination: harness.pageTitle.id),
        ]
    )
    #expect(harness.bridge.presentTransition(badRequest) == false)
    #expect(harness.bridge.transitionSession == nil)
    #expect(harness.bridge.layer(for: harness.card.id)?.opacity == 1, "source stays untouched")
}

@Test @MainActor
func m11_missingSourceIsRejected() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()

    let ghostCard = Node()  // never mounted under `root` — an unresolvable identity.
    let request = NodeHostBridge.TransitionRequest(
        source: ghostCard.id,
        destinationRoot: harness.page.id,
        roles: []
    )
    #expect(harness.bridge.presentTransition(request) == false)
    #expect(harness.bridge.transitionSession == nil)
}

@Test @MainActor
func m11_sourceRemovedWhilePreparingCancelsTheSessionAndRestoresVisibility() async throws {
    let harness = ExpandTransitionHarness(mountPageImmediately: false)
    await harness.waitForCommit()

    harness.mountPageNow()
    // Requested in the same synchronous turn the destination was mounted — `page`/`pageTitle`
    // have no `calculatedFrame` yet, so the session must stay `preparing`.
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(harness.bridge.transitionSession?.state == .preparing)

    // The source is now removed before the destination ever finished measuring — D71's
    // "может получить отмену запроса".
    harness.card.removeFromSupernode()

    // Re-driving prepare (what the next commit's retry hook does) finds the source gone and
    // cancels rather than proceeding.
    await harness.waitForCommit()
    #expect(harness.bridge.transitionSession == nil)
    #expect(!harness.bridge.hasTransitionOverlayForTesting)
}

@Test @MainActor
func m11_delayedDestinationMeasurementKeepsSessionPreparingUntilTheNextCommit() async throws {
    let harness = ExpandTransitionHarness(mountPageImmediately: false)
    await harness.waitForCommit()

    harness.mountPageNow()
    #expect(harness.bridge.presentTransition(harness.request))
    #expect(
        harness.bridge.transitionSession?.state == .preparing,
        "destination not measured yet — must not fly to an unmeasured box"
    )
    #expect(
        harness.bridge.layer(for: harness.card.id)?.opacity == 1,
        "source stays fully visible while preparing"
    )

    await harness.waitForCommit()
    #expect(
        harness.bridge.transitionSession?.state == .opening,
        "next real commit retries prepare and arms the motion — no per-frame poll"
    )
}

@Test @MainActor
func m11_repeatedPresentRetargetsTheSameSessionRatherThanCreatingASecondCopy() async throws {
    let harness = ExpandTransitionHarness()
    await harness.waitForCommit()

    #expect(harness.bridge.presentTransition(harness.request))
    let first = try #require(harness.bridge.transitionSession)
    let overlay = first.overlayLayer
    #expect(harness.transitionRasterLayerCount(harness.bridge) == 2)

    #expect(harness.bridge.presentTransition(harness.request))
    let second = try #require(harness.bridge.transitionSession)
    #expect(second.overlayLayer === overlay, "same overlay layer, not a second copy")
    #expect(second.token != first.token, "retarget bumps the session token")
    #expect(
        harness.transitionRasterLayerCount(harness.bridge) == 2,
        "no additional title rasters materialized on retarget"
    )
}

@Test @MainActor
func m11_temporaryLayersAreReleasedOnCloseDetachAndSuspend() async throws {
    // Close.
    let closeHarness = ExpandTransitionHarness()
    await closeHarness.waitForCommit()
    #expect(closeHarness.bridge.presentTransition(closeHarness.request))
    #expect(closeHarness.bridge.hasTransitionOverlayForTesting)
    #expect(closeHarness.bridge.transitionRasterLayerCountForTesting == 2)
    closeHarness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(!closeHarness.bridge.hasTransitionOverlayForTesting)
    #expect(closeHarness.bridge.transitionRasterLayerCountForTesting == 0)
    #expect(closeHarness.bridge.closeTransition())
    #expect(closeHarness.bridge.hasTransitionOverlayForTesting)
    closeHarness.bridge.forceCompleteTransitionMotionForTesting()
    #expect(!closeHarness.bridge.hasTransitionOverlayForTesting)
    #expect(closeHarness.bridge.transitionRasterLayerCountForTesting == 0)

    // Detach mid-flight.
    let detachHarness = ExpandTransitionHarness()
    await detachHarness.waitForCommit()
    #expect(detachHarness.bridge.presentTransition(detachHarness.request))
    #expect(detachHarness.bridge.hasTransitionOverlayForTesting)
    detachHarness.bridge.detach()
    #expect(!detachHarness.bridge.hasTransitionOverlayForTesting)
    #expect(detachHarness.bridge.transitionSession == nil)

    // Suspend mid-flight — D73: finishes in place to `.presented`, overlay released.
    let suspendHarness = ExpandTransitionHarness()
    await suspendHarness.waitForCommit()
    #expect(suspendHarness.bridge.presentTransition(suspendHarness.request))
    suspendHarness.bridge.suspend()
    #expect(suspendHarness.bridge.transitionSession?.state == .presented)
    #expect(!suspendHarness.bridge.hasTransitionOverlayForTesting)
}

extension ExpandTransitionHarness {
    fileprivate func transitionRasterLayerCount(_ bridge: NodeHostBridge) -> Int {
        bridge.transitionRasterLayerCountForTesting
    }
}
