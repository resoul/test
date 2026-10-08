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

// M06 — real text card (implementation-plan-5.md §5): D65 already holds in isolation
// (TextRasterLayerTests.swift, TextContentChangeClearsRasterTests.swift), without any
// `Node.animate` in flight. These tests combine a real windowed `CABasicAnimation`
// (`WindowedHostLayer`, same warm-up requirement as AnimationCommitLayerTests.swift/
// m02-animation-prototype.md §2) with a controllable text raster worker
// (DisplaySchedulerTests.swift's own technique) to prove M06's three checklist items: D65 keeps
// holding with the M04 explicit animator active; a disclosure's rapid re-press retargets the
// geometry the same way D66 already proves for plain nodes; and card sibling order (background,
// text, overlay) is unaffected by either mechanism.

@MainActor
private final class WindowedHostLayer {
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

/// A controllable `TextRasterizer` (DisplaySchedulerTests.swift's own technique, duplicated per
/// this project's convention of each test file owning its fixtures): an artificial delay holds a
/// job "in flight" long enough for a test to observe a geometry animation running concurrently,
/// and every produced image is tagged so a test can tell which revision landed.
private final class ControllableRasterizer: TextRasterizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    let delay: TimeInterval

    init(delay: TimeInterval) { self.delay = delay }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    private static func fixtureImage(tag: UInt8) -> CGImage {
        var pixel: [UInt8] = [tag, tag, tag, 255]
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func rasterize(_ request: TextDisplayRequest, context: LayoutContext) throws -> DisplayArtifact
    {
        lock.lock()
        _callCount += 1
        let tag = UInt8(truncatingIfNeeded: _callCount)
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try context.checkCancellation()
        return DisplayArtifact(
            image: Self.fixtureImage(tag: tag),
            pixelWidth: 1,
            pixelHeight: 1,
            scale: request.scale
        )
    }
}

private func displayKey(_ revision: UInt64, size: MeasuredSize) -> DisplayKey {
    DisplayKey(
        contentRevision: revision,
        displayRevision: 0,
        environmentRevision: 0,
        size: size,
        scale: 2
    )
}

private func displayRequest(size: MeasuredSize) -> TextDisplayRequest {
    TextDisplayRequest(
        input: TextLayoutInput(
            document: TextDocument("text"),
            style: TextStyle(),
            direction: .leftToRight,
            localeIdentifier: "en",
            maxLines: nil,
            truncation: .tail
        ),
        size: size,
        resolvedColor: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1),
        scale: 2
    )
}

/// A card: background sibling, a `TextNode`, and an overlay sibling — the shape M06's third
/// checklist item (background/clipping/overlay order) asks for — wired through the real
/// `Node.animate` → `RenderCoordinator` (M03) → `LayerRenderer` (M04) path, exactly as
/// AnimationCommitLayerTests.swift's `CommittedLayerHarness` does for plain nodes, plus a manual
/// `DisplayScheduler` (this harness has no `NodeHostBridge`, so nothing schedules text raster
/// work on its own — each test drives it explicitly to control timing).
@MainActor
private final class TextCardHarness {
    let root = Node()
    let card = Node()
    let background = Node()
    let label = TextNode(text: "Hello")
    let overlay = Node()
    private let windowedHost = WindowedHostLayer()
    var hostLayer: CALayer { windowedHost.layer }
    let renderer = LayerRenderer()
    let coordinator: RenderCoordinator
    let rasterizer: ControllableRasterizer
    private let scheduler: DisplayScheduler
    private var pendingEnvelope: AnimationCommitEnvelope?
    private let epoch: UInt64

    init(epoch: UInt64 = 1, rasterDelay: TimeInterval = 0.05) {
        self.epoch = epoch
        rasterizer = ControllableRasterizer(delay: rasterDelay)
        let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
        self.scheduler = scheduler

        root.style.flexDirection = .column
        root.addSubnode(card)
        card.style.flexDirection = .column
        card.style.visual = LayoutVisualProperties(overflow: .hidden)
        card.appearance.background = .color(ThemeColor(red: 0, green: 0, blue: 1))
        card.addSubnode(background)
        card.addSubnode(label)
        card.addSubnode(overlay)
        background.style.width = 100
        background.style.height = 4
        label.style.width = 100
        label.style.height = 24
        overlay.style.width = 100
        overlay.style.height = 4

        coordinator = RenderCoordinator(hostID: 1)
        coordinator.onAnimationCommit = { [weak self] envelope in self?.pendingEnvelope = envelope }
        coordinator.onCommitGeometry = { [weak self] _, request in
            guard let self else { return }
            let envelope =
                self.pendingEnvelope
                ?? AnimationCommitEnvelope(request: request, intents: [], epoch: epoch)
            self.pendingEnvelope = nil
            self.renderer.applyCommitted(root: self.root, on: self.hostLayer, envelope: envelope)
        }
        coordinator.onPaintOnly = { [weak self] request in
            guard let self else { return }
            let envelope =
                self.pendingEnvelope
                ?? AnimationCommitEnvelope(request: request, intents: [], epoch: epoch)
            self.pendingEnvelope = nil
            self.renderer.applyAppearance(root: self.root, envelope: envelope)
        }
        scheduler.onArtifactCommitted = { [weak renderer] nodeID, artifact in
            renderer?.applyDisplayArtifact(artifact, for: nodeID)
        }
        coordinator.mount(root: root, animationEpoch: epoch)
    }

