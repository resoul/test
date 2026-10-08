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

// M07 — взаимодействие и детерминированная готовность (implementation-plan-5.md §5, D68/D69).
// D68 (hit-test/focus/AX/DebugOverlay read the committed target, never presentation) is D25/D34/
// D46's existing contract, unchanged — these tests prove it still holds with a real explicit
// animation in flight, the same way M06 did for D65. D69's "готовность export" is new: `NodeHost
// Bridge.sceneReadiness`/`waitUntilSceneReady(timeout:)`, backed by `RenderCoordinator.hasPending
// LayoutWork` (layout axis), `DisplayScheduler.activeJobCount`/`pendingJobCount` (display axis)
// and `LayerAnimator.activeCount(mountEpoch:)` via `LayerRenderer.hasActiveAnimations` (animation
// axis) — added by this card.
//
// One thing these tests deliberately do NOT attempt: waiting for a real `Node.animate` to finish
// on its own and observing `animationReady` flip back to `true` from natural CA completion.
// m02-animation-prototype.md §1.4 found CA's own completion callback (`CATransaction
// .setCompletionBlock`/`CAAnimationDelegate`) is never delivered inside an XCTest-hosted
// process on this toolchain, reproduced five different ways — only `presentation()` reads and
// the retarget/token mechanism itself are verifiable here; natural completion is Playground/
// manual evidence, not an automated test, for M02 and every card built on `LayerAnimator` since,
// M07 included. What *is* tested here is `animationReady` clearing through `suspend()` (D67's
// `finishActiveAnimations`), which does not depend on that callback at all.

@MainActor
private final class ReadinessWindowHost {
    let layer: CALayer
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
            layer = view.layer ?? CALayer()
        #elseif canImport(UIKit)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
            let view = UIView(frame: window.bounds)
            window.addSubview(view)
            window.makeKeyAndVisible()
            layer = view.layer
        #endif
    }
}

/// A disclosure control: press toggles `label`'s height/text under a long-lived `card.animate`
/// scope — long enough (30s) that this test file's own polling can never race it into having
/// already finished (`AnimationCommitLayerTests.swift`'s own D63 test documents the same
/// reasoning).
@MainActor
private final class DisclosureControl: ControlNode {
    let card: Node
    let label: TextNode
    private(set) var isExpanded = false
    private(set) var pressCount = 0

    init(card: Node, label: TextNode) {
        self.card = card
        self.label = label
        super.init()
        focus.isFocusable = true
        activation = { [weak self] in self?.press() }
    }

    private func press() {
        pressCount += 1
        isExpanded.toggle()
        let expanded = isExpanded
        card.animate(.easeOut(duration: .seconds(30))) {
            self.label.style.height = expanded ? 80 : 24
            self.label.text =
                expanded
                ? "A much longer revealed paragraph of text that changes the raster" : "Short"
        }
    }
}

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<20_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func waitForArtifact(_ bridge: NodeHostBridge, _ id: NodeID) async {
    for _ in 0..<40_000 where bridge.displayArtifact(for: id) == nil { await Task.yield() }
}

@MainActor
private func tap(_ bridge: NodeHostBridge, at point: LayoutPoint, id: UInt64 = 1) {
    _ = bridge.send(.pointerDown, PointerData(point: point, pointerID: id))
    _ = bridge.send(.pointerUp, PointerData(point: point, pointerID: id))
}

@Test @MainActor
func m07_sceneReadinessIsTriviallyTrueForAPlainSceneWithNoTextAndNoAnimation() async throws {
    let host = ReadinessWindowHost()
    let root = Node()
    let child = Node()
    child.style.width = 50
    child.style.height = 50
    root.addSubnode(child)
    let bridge = NodeHostBridge(hostLayer: host.layer)

    #expect(bridge.sceneReadiness == nil, "nothing mounted yet")
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)

    let readiness = try #require(bridge.sceneReadiness)
    #expect(readiness.layoutReady)
    #expect(readiness.displayReady)
    #expect(readiness.animationReady)
    #expect(readiness.isReady)

    let waited = try await bridge.waitUntilSceneReady(timeout: .milliseconds(200))
    #expect(waited.isReady)
}

