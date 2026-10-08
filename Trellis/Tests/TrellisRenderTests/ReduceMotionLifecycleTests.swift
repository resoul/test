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

// M05 — Reduce Motion и lifecycle (implementation-plan-5.md §5, D67,
// docs/validation/m05-reduce-motion-lifecycle.md). Exercises the real `NodeHostBridge` (not
// bare `RenderCoordinator`/`LayerRenderer` like `AnimationCommitLayerTests.swift`) since
// `updateReduceMotion`/`suspend`'s D67 behavior is bridge-owned. The host layer is mounted
// under a real window — `CALayer.add(_:forKey:)`/`animation(forKey:)` are unreliable off a
// mounted tree until a process-wide one-time warm-up (m02-animation-prototype.md §2).

@MainActor
private final class ReduceMotionWindowHost {
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
private func attachedBridge(
    on hostLayer: CALayer,
    root: Node,
    reduceMotion: Bool? = nil
) async -> NodeHostBridge {
    let bridge = NodeHostBridge(hostLayer: hostLayer)
    #expect(
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 300, height: 300),
            scale: 2,
            reduceMotion: reduceMotion
        )
    )
    for _ in 0..<10_000 where bridge.committedCount < 1 { await Task.yield() }
    return bridge
}

@MainActor
private func waitForNextCommitOrCoalesce(
    _ bridge: NodeHostBridge,
    committedBefore: Int,
    coalescedBefore: Int
) async {
    for _ in 0..<10_000
    where bridge.committedCount <= committedBefore && bridge.statistics.coalesced <= coalescedBefore
    {
        await Task.yield()
    }
}

@Test @MainActor
func m05_reduceMotionAtAttachResolvesEveryIntentToASnap() async throws {
    let host = ReduceMotionWindowHost()
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let bridge = await attachedBridge(on: host.layer, root: root, reduceMotion: true)

    let layer = try #require(bridge.layer(for: child.id))
    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    child.animate(.easeInOut(duration: .seconds(30))) {
        child.style.visual = LayoutVisualProperties(opacity: 0.4)
    }
    await waitForNextCommitOrCoalesce(
        bridge,
        committedBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    #expect(layer.animation(forKey: "opacity") == nil, "Reduce Motion resolves the intent to .none")
    #expect(layer.opacity == 0.4, "the model value still lands, just without an explicit animation")

    bridge.detach()
}

@Test @MainActor
func m05_turningOnReduceMotionMidFlightFinishesActiveAnimationsImmediately() async throws {
    let host = ReduceMotionWindowHost()
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let bridge = await attachedBridge(on: host.layer, root: root, reduceMotion: false)

    let layer = try #require(bridge.layer(for: child.id))
    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    child.animate(.easeInOut(duration: .seconds(30))) {
        child.style.visual = LayoutVisualProperties(opacity: 0.4)
    }
    await waitForNextCommitOrCoalesce(
        bridge,
        committedBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    #expect(layer.animation(forKey: "opacity") != nil, "sanity: a real animation is in flight")

    // No new commit here at all — D67's "без нового solve": the animation must be gone the
    // instant this call returns.
    bridge.updateReduceMotion(true)

    #expect(layer.animation(forKey: "opacity") == nil)
    #expect(layer.opacity == 0.4, "the already-committed target, unchanged by finishing early")

    bridge.detach()
}

@Test @MainActor
func m05_turningReduceMotionOffOnlyAffectsFutureAnimateCalls() async throws {
    let host = ReduceMotionWindowHost()
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let bridge = await attachedBridge(on: host.layer, root: root, reduceMotion: true)
    let layer = try #require(bridge.layer(for: child.id))

    var committedBefore = bridge.committedCount
    var coalescedBefore = bridge.statistics.coalesced
    child.animate(.smooth) { child.style.visual = LayoutVisualProperties(opacity: 0.2) }
    await waitForNextCommitOrCoalesce(
        bridge,
        committedBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    #expect(layer.animation(forKey: "opacity") == nil, "still resolving to .none while enabled")

    bridge.updateReduceMotion(false)
    #expect(
        layer.animation(forKey: "opacity") == nil,
        "turning it off does not retroactively animate an already-snapped change"
    )

    committedBefore = bridge.committedCount
    coalescedBefore = bridge.statistics.coalesced
    child.animate(.easeInOut(duration: .seconds(30))) {
        child.style.visual = LayoutVisualProperties(opacity: 0.6)
    }
    await waitForNextCommitOrCoalesce(
        bridge,
        committedBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    #expect(layer.animation(forKey: "opacity") != nil, "a later call animates normally again")

    bridge.detach()
}

@Test @MainActor
func m05_suspendFinishesActiveAnimationsToTheirCommittedTarget() async throws {
    let host = ReduceMotionWindowHost()
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let bridge = await attachedBridge(on: host.layer, root: root)

    let layer = try #require(bridge.layer(for: child.id))
    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    child.animate(.easeInOut(duration: .seconds(30))) {
        child.style.visual = LayoutVisualProperties(opacity: 0.4)
    }
    await waitForNextCommitOrCoalesce(
        bridge,
        committedBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )
    #expect(layer.animation(forKey: "opacity") != nil, "sanity: a real animation is in flight")

    bridge.suspend()

    #expect(layer.animation(forKey: "opacity") == nil, "D67: suspend snaps to the committed target")
    #expect(layer.opacity == 0.4)

    bridge.resume()
    bridge.detach()
}

@Test @MainActor
func m05_detachDoesNotLeaveAStaleAnimationAffectingTheNextMount() async throws {
    let host = ReduceMotionWindowHost()
    let firstRoot = Node()
    let firstChild = Node()
    firstRoot.addSubnode(firstChild)
    let bridge = await attachedBridge(on: host.layer, root: firstRoot)

    let firstLayer = try #require(bridge.layer(for: firstChild.id))
    firstChild.animate(.easeInOut(duration: .seconds(30))) {
        firstChild.style.visual = LayoutVisualProperties(opacity: 0.4)
    }
    for _ in 0..<10_000 where firstLayer.animation(forKey: "opacity") == nil { await Task.yield() }

    bridge.detach()

    // A fresh root, same bridge, a fresh mount epoch: the previous mount's active-animation
    // bookkeeping must not resurface as a bogus "already active, retarget from presentation"
    // for a same-identity coincidence, and a brand new node must still animate normally.
    let secondRoot = Node()
    let secondChild = Node()
    secondRoot.addSubnode(secondChild)
    #expect(
        bridge.attach(root: secondRoot, bounds: LayoutFrame(width: 300, height: 300), scale: 2)
    )
    for _ in 0..<10_000 where bridge.committedCount < 1 { await Task.yield() }
    let secondLayer = try #require(bridge.layer(for: secondChild.id))

    let committedBefore = bridge.committedCount
    let coalescedBefore = bridge.statistics.coalesced
    secondChild.animate(.smooth) { secondChild.style.visual = LayoutVisualProperties(opacity: 0.5) }
    await waitForNextCommitOrCoalesce(
        bridge,
        committedBefore: committedBefore,
        coalescedBefore: coalescedBefore
    )

    #expect(
        secondLayer.animation(forKey: "opacity") != nil,
        "the new mount animates on its own terms"
    )
    #expect(
        (secondLayer.animation(forKey: "opacity") as? CABasicAnimation)?.toValue as? Float == 0.5
    )

    bridge.detach()
}
