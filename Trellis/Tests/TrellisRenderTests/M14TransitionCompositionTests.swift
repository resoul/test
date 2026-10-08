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

// M14 — closes result B (implementation-plan-5.md §6): two external-consumer Playground scenes
// (S30/S31) prove D70–D74's reusability claim; this file covers the one small, narrowly-scoped
// production addition M14 needed to build S31's own timing/appearance intervals honestly
// (`docs/validation/m10-transition-contract.md`'s D70 text: "все части используют единый
// progress 0…1, собственные интервалы и кривые внутри него") — `TransitionRoleMapping.interval`
// (`NodeHostBridge.swift`), threaded to `TransitionAnimator.Target.beginProgress`/`endProgress`
// (`TransitionAnimator.swift`). Reuses M12/M13's window-host/harness shape (own copy, same
// precedent every prior card in this arc has followed).

@MainActor
private final class M14WindowHost {
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

    /// See `TransitionOverlayPrototypeTests.swift`'s `pump(for:)` doc comment (M10 §2.3): a
    /// freshly created window's first `presentation()` read after a manual `timeOffset` scrub
    /// is only reliable once the window has completed at least one real display pass.
    func pump(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

/// A three-role composition (`avatar`/`name`/`bio`, deliberately not `.hero`/`.title` — `Role`
/// is an open value type, D70's own reasoning for why) with `bio` confined to the back half of
/// the session's progress (`0.5...1`) and no source counterpart at all — the shape S31 (profile
/// card→profile) actually uses.
@MainActor
private final class ThreeRoleTransitionHarness {
    let root = Node()
    let card = Node()
    let avatar = Node()
    let cardName = TextNode(text: "J. Rivera")
    let page = Node()
    let pageAvatar = Node()
    let pageName = TextNode(text: "J. Rivera")
    let pageBio = TextNode(text: "Product design, ten years. Previously at two startups.")
    let bridge: NodeHostBridge
    private let host = M14WindowHost()

    init() {
        bridge = NodeHostBridge(hostLayer: host.hostLayer)

        root.style.flexDirection = .column
        card.style.width = 260
        card.style.height = 88
        card.appearance.background = .color(ThemeColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1))
        card.appearance.cornerRadius = 12
        card.addSubnode(avatar)
        avatar.style.width = 40
        avatar.style.height = 40
        card.addSubnode(cardName)
        cardName.style.width = 160
        cardName.style.height = 20

        page.style.width = 390
        page.style.height = 600
        page.appearance.background = .color(ThemeColor(red: 1, green: 1, blue: 1, alpha: 1))
        page.appearance.cornerRadius = 0
        page.addSubnode(pageAvatar)
        pageAvatar.style.width = 96
        pageAvatar.style.height = 96
        page.addSubnode(pageName)
        pageName.style.width = 300
        pageName.style.height = 32
        page.addSubnode(pageBio)
        pageBio.style.width = 340
        pageBio.style.height = 60

        root.addSubnode(card)
        root.addSubnode(page)

        _ = bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 390, height: 700),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
        host.pump(for: 0.05)
    }

    func pump() { host.pump(for: 0.3) }

    func waitForCommit() async {
        let before = bridge.statistics.committed
        for _ in 0..<20_000 where bridge.statistics.committed <= before { await Task.yield() }
    }

    var request: NodeHostBridge.TransitionRequest {
        NodeHostBridge.TransitionRequest(
            source: card.id,
            destinationRoot: page.id,
            roles: [
                .init(role: Role("avatar"), source: avatar.id, destination: pageAvatar.id),
                .init(role: Role("name"), source: cardName.id, destination: pageName.id),
                .init(
                    role: Role("bio"),
                    source: nil,
                    destination: pageBio.id,
                    interval: 0.5...1
                ),
            ],
            duration: .seconds(30)
        )
    }

    func presentAndComplete() async {
        await waitForCommit()
        #expect(bridge.presentTransition(request))
        bridge.forceCompleteTransitionMotionForTesting()
        host.pump(for: 0.02)
    }
}

@Test @MainActor
func m14_roleWithoutASourceCounterpartHoldsUntilItsOwnLatterIntervalThenFadesOut() async throws {
    let harness = ThreeRoleTransitionHarness()
    await harness.presentAndComplete()

    // Dismiss gesture from `.presented`: progress 0 = presented (bio fully visible, it has no
    // source counterpart so it is only ever on the destination side), progress 1 = closed.
    #expect(harness.bridge.beginTransitionGesture())
    harness.pump()

    func bioOpacity() throws -> Float {
        let layer = try #require(
            harness.bridge.transitionRasterLayerForTesting(role: Role("bio"), side: .source)
        )
        return try #require(layer.presentation()?.opacity)
    }

    harness.bridge.updateTransitionGesture(deltaProgress: 0.25)
    harness.pump()
    #expect(
        try bioOpacity() == 1,
        "held at its starting value before its own 0.5...1 interval begins"
    )

    harness.bridge.updateTransitionGesture(deltaProgress: 0.5)  // now at progress 0.75
    harness.pump()
    let midInterval = try bioOpacity()
    #expect(midInterval > 0 && midInterval < 1, "mid-fade inside its own interval")

    harness.bridge.updateTransitionGesture(deltaProgress: 0.25)  // now at progress 1.0
    harness.pump()
    #expect(try bioOpacity() == 0, "fully faded out by the end of its own interval")
}

@Test @MainActor
func m14_roleWithNoIntervalStillSpansTheFullProgressRangeUnchanged() async throws {
    let harness = ThreeRoleTransitionHarness()
    await harness.presentAndComplete()
    #expect(harness.bridge.beginTransitionGesture())
    harness.pump()

    // `name` carries no `interval` (defaults to the full range) — unlike `bio`, its crossfade
    // must already be partway done at progress 0.25, the M11–M13 behavior this field must not
    // change for every mapping that does not opt in.
    harness.bridge.updateTransitionGesture(deltaProgress: 0.25)
    harness.pump()
    let layer = try #require(
        harness.bridge.transitionRasterLayerForTesting(role: Role("name"), side: .source)
    )
    let value = try #require(layer.presentation()?.opacity)
    #expect(value > 0 && value < 1, "full-range role already mid-fade at progress 0.25")
}