@Test @MainActor
func m07_animationReadyIsFalseWhileAnExplicitAnimationIsInFlightAndTimeoutSurfacesAsAnError()
    async throws
{
    let host = ReadinessWindowHost()
    let root = Node()
    let control = Node()
    control.style.width = 100
    control.style.height = 24
    root.addSubnode(control)
    let bridge = NodeHostBridge(hostLayer: host.layer)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)
    #expect(bridge.sceneReadiness?.isReady == true)

    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    control.animate(.easeOut(duration: .seconds(30))) {
        control.style.height = 80
    }
    for _ in 0..<20_000
    where bridge.committedCount <= committedBefore
        && bridge.statistics.coalesced <= coalescedBefore
    {
        await Task.yield()
    }

    #expect(bridge.sceneReadiness?.animationReady == false)
    #expect(bridge.sceneReadiness?.isReady == false)

    await #expect(throws: NodeHostBridge.SceneReadinessError.timeout) {
        try await bridge.waitUntilSceneReady(timeout: .milliseconds(30))
    }
}

@Test @MainActor
func m07_suspendFinishesTheActiveAnimationAndRestoresAnimationReadiness() async throws {
    let host = ReadinessWindowHost()
    let root = Node()
    let control = Node()
    control.style.width = 100
    control.style.height = 24
    root.addSubnode(control)
    let bridge = NodeHostBridge(hostLayer: host.layer)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)

    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    control.animate(.easeOut(duration: .seconds(30))) {
        control.style.height = 80
    }
    for _ in 0..<20_000
    where bridge.committedCount <= committedBefore
        && bridge.statistics.coalesced <= coalescedBefore
    {
        await Task.yield()
    }
    #expect(bridge.sceneReadiness?.animationReady == false)

    // D67: suspend snaps every active transition to its committed target right away, without a
    // new commit — the readiness axis must reflect that immediately, not after a later flush.
    bridge.suspend()
    #expect(bridge.sceneReadiness?.animationReady == true)
    #expect(bridge.sceneReadiness?.isReady == true)
}

@Test @MainActor
func
    m07_hitTestFocusAndAccessibilityTargetTheCommittedFrameNotThePresentationDuringAnActiveAnimation()
    async throws
{
    let host = ReadinessWindowHost()
    let root = Node()
    let control = Node()
    control.focus.isFocusable = true
    control.style.width = 100
    control.style.height = 24
    root.addSubnode(control)
    let bridge = NodeHostBridge(hostLayer: host.layer)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)
    let outer = try #require(bridge.layer(for: control.id))

    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    control.animate(.easeOut(duration: .seconds(30))) {
        control.style.height = 80
    }
    for _ in 0..<20_000
    where bridge.committedCount <= committedBefore
        && bridge.statistics.coalesced <= coalescedBefore
    {
        await Task.yield()
    }

    // Sanity check the test is not vacuous: the layer really is still visually mid-transition
    // (presentation still near the pre-press height), not already jumped to 80.
    let presentedHeight = outer.presentation()?.bounds.height ?? outer.bounds.height
    #expect(presentedHeight < 80)

    // D68: hit-testing, focus and accessibility all target the committed (final) frame — a
    // point only inside the *new*, still-animating-to box already resolves to `control`.
    #expect(bridge.hitTest(LayoutPoint(x: 10, y: 50)) == control.id)

    let focusResult = bridge.focus(control.id)
    if case .unavailable = focusResult {
        Issue.record("focus should have resolved to the committed control, not been unavailable")
    }
    #expect(bridge.focusedID == control.id)

    let record = try #require(bridge.semanticSnapshot?.record(for: control.id))
    #expect(record.frame.height == 80)
}