    func invalidateAndWaitForCommit(bounds: LayoutFrame = LayoutFrame(width: 300, height: 300))
        async
    {
        let before = coordinator.committedCount
        coordinator.invalidate(root: root, bounds: bounds, scale: 2)
        for _ in 0..<10_000 where coordinator.committedCount <= before { await Task.yield() }
    }

    func waitForPaintOnlyOrCommit(commitCountBefore: Int, coalescedBefore: Int) async {
        for _ in 0..<10_000
        where coordinator.committedCount <= commitCountBefore
            && coordinator.coalescedCount <= coalescedBefore
        {
            await Task.yield()
        }
    }

    /// Simulates the display job `NodeHostBridge.scanForDisplayWork` would schedule for `label`
    /// after a commit — this harness has no bridge, so each test schedules `label`'s raster work
    /// itself and controls exactly when it starts, independent of the geometry commit's timing.
    func scheduleDisplay(
        revision: UInt64,
        size: MeasuredSize = MeasuredSize(width: 100, height: 24)
    ) {
        scheduler.schedule(
            nodeID: label.id,
            key: displayKey(revision, size: size),
            request: displayRequest(size: size)
        )
    }

    func waitForCompletedCount(_ count: Int) async {
        for _ in 0..<40_000 where scheduler.statistics.completed < count { await Task.yield() }
    }
}

@Test @MainActor
func m06_resizeInsideAnAnimateScopeAnimatesTheOuterLayerButSnapsTheRasterAndKeepsItsOldBitmap()
    async throws
{
    let harness = TextCardHarness()
    await harness.invalidateAndWaitForCommit()
    harness.scheduleDisplay(revision: 1)
    await harness.waitForCompletedCount(1)

    let outer = try #require(harness.renderer.layer(for: harness.label.id))
    let raster = try #require(harness.renderer.rasterLayer(for: harness.label.id))
    let originalBitmap = raster.contents
    #expect(originalBitmap != nil)

    let committedBefore = harness.coordinator.committedCount
    let coalescedBefore = harness.coordinator.coalescedCount
    harness.label.animate(.easeOut(duration: .milliseconds(200))) {
        harness.label.style.height = 48
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    // The outer layer — geometry, focus/hit-test/AX/D65's node identity — really animates.
    let animation = try #require(
        outer.animation(forKey: "bounds.size.height") as? CABasicAnimation
    )
    #expect((animation.toValue as? CGFloat) == 48)

    // The internal raster layer never gets an animation object at all (D65: "обновляется без
    // actions") and snaps straight to the new box...
    #expect(raster.animation(forKey: "bounds.size.height") == nil)
    #expect(raster.bounds == CGRect(x: 0, y: 0, width: 100, height: 48))
    // ...while the bitmap itself is untouched: same text/style, only the box moved, so D65 keeps
    // showing the old glyphs (clipped, not stretched) rather than clearing to empty.
    #expect((raster.contents as! CGImage) === (originalBitmap as! CGImage))
}

