import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T10 — "Реентрантность: изменение текста из onCommit/onFocusChange callbacks."
//
// A host adapter's `onSemanticsPublished`/`onFocusChange` run synchronously, deep inside
// `RenderCoordinator.handle()` (`onCommitGeometry` → `NodeHostBridge.publishSemantics` →
// `focusEngine.apply`/`onSemanticsPublished`). Nothing stops a callback from mutating the very
// tree that commit just produced, or from tearing the bridge down mid-publish. These tests lock
// in that both are already safe by construction — `RenderCoordinator` clears `activeRequest`
// and each callback slot *before* invoking it, so a reentrant edit only ever schedules a
// deferred flush (never a recursive one), and `detachCurrentRoot()` nils every bridge callback
// and coordinator slot the still-unwinding call stack reads next — rather than something this
// card had to add. A regression here would most likely show up as an infinite recursion/stack
// overflow or a crash reading torn-down state, neither of which a `#expect` failure would catch
// after the fact, so the assertions are on the *converged* state once the dust settles.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func settle() async {
    for _ in 0..<300 { await Task.yield() }
}

@Test @MainActor
func t10_mutatingTextFromOnSemanticsPublishedDoesNotCrashAndSettlesOnASecondCommit() async {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    var didMutate = false
    bridge.onSemanticsPublished = { _ in
        guard !didMutate else { return }
        didMutate = true
        label.text = "Changed reentrantly from inside the commit that produced \"Hello\""
    }

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    #expect(didMutate)

    await waitForCommits(bridge, 2)

    #expect(bridge.committedCount == 2)
    #expect(bridge.statistics.stale == 0)
    #expect(bridge.semanticSnapshot != nil)
}

@Test @MainActor
func t10_detachingFromOnSemanticsPublishedLeavesTheBridgeFullyTornDownNotHalfway() async {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    bridge.onSemanticsPublished = { [weak bridge] _ in
        bridge?.detach()
    }

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    await settle()

    // The coordinator whose `handle()` is still on the stack when `detach()` runs disposes
    // itself as part of that same call — so its own deferred `onPostCommit` never fires late
    // (D58's "zero late commits"), and every downstream bridge accessor reads the fully-detached
    // state, not a partial one.
    #expect(bridge.hitTestSnapshot == nil)
    #expect(bridge.semanticSnapshot == nil)
    #expect(bridge.accessibilityTree == nil)
    #expect(bridge.displayArtifact(for: label.id) == nil)
    #expect(bridge.displayStatistics.completed == 0)
    #expect(bridge.materializedLayerCount == 0)

    // A bridge is reusable after `detach()` (C29): a fresh `attach()` must not see anything the
    // reentrant teardown left behind. `onSemanticsPublished` itself survives `detach()` as a
    // setting (it is the caller's job to clear it) — drop the self-detaching one first so this
    // second mount is not immediately torn down by the very callback under test.
    bridge.onSemanticsPublished = nil
    let root2 = Node()
    #expect(bridge.attach(root: root2, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    await waitForCommits(bridge, 1)
    #expect(bridge.committedCount == 1)
}

@Test @MainActor
func t10_movingFocusFromOnFocusChangeIsDeferredNotRecursedAndConverges() async {
    let root = Node()
    let first = ControlNode()
    let second = ControlNode()
    first.style.width = 50
    first.style.height = 20
    second.style.width = 50
    second.style.height = 20
    root.style.flexDirection = .column
    root.addSubnode(first)
    root.addSubnode(second)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    var changes: [NodeID?] = []
    bridge.onFocusChange = { [weak bridge] change in
        changes.append(change.next)
        // Bounce straight back to `first` exactly once, from inside the transition that just
        // moved focus away from it — `FocusEngine`'s `inTransition` guard must defer this
        // rather than recurse into a second `transition(to:)` on the same call stack.
        if change.next == second.id, changes.filter({ $0 == first.id }).count < 2 {
            bridge?.focus(first.id)
        }
    }

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 200), scale: 1))
    await waitForCommits(bridge, 1)

    bridge.focus(first.id)
    #expect(bridge.moveFocus(.next) != .unavailable)

    #expect(bridge.focusedID == first.id)
    #expect(changes == [first.id, second.id, first.id])
}