@Test @MainActor
func m07_debugOverlayOutlinesTheCommittedFrameNotThePresentationDuringAnActiveAnimation()
    async throws
{
    let host = ReadinessWindowHost()
    let root = Node()
    let control = Node()
    control.style.width = 100
    control.style.height = 24
    root.addSubnode(control)
    let bridge = NodeHostBridge(hostLayer: host.layer)
    bridge.isDebugOverlayEnabled = true
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)
    let outer = try #require(bridge.layer(for: control.id))

    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    control.animate(.easeOut(duration: .seconds(30))) {
        control.style.height = 80
    }
    for _ in 0..<20_000
    where bridge.committedCount <= committedBefore
        && bridge.statistics.coalesced <= coalescedBefore
    {
        await Task.yield()
    }

    let presentedHeight = outer.presentation()?.bounds.height ?? outer.bounds.height
    #expect(presentedHeight < 80)
    #expect(bridge.debugOverlayRenderer.outlinedCount == 2)  // root + control

    let outlines =
        (host.layer.sublayers ?? [])
        .filter { $0.name == "trellis.debug-overlay" }
        .flatMap { $0.sublayers ?? [] }
        .filter { $0.name == "trellis.debug-outline" }
    #expect(outlines.contains { $0.frame.height == 80 })
    #expect(!outlines.contains { $0.frame.height == presentedHeight && presentedHeight != 80 })
}

@Test @MainActor
func m07_displayReadyTracksARealTextRasterJobFromScheduledToCommitted() async throws {
    let host = ReadinessWindowHost()
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let bridge = NodeHostBridge(hostLayer: host.layer)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)

    // T06 schedules the raster job synchronously inside the same commit's `onPostCommit` —
    // by the time the awaited commit count is visible, the job is already active or queued.
    #expect(bridge.sceneReadiness?.displayReady == false)
    #expect(bridge.sceneReadiness?.isReady == false)

    await waitForArtifact(bridge, label.id)
    #expect(bridge.sceneReadiness?.displayReady == true)

    let readiness = try await bridge.waitUntilSceneReady()
    #expect(readiness.isReady)
}

@Test @MainActor
func m07_repeatedTapDuringAnInFlightRasterJobThenDetachLeavesNoStaleReadinessOrSessions()
    async throws
{
    let host = ReadinessWindowHost()
    let root = Node()
    let label = TextNode(text: "Short")
    label.style.width = 200
    label.style.height = 24
    let control = DisclosureControl(card: root, label: label)
    control.style.width = 200
    control.style.height = 24
    root.style.flexDirection = .column
    root.addSubnode(control)
    root.addSubnode(label)
    let bridge = NodeHostBridge(hostLayer: host.layer)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 2))
    await waitForCommits(bridge, 1)
    await waitForArtifact(bridge, label.id)

    let point = LayoutPoint(x: 10, y: 12)
    // First tap: expands, starts a real text raster job (delayed by real CoreText timing, not
    // simulated) and a real geometry animation at the same time.
    tap(bridge, at: point)
    let committedAfterFirst = bridge.committedCount
    for _ in 0..<20_000 where bridge.committedCount <= committedAfterFirst - 1 {
        await Task.yield()
    }
    #expect(control.pressCount == 1)

    // Second tap immediately after, before the first raster job necessarily finished — the
    // control retargets (D66) while a raster for the *first* text change may still be active.
    tap(bridge, at: point)
    for _ in 0..<20_000 where bridge.committedCount <= committedAfterFirst {
        await Task.yield()
    }
    #expect(control.pressCount == 2)

    // Detach right here, possibly mid-raster and mid-animation — no crash (the test completing
    // is itself evidence of that), and nothing stale survives it.
    bridge.detach()

    #expect(bridge.sceneReadiness == nil)
    #expect(bridge.displayArtifact(for: label.id) == nil)
    #expect(bridge.activePointerSessionCount == 0)
}