@Test @MainActor
func m06_contentChangeInFlightClearsTheStaleBitmapWithoutDisturbingTheRunningGeometryAnimation()
    async throws
{
    let harness = TextCardHarness(rasterDelay: 0.05)
    await harness.invalidateAndWaitForCommit()
    harness.scheduleDisplay(revision: 1)
    await harness.waitForCompletedCount(1)

    let outer = try #require(harness.renderer.layer(for: harness.label.id))
    let raster = try #require(harness.renderer.rasterLayer(for: harness.label.id))

    let committedBefore = harness.coordinator.committedCount
    let coalescedBefore = harness.coordinator.coalescedCount
    // A disclosure: geometry grows under `.smooth`-like timing...
    harness.label.animate(.easeOut(duration: .milliseconds(300))) {
        harness.label.style.height = 60
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    #expect(outer.animation(forKey: "bounds.size.height") != nil)

    // ...and, independently, the revealed text is a different string — the content-change half
    // of D65 must still clear the stale bitmap immediately, exactly as
    // TextContentChangeClearsRasterTests.swift proves with no animation in flight at all.
    harness.label.text = "The full paragraph, now revealed by the disclosure"
    harness.renderer.clearDisplayContent(for: harness.label.id)
    harness.scheduleDisplay(revision: 2, size: MeasuredSize(width: 100, height: 60))

    #expect(raster.contents == nil, "stale bitmap cleared the instant content changed")
    #expect(
        outer.animation(forKey: "bounds.size.height") != nil,
        "clearing the raster must not touch the outer layer's own explicit animation"
    )

    await harness.waitForCompletedCount(2)
    let newBitmap = try #require(raster.contents)
    #expect((newBitmap as! CGImage).width == 1)
    #expect(
        outer.animation(forKey: "bounds.size.height") != nil,
        "the delayed worker committing late must not cancel or restart the geometry animation"
    )
}

@Test @MainActor
func m06_rapidRepeatedPressesRetargetTheGeometryFromThePresentationValueNotFromAStaleModel()
    async throws
{
    let harness = TextCardHarness()
    await harness.invalidateAndWaitForCommit()
    harness.scheduleDisplay(revision: 1)
    await harness.waitForCompletedCount(1)

    let outer = try #require(harness.renderer.layer(for: harness.label.id))
    let raster = try #require(harness.renderer.rasterLayer(for: harness.label.id))
    let originalBitmap = raster.contents

    // Long enough that this test's own polling cannot outlast it and observe it having already
    // finished and auto-removed (the same reasoning AnimationCommitLayerTests.swift's own D63
    // test documents).
    var committedBefore = harness.coordinator.committedCount
    var coalescedBefore = harness.coordinator.coalescedCount
    harness.label.animate(.easeOut(duration: .seconds(30))) {
        harness.label.style.height = 60
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    let firstAnimation = try #require(
        outer.animation(forKey: "bounds.size.height") as? CABasicAnimation
    )
    #expect((firstAnimation.toValue as? CGFloat) == 60)

    // Pressed again before the first transition finished: the new target replaces the old one
    // (D66), starting from wherever the layer visibly is right now, not from the pre-press model
    // value of 24.
    committedBefore = harness.coordinator.committedCount
    coalescedBefore = harness.coordinator.coalescedCount
    harness.label.animate(.easeOut(duration: .seconds(30))) {
        harness.label.style.height = 30
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    let secondAnimation = try #require(
        outer.animation(forKey: "bounds.size.height") as? CABasicAnimation
    )
    #expect((secondAnimation.toValue as? CGFloat) == 30)
    let fromValue = try #require(secondAnimation.fromValue as? CGFloat)
    #expect(fromValue != 24, "must retarget from the live presentation, not the original model")

    // Same text throughout both presses: the raster still snaps immediately to the latest box
    // and never picks up an animation of its own, exactly as the single-press case does.
    #expect(raster.animation(forKey: "bounds.size.height") == nil)
    #expect(raster.bounds == CGRect(x: 0, y: 0, width: 100, height: 30))
    #expect((raster.contents as! CGImage) === (originalBitmap as! CGImage))
}

@Test @MainActor
func m06_cardSiblingOrderAndClippingSurviveAnActiveTextGeometryAnimation() async throws {
    let harness = TextCardHarness()
    await harness.invalidateAndWaitForCommit()
    harness.scheduleDisplay(revision: 1)
    await harness.waitForCompletedCount(1)

    let cardLayer = try #require(harness.renderer.layer(for: harness.card.id))
    let backgroundLayer = try #require(harness.renderer.layer(for: harness.background.id))
    let outer = try #require(harness.renderer.layer(for: harness.label.id))
    let raster = try #require(harness.renderer.rasterLayer(for: harness.label.id))
    let overlayLayer = try #require(harness.renderer.layer(for: harness.overlay.id))

    harness.label.animate(.easeOut(duration: .milliseconds(200))) {
        harness.label.style.height = 48
    }
    let committedBefore = harness.coordinator.committedCount
    let coalescedBefore = harness.coordinator.coalescedCount
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    // The card clips (D65's outer-layer overflow) and its own background paints behind every
    // sublayer by CALayer's own contract; what M06 must prove is that its *children* — the
    // painted node layers — keep declaration order regardless of the text node's own animation,
    // and that the raster never appears there: it is nested one level inside `outer`, not a
    // sibling of `background`/`overlay`.
    #expect(cardLayer.masksToBounds)
    #expect(cardLayer.sublayers == [backgroundLayer, outer, overlayLayer])
    #expect(outer.sublayers == [raster])
}
