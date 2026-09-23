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

// M04 — маленький explicit animator внутри renderer: end-to-end через настоящий
// Node.animate → RenderCoordinator (M03) → LayerRenderer (M04), а не через прямой
// вызов LayerAnimator (LayerAnimatorTests.swift). Доказывает саму проводку из
// implementation-plan-5.md §5: `NodeHostBridge`'s wiring is exercised indirectly by
// reproducing its `onAnimationCommit`/`onCommitGeometry`/`onPaintOnly` pattern directly
// against a real `CALayer` host, matching LayerRendererTests.swift's style.
//
// The host layer is mounted under a real window (as `LayerAnimatorTests.swift`'s
// `AnimatorWindowHost` and M02's `WindowHost` are) — `CALayer.add(_:forKey:)` and
// `animation(forKey:)` are unreliable off a mounted tree until a process-wide one-time
// warm-up (docs/validation/m02-animation-prototype.md §2).
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

@MainActor
private final class CommittedLayerHarness {
    let root = Node()
    private let windowedHost = WindowedHostLayer()
    var hostLayer: CALayer { windowedHost.layer }
    let renderer = LayerRenderer()
    let coordinator: RenderCoordinator
    private var pendingEnvelope: AnimationCommitEnvelope?

    init(epoch: UInt64 = 1) {
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
}

@Test @MainActor
func m04_nodeAnimateProducesARealExplicitAnimationOnTheCommittedLayer() async throws {
    let harness = CommittedLayerHarness(epoch: 7)
    let child = Node()
    harness.root.addSubnode(child)
    await harness.invalidateAndWaitForCommit()

    let layer = try #require(harness.renderer.layer(for: child.id))
    #expect(
        layer.animation(forKey: "opacity") == nil,
        "initial commit has no scope to animate from"
    )

    let committedBefore = harness.coordinator.committedCount
    let coalescedBefore = harness.coordinator.coalescedCount
    child.animate(.easeOut(duration: .milliseconds(240))) {
        child.style.visual = LayoutVisualProperties(opacity: 0.25)
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    let animation = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation)
    #expect((animation.toValue as? Float) == 0.25)
    #expect(abs(animation.duration - 0.24) < 0.001)
    #expect(layer.opacity == 0.25)
}

@Test @MainActor
func m04_plainMutationOutsideAnyScopeSnapsEvenWhenAnotherNodeIsAnimating() async throws {
    let harness = CommittedLayerHarness(epoch: 9)
    let first = Node()
    let second = Node()
    harness.root.addSubnode(first)
    harness.root.addSubnode(second)
    await harness.invalidateAndWaitForCommit()

    let firstLayer = try #require(harness.renderer.layer(for: first.id))
    let secondLayer = try #require(harness.renderer.layer(for: second.id))

    var committedBefore = harness.coordinator.committedCount
    var coalescedBefore = harness.coordinator.coalescedCount
    // A long duration, not `.smooth`'s 250ms: this test's own polling/assertions run after
    // `second`'s commit too, and under a busy parallel test run that can outlast 250ms —
    // long enough for a short explicit animation to complete and auto-remove itself before
    // the final assertion below reads it, which would be a harness flake, not a real bug.
    first.animate(.easeInOut(duration: .seconds(30))) {
        first.style.visual = LayoutVisualProperties(opacity: 0.4)
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    #expect(firstLayer.animation(forKey: "opacity") != nil)

    committedBefore = harness.coordinator.committedCount
    coalescedBefore = harness.coordinator.coalescedCount
    second.style.visual = LayoutVisualProperties(opacity: 0.4)
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    #expect(
        secondLayer.animation(forKey: "opacity") == nil,
        "ordinary mutation outside a scope snaps (D63)"
    )
    #expect(secondLayer.opacity == 0.4)
    #expect(
        firstLayer.animation(forKey: "opacity") != nil,
        "unrelated node's active animation untouched"
    )
}

@Test @MainActor
func m04_newlyMountedLayerNeverAnimatesItsFirstAppearance() async throws {
    let harness = CommittedLayerHarness(epoch: 3)
    await harness.invalidateAndWaitForCommit()

    let committedBefore = harness.coordinator.committedCount
    let coalescedBefore = harness.coordinator.coalescedCount
    let child = Node()
    harness.root.animate(.smooth) {
        harness.root.addSubnode(child)
        child.style.visual = LayoutVisualProperties(opacity: 0.3)
    }
    await harness.waitForPaintOnlyOrCommit(
        commitCountBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    let childLayer = try #require(harness.renderer.layer(for: child.id))
    #expect(
        childLayer.animation(forKey: "opacity") == nil,
        "D62: a layer materialized this commit snaps, it has nothing to retarget from"
    )
}
