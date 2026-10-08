import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// R07 (`implementation-plan-6.md` plan 6): `ScrollNode`'s renderer wiring, offset-aware
// hit-testing (D18), and the offset-only commit path — against a test-double
// `NativeScrollBacking`, not real `UIScrollView`/`NSScrollView` (those live in
// `UIKitScrollNodeEmbeddingTests.swift`/`AppKitScrollNodeEmbeddingTests.swift`). Covers the
// R07 checklist's bullets 1 and 2 in full and contributes to bullet 3 (nested clip/transform);
// empty/short/long content, resize/insets and RTL scenarios that need real embedding live in
// the platform embedding tests.

@MainActor
private func waitForBridgeCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

/// A `NativeScrollBacking` test double: tracks every call the renderer/bridge makes, and lets a
/// test simulate a native-driven offset/phase tick without any real platform view.
@MainActor
private final class FakeScrollBacking: NativeScrollBacking {
    let nodeID: NodeID
    weak var delegate: (any NativeScrollBackingDelegate)?
    let containerLayer = CALayer()
    private(set) var installedContentLayer: CALayer?
    var contentOffset = LayoutPoint(x: 0, y: 0)
    private(set) var lastContentSize: MeasuredSize?
    private(set) var lastInsets: DirectionalEdgeInsets?
    private(set) var lastConfiguration: ScrollConfiguration?
    private(set) var scrollCallCount = 0
    private(set) var removedContentLayerCount = 0
    private(set) var disposeCount = 0
    private(set) var childBackings: [NodeID: FakeScrollBacking] = [:]
    /// When set, `scroll(to:animated:completion:)` stores the completion instead of calling it
    /// synchronously — a test resolves it explicitly to simulate a real animated command.
    var deferCompletions = false
    private var pendingCompletion: (@MainActor (Bool) -> Void)?

    init(nodeID: NodeID, delegate: any NativeScrollBackingDelegate) {
        self.nodeID = nodeID
        self.delegate = delegate
    }

    var viewportSize: MeasuredSize {
        MeasuredSize(
            width: Double(containerLayer.bounds.width),
            height: Double(containerLayer.bounds.height)
        )
    }

    func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
        // Mirrors a real backing's `setFrame(_:)`: only the layer's size is observable through
        // `viewportSize` here (no real `UIView`/`NSView` in this test double), `bounds.origin`
        // is left untouched so it keeps standing in for the native content offset.
        containerLayer.bounds = CGRect(
            origin: containerLayer.bounds.origin,
            size: CGSize(width: frame.width, height: frame.height)
        )
        containerLayer.position = CGPoint(x: frame.origin.x, y: frame.origin.y)
    }

    var contentOriginInHost: LayoutPoint {
        LayoutPoint(x: Double(containerLayer.position.x), y: Double(containerLayer.position.y))
    }

    func setContentSize(_ size: MeasuredSize) { lastContentSize = size }
    func setInsets(_ insets: DirectionalEdgeInsets) { lastInsets = insets }
    func apply(configuration: ScrollConfiguration) { lastConfiguration = configuration }

    func makeChildBacking(nodeID: NodeID) -> (any NativeScrollBacking)? {
        guard let delegate else { return nil }
        let child = FakeScrollBacking(nodeID: nodeID, delegate: delegate)
        childBackings[nodeID] = child
        return child
    }

    func installContentLayer(_ layer: CALayer) {
        installedContentLayer = layer
        containerLayer.addSublayer(layer)
    }

    func removeContentLayer() {
        installedContentLayer?.removeFromSuperlayer()
        installedContentLayer = nil
        removedContentLayerCount += 1
    }

    func dispose() { disposeCount += 1 }

    func scroll(
        to offset: LayoutPoint,
        animated: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        scrollCallCount += 1
        contentOffset = offset
        if deferCompletions {
            pendingCompletion = completion
        } else {
            completion(true)
        }
    }

    /// Resolves a deferred `scroll(to:...)` completion — simulates the native animation finishing
    /// (`finished: true`) or being interrupted (`finished: false`).
    func resolvePending(finished: Bool) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(finished)
    }

    /// Simulates a native-driven offset/phase change — a drag tick, deceleration, or the
    /// backing's own intermediate animation frames.
    func simulateNativeOffset(_ offset: LayoutPoint, phase: ScrollPhase) {
        contentOffset = offset
        delegate?.scrollBacking(for: nodeID, didChangeOffset: offset, phase: phase)
    }
}

/// Collects every `FakeScrollBacking` a bridge's `scrollBackingFactory` creates, keyed by node.
/// Also keeps the test's host `CALayer` alive: `NodeHostBridge` only holds it `weak` (a real
/// `UIView`/`NSView` normally owns both the bridge and the layer) — a bare
/// `NodeHostBridge(hostLayer: CALayer())` literal would deallocate the layer the instant the
/// helper that created it returns, silently breaking every commit after the first (found
/// while writing this test: `test_scrollNode_removedFromTreeReleasesItsBacking`'s second commit
/// otherwise skips `LayerRenderer` entirely, `docs/validation/r07-scroll-node.md`).
@MainActor
private final class FakeScrollBackingRegistry {
    private(set) var backings: [NodeID: FakeScrollBacking] = [:]
    let hostLayer = CALayer()

    func factory(_ nodeID: NodeID, _ delegate: any NativeScrollBackingDelegate)
        -> any NativeScrollBacking
    {
        let backing = FakeScrollBacking(nodeID: nodeID, delegate: delegate)
        backings[nodeID] = backing
        return backing
    }
}

@MainActor
private func attachedBridge(
    root: Node,
    bounds: LayoutFrame = LayoutFrame(width: 400, height: 400)
) async -> (bridge: NodeHostBridge, registry: FakeScrollBackingRegistry) {
    let registry = FakeScrollBackingRegistry()
    let bridge = NodeHostBridge(hostLayer: registry.hostLayer)
    let factory: NativeScrollBackingFactory = { registry.factory($0, $1) }
    let attached = bridge.attach(
        root: root,
        bounds: bounds,
        scale: 1,
        scrollBackingFactory: factory
    )
    #expect(attached)
    await waitForBridgeCommits(bridge, 1)
    return (bridge, registry)
}

// MARK: - Renderer wiring

@Test
@MainActor
func test_scrollNode_registersBackingContainerLayerAsItsOwnLayer() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]

    #expect(bridge.layer(for: scroll.id) === backing?.containerLayer)
}

@Test
@MainActor
func test_scrollNode_childrenAreParentedUnderTheInstalledContentLayerNotTheContainer() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    let child = Node()
    child.style.width = 50
    child.style.height = 50
    scroll.addSubnode(child)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    let childLayer = bridge.layer(for: child.id)

    #expect(childLayer?.superlayer === backing?.installedContentLayer)
    #expect(childLayer?.superlayer !== backing?.containerLayer)
}

@Test
@MainActor
func test_nestedScrollNodeUsesItsNearestNativeContentSurface() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let outer = ScrollNode()
    outer.style.width = 300
    outer.style.height = 300
    let inner = ScrollNode()
    inner.style.width = 200
    inner.style.height = 120
    outer.addSubnode(inner)
    root.addSubnode(outer)

    let (bridge, registry) = await attachedBridge(root: root)
    let outerBacking = registry.backings[outer.id]
    let innerBacking = outerBacking?.childBackings[inner.id]

    #expect(innerBacking != nil)
    #expect(bridge.layer(for: inner.id) === innerBacking?.containerLayer)
    #expect(registry.backings[inner.id] == nil)
    #expect(innerBacking?.contentOriginInHost == inner.calculatedFrame?.origin)
}

@Test
@MainActor
func test_scrollNode_contentSizeForEmptyOrShortContentEqualsViewportNotSmaller() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let empty = ScrollNode()
    empty.style.width = 300
    empty.style.height = 200
    root.addSubnode(empty)

    let (_, registry) = await attachedBridge(root: root)
    let backing = registry.backings[empty.id]

    #expect(backing?.lastContentSize == MeasuredSize(width: 300, height: 200))
}

@Test
@MainActor
func test_scrollNode_contentSizeForLongContentIsTheChildUnionBeyondTheViewport() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let tallChild = Node()
    tallChild.style.width = 300
    tallChild.style.height = 900
    scroll.addSubnode(tallChild)
    root.addSubnode(scroll)

    let (_, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]

    #expect(backing?.lastContentSize == MeasuredSize(width: 300, height: 900))
}

@Test
@MainActor
func test_scrollNode_appliesConfigurationWithoutASecondLayoutSnapshot() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    scroll.configuration = ScrollConfiguration(
        axis: .horizontal,
        userInteractionEnabled: false,
        directionalLockEnabled: true,
        indicators: .hidden,
        bounce: .never,
        keyboardDismissMode: .onDrag
    )
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    #expect(registry.backings[scroll.id]?.lastConfiguration == scroll.configuration)
    let snapshots = bridge.layoutSnapshotCount

    registry.backings[scroll.id]?.simulateNativeOffset(LayoutPoint(x: 0, y: 0), phase: .idle)

    #expect(bridge.layoutSnapshotCount == snapshots)
}

@Test
@MainActor
func test_scrollNode_removedFromTreeReleasesItsBacking() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    scroll.removeFromSupernode()
    await waitForBridgeCommits(bridge, 2)

    #expect(backing?.removedContentLayerCount == 1)
    #expect(bridge.layer(for: scroll.id) == nil)
}

// MARK: - Offset-aware hit-testing (D18)

@Test
@MainActor
func test_hitTest_pointInsideScrollNodeViewportHitsTheChildAtCurrentOffset() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let first = ControlNode()
    first.style.width = 300
    first.style.height = 200
    let second = ControlNode()
    second.style.width = 300
    second.style.height = 200
    scroll.addSubnode(first)
    scroll.addSubnode(second)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]

    // Before any scroll: a point in the viewport hits `first` (content-space y 0...200).
    #expect(bridge.hitTest(LayoutPoint(x: 10, y: 10)) == first.id)

    // Scroll down by the full first child's height: the same viewport point now names `second`
    // — `contentPoint = viewportPoint + offset` (§1), the one conversion hit-test shares with
    // reveal/AX.
    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 200), phase: .idle)
    #expect(bridge.hitTest(LayoutPoint(x: 10, y: 10)) == second.id)
}

@Test
@MainActor
func test_scrollOffset_republishesFocusAndAccessibilityGeometryWithoutLayout() async {
    let root = Node()
    root.style.width = 300
    root.style.height = 200
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let first = ControlNode()
    first.style.width = 300
    first.style.height = 200
    let second = ControlNode()
    second.style.width = 300
    second.style.height = 200
    second.focus.isFocusable = true
    second.accessibility.label = "Second"
    scroll.addSubnode(first)
    scroll.addSubnode(second)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(
        root: root,
        bounds: LayoutFrame(width: 300, height: 200)
    )
    let before = bridge.semanticSnapshot?.record(for: second.id)
    #expect(before?.visibleBounds == nil)
    #expect(bridge.focus(second.id) == .unavailable)
    let snapshots = bridge.layoutSnapshotCount

    registry.backings[scroll.id]?.simulateNativeOffset(LayoutPoint(x: 0, y: 200), phase: .dragging)

    let after = bridge.semanticSnapshot?.record(for: second.id)
    #expect(
        after?.visibleBounds
            == LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 200)
    )
    #expect(bridge.focus(second.id) != .unavailable)
    #expect(bridge.layoutSnapshotCount == snapshots)
}

@Test
@MainActor
func test_hitTest_offsetOnlyTickDoesNotRequestANewLayoutSnapshot() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    let child = Node()
    child.style.width = 300
    child.style.height = 900
    scroll.addSubnode(child)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    let snapshotCountBefore = bridge.layoutSnapshotCount
    let committedBefore = bridge.committedCount

    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 50), phase: .dragging)
    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 120), phase: .dragging)
    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 200), phase: .idle)

    // The concrete meaning of "offset-only путь" (R07's plan): no new layout snapshot, no new
    // geometry commit — hit-test still reflects the latest offset via `withScrollOffsets(_:)`.
    #expect(bridge.layoutSnapshotCount == snapshotCountBefore)
    #expect(bridge.committedCount == committedBefore)
    #expect(bridge.hitTestSnapshot?.scrollOffsets[scroll.id] == LayoutPoint(x: 0, y: 200))
}

@Test
@MainActor
func test_hitTest_d18NearestAncestorRoutingForNestedScrollNodes() async {
    // Two nested `ScrollNode`s, each scrolled independently — a point inside the inner one must
    // resolve through *both* ancestors' own offsets, applied nearest-first as the walk
    // descends, not by finding "the" scroll node anywhere in the tree (D18, replacing Weave's
    // `findScrollNode(in:)` first-match search, `docs/weave-scroll-analysis.md` §7 (6)).
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let outer = ScrollNode()
    outer.style.flexDirection = .column
    outer.style.width = 300
    outer.style.height = 200
    let outerSpacer = Node()
    outerSpacer.style.width = 300
    outerSpacer.style.height = 400
    let inner = ScrollNode()
    inner.style.flexDirection = .column
    inner.style.width = 300
    inner.style.height = 200
    let innerFirst = ControlNode()
    innerFirst.style.width = 300
    innerFirst.style.height = 200
    let innerSecond = ControlNode()
    innerSecond.style.width = 300
    innerSecond.style.height = 200
    inner.addSubnode(innerFirst)
    inner.addSubnode(innerSecond)
    outer.addSubnode(outerSpacer)
    outer.addSubnode(inner)
    root.addSubnode(outer)

    let (bridge, registry) = await attachedBridge(root: root)
    let outerBacking = registry.backings[outer.id]
    let innerBacking = outerBacking?.childBackings[inner.id] ?? registry.backings[inner.id]

    // Scroll the outer node down exactly past the spacer, so `inner` is at the top of the
    // outer's viewport.
    outerBacking?.simulateNativeOffset(LayoutPoint(x: 0, y: 400), phase: .idle)
    #expect(bridge.hitTest(LayoutPoint(x: 10, y: 10)) == innerFirst.id)

    // Now scroll the *inner* node too — only the inner offset should move which of its own
    // children is hit; the outer offset already resolved which ancestor content is on screen.
    innerBacking?.simulateNativeOffset(LayoutPoint(x: 0, y: 200), phase: .idle)
    #expect(bridge.hitTest(LayoutPoint(x: 10, y: 10)) == innerSecond.id)
}

@Test
@MainActor
func test_hitTest_scrollNodeOffsetCombinesWithAncestorTransform() async {
    // Nested clip/transform + scroll (R07 checklist bullet 3): a `ScrollNode` behind a rotated
    // ancestor still resolves hit-testing correctly — the existing transform math (D17, ADR
    // 0010) and the new offset math compose without special-casing either.
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let rotated = Node()
    rotated.style.width = 300
    rotated.style.height = 300
    rotated.style.visual = LayoutVisualProperties(
        transform: LayoutTransform(translationX: 20, translationY: 30)
    )
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let first = ControlNode()
    first.style.width = 300
    first.style.height = 200
    let second = ControlNode()
    second.style.width = 300
    second.style.height = 200
    scroll.addSubnode(first)
    scroll.addSubnode(second)
    rotated.addSubnode(scroll)
    root.addSubnode(rotated)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]

    // The ancestor's `translationX: 20, translationY: 30` transform means a host-space point
    // must be offset by that same translation to land at content-space (10, 10) inside
    // `scroll` — the existing D17/ADR 0010 transform math and this card's offset math compose
    // without special-casing either.
    #expect(bridge.hitTest(LayoutPoint(x: 30, y: 40)) == first.id)
    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 200), phase: .idle)
    #expect(bridge.hitTest(LayoutPoint(x: 30, y: 40)) == second.id)
}

// MARK: - ScrollCommandIssuing (§7)

@Test
@MainActor
func test_scrollCommand_notAttachedBeforeAnyCommitOrAfterDetach() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    root.addSubnode(scroll)

    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)
    var outcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.to(LayoutPoint(x: 0, y: 100), animated: false), on: scroll) {
        outcomes.append($0)
    }
    #expect(outcomes == [.notAttached])

    let registry = FakeScrollBackingRegistry()
    let factory: NativeScrollBackingFactory = { registry.factory($0, $1) }
    let attached = bridge.attach(
        root: root,
        bounds: LayoutFrame(width: 400, height: 400),
        scale: 1,
        scrollBackingFactory: factory
    )
    #expect(attached)
    await waitForBridgeCommits(bridge, 1)

    outcomes.removeAll()
    bridge.detach()
    bridge.scroll(.to(LayoutPoint(x: 0, y: 100), animated: false), on: scroll) {
        outcomes.append($0)
    }
    #expect(outcomes == [.notAttached])
}

@Test
@MainActor
func test_scrollCommand_pendingCompletionResolvesNotAttachedOnDetach() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let child = Node()
    child.style.width = 300
    child.style.height = 900
    scroll.addSubnode(child)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    backing?.deferCompletions = true

    var outcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.to(LayoutPoint(x: 0, y: 300), animated: true), on: scroll) {
        outcomes.append($0)
    }
    #expect(outcomes.isEmpty)

    bridge.detach()
    #expect(outcomes == [.notAttached])
}

@Test
@MainActor
func test_scrollCommand_secondCommandSupersedesTheFirstSynchronously() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let child = Node()
    child.style.width = 300
    child.style.height = 900
    scroll.addSubnode(child)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    backing?.deferCompletions = true

    var firstOutcomes: [ScrollCommandOutcome] = []
    var secondOutcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.to(LayoutPoint(x: 0, y: 300), animated: true), on: scroll) {
        firstOutcomes.append($0)
    }
    #expect(firstOutcomes.isEmpty)

    bridge.scroll(.to(LayoutPoint(x: 0, y: 500), animated: true), on: scroll) {
        secondOutcomes.append($0)
    }

    // The first command resolves synchronously with the second call, before either backing
    // command finishes natively — never left dangling (§7, §9).
    #expect(firstOutcomes == [.supersededByLaterCommand])
    #expect(secondOutcomes.isEmpty)

    backing?.resolvePending(finished: true)
    #expect(secondOutcomes.count == 1)
    guard case .completed = secondOutcomes.first else {
        Issue.record("expected the second, still-pending command to complete")
        return
    }
}

@Test
@MainActor
func test_scrollCommand_userInputInterruptsAPendingAnimatedCommand() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let child = Node()
    child.style.width = 300
    child.style.height = 900
    scroll.addSubnode(child)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    backing?.deferCompletions = true

    var outcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.to(LayoutPoint(x: 0, y: 300), animated: true), on: scroll) {
        outcomes.append($0)
    }
    #expect(outcomes.isEmpty)

    // Scenario 2, §10: the user begins a drag before the programmatic command finishes.
    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 10), phase: .dragging)

    #expect(outcomes == [.cancelledByUserInput])
}

@Test
@MainActor
func test_scrollCommand_issuedWhileUserDrivenIsRefusedImmediately() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let child = Node()
    child.style.width = 300
    child.style.height = 900
    scroll.addSubnode(child)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]
    backing?.simulateNativeOffset(LayoutPoint(x: 0, y: 10), phase: .dragging)

    var outcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.to(LayoutPoint(x: 0, y: 300), animated: true), on: scroll) {
        outcomes.append($0)
    }

    #expect(outcomes == [.cancelledByUserInput])
    #expect(backing?.scrollCallCount == 0)
}

@Test
@MainActor
func test_scrollCommand_revealAlreadyVisibleCompletesSynchronouslyWithoutMovement() async {
    // Scenario 6, §10.
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let first = Node()
    first.style.width = 300
    first.style.height = 100
    let second = Node()
    second.style.width = 300
    second.style.height = 900
    scroll.addSubnode(first)
    scroll.addSubnode(second)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]

    guard let firstFrame = first.calculatedFrame else {
        Issue.record("expected a committed frame")
        return
    }

    var outcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.reveal(frame: firstFrame, alignment: .nearest, animated: false), on: scroll) {
        outcomes.append($0)
    }

    #expect(outcomes.count == 1)
    guard case .completed = outcomes.first else {
        Issue.record("expected .completed")
        return
    }
    #expect(backing?.scrollCallCount == 0)
}

@Test
@MainActor
func test_scrollCommand_revealOfPartiallyVisibleNodeScrollsTheMinimumDistance() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.style.flexDirection = .column
    scroll.style.width = 300
    scroll.style.height = 200
    let first = Node()
    first.style.width = 300
    first.style.height = 300
    let second = Node()
    second.style.width = 300
    second.style.height = 300
    scroll.addSubnode(first)
    scroll.addSubnode(second)
    root.addSubnode(scroll)

    let (bridge, registry) = await attachedBridge(root: root)
    let backing = registry.backings[scroll.id]

    guard let secondFrame = second.calculatedFrame else {
        Issue.record("expected a committed frame")
        return
    }

    var outcomes: [ScrollCommandOutcome] = []
    bridge.scroll(.reveal(frame: secondFrame, alignment: .nearest, animated: false), on: scroll) {
        outcomes.append($0)
    }

    #expect(backing?.scrollCallCount == 1)
    guard case let .completed(state) = outcomes.first else {
        Issue.record("expected .completed")
        return
    }
    // `second` starts at content y=300, is 300 tall; nearest-alignment against a 200pt viewport
    // scrolls exactly enough to bring its trailing edge to the viewport's trailing edge.
    #expect(state.offset.y == 400)
}

// MARK: - R08 reveal and AX input

@MainActor
private func revealFixture() async -> (
    NodeHostBridge, FakeScrollBackingRegistry, ScrollNode, [ControlNode]
) {
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    scroll.style.flexDirection = .column
    let controls = (0..<4).map { _ in ControlNode() }
    for control in controls {
        control.style.width = 300
        control.style.height = 200
        scroll.addSubnode(control)
    }
    let (bridge, registry) = await attachedBridge(
        root: scroll,
        bounds: LayoutFrame(width: 300, height: 200)
    )
    _ = bridge.focus(controls[0].id)
    return (bridge, registry, scroll, controls)
}

@Test @MainActor
func test_r08_revealPrecedesNativeFocusConfirmation() async {
    let (bridge, registry, scroll, controls) = await revealFixture()
    let snapshots = bridge.layoutSnapshotCount
    #expect(bridge.focus(controls[1].id) == .unavailable)
    #expect(bridge.revealFocusTarget(.down) == controls[1].id)
    #expect(bridge.focusedID == nil)
    #expect(registry.backings[scroll.id]?.contentOffset.y == 200)
    #expect(bridge.semanticSnapshot?.record(for: controls[1].id)?.isFocusCandidate == true)
    #expect(bridge.focus(controls[1].id, reason: .native) != .unavailable)
    #expect(bridge.focusedID == controls[1].id)
    #expect(bridge.layoutSnapshotCount == snapshots)
}

@Test @MainActor
func test_r08_keyboardRevealAndReverseUseSameGeometry() async {
    let (bridge, registry, scroll, controls) = await revealFixture()
    #expect(bridge.send(.keyDown, key: KeyData(key: .downArrow)) == .handled)
    #expect(bridge.focusedID == controls[1].id)
    #expect(bridge.send(.keyDown, key: KeyData(key: .upArrow)) == .handled)
    #expect(bridge.focusedID == controls[0].id)
    #expect(registry.backings[scroll.id]?.contentOffset.y == 0)
}

@Test @MainActor
func test_r08_revealSkipsDisabledHiddenAndStaleTargets() async {
    let (bridge, registry, scroll, controls) = await revealFixture()
    controls[1].isEnabled = false
    controls[2].removeFromSupernode()
    #expect(bridge.revealFocusTarget(.down) == controls[3].id)
    #expect(registry.backings[scroll.id]?.contentOffset.y == 600)
}

@Test @MainActor
func test_r08_userMotionAndDetachRejectRevealAndAX() async {
    let (bridge, registry, scroll, controls) = await revealFixture()
    registry.backings[scroll.id]?.simulateNativeOffset(
        LayoutPoint(x: 0, y: 0),
        phase: .decelerating
    )
    #expect(bridge.revealFocusTarget(.down) == nil)
    #expect(!bridge.scrollAccessibility(.down, from: controls[0].id))
    bridge.detach()
    #expect(bridge.revealFocusTarget(.down) == nil)
    #expect(!bridge.scrollAccessibility(.down, from: controls[0].id))
}

@Test @MainActor
func test_r08_axPagesRespectAxisBoundaryAndStaleEndpoints() async {
    let (bridge, registry, scroll, controls) = await revealFixture()
    _ = bridge.focus(nil)
    let snapshots = bridge.layoutSnapshotCount
    #expect(!bridge.scrollAccessibility(.left, from: controls[0].id))
    #expect(!bridge.scrollAccessibility(.up, from: controls[0].id))
    #expect(bridge.scrollAccessibility(.down, from: controls[0].id))
    #expect(registry.backings[scroll.id]?.contentOffset.y == 200)
    #expect(bridge.focusedID == nil)
    #expect(!bridge.scrollAccessibility(.down, from: controls[0].id))
    #expect(bridge.scrollAccessibility(.up, from: controls[1].id))
    #expect(bridge.layoutSnapshotCount == snapshots)
}

@Test @MainActor
func test_r08_scopeAndDisabledInputDoNotMoveBackgroundScroll() async {
    let (bridge, registry, scroll, controls) = await revealFixture()
    bridge.setFocusScope(controls[0].id)
    #expect(bridge.revealFocusTarget(.down) == nil)
    #expect(!bridge.scrollAccessibility(.down, from: controls[0].id))
    bridge.setFocusScope(nil)
    scroll.configuration.userInteractionEnabled = false
    #expect(bridge.revealFocusTarget(.down) == nil)
    #expect(registry.backings[scroll.id]?.contentOffset.y == 0)
}

@Test @MainActor
func test_r08_detachInsideScrollCallbackDoesNotReturnAStaleFocusTarget() async {
    let (bridge, _, scroll, _) = await revealFixture()
    scroll.onScrollStateChanged = { [weak bridge] state in
        if state.offset.y > 0 { bridge?.detach() }
    }
    #expect(bridge.revealFocusTarget(.down) == nil)
    #expect(bridge.semanticSnapshot == nil)
}

@Test @MainActor
func test_r08_revealHonorsOrdinaryClipAndOpacity() async {
    let scroll = ScrollNode()
    scroll.style.width = 300
    scroll.style.height = 200
    scroll.style.flexDirection = .column
    let first = ControlNode()
    first.style.width = 300
    first.style.height = 200
    let clip = Node()
    clip.style.width = 300
    clip.style.height = 200
    clip.style.visual = LayoutVisualProperties(overflow: .hidden)
    let clipped = ControlNode()
    clipped.style.positionType = .absolute
    clipped.style.offsets = DirectionalEdgeOffsets(top: 300)
    clipped.style.width = 300
    clipped.style.height = 200
    clip.addSubnode(clipped)
    let transparent = ControlNode()
    transparent.style.width = 300
    transparent.style.height = 200
    transparent.style.visual = LayoutVisualProperties(opacity: 0)
    scroll.addSubnode(first)
    scroll.addSubnode(clip)
    scroll.addSubnode(transparent)
    let (bridge, registry) = await attachedBridge(
        root: scroll,
        bounds: LayoutFrame(width: 300, height: 200)
    )
    _ = bridge.focus(first.id)
    #expect(bridge.revealFocusTarget(.down) == nil)
    #expect(registry.backings[scroll.id]?.contentOffset.y == 0)
}

@Test @MainActor
func test_r08_nestedRevealMovesInnerThenOuterViewport() async {
    let outer = ScrollNode()
    outer.style.width = 300
    outer.style.height = 200
    outer.style.flexDirection = .column
    let first = ControlNode()
    first.style.width = 300
    first.style.height = 200
    let inner = ScrollNode()
    inner.style.width = 300
    inner.style.height = 200
    inner.style.flexDirection = .column
    let spacer = Node()
    spacer.style.width = 300
    spacer.style.height = 200
    let target = ControlNode()
    target.style.width = 300
    target.style.height = 200
    inner.addSubnode(spacer)
    inner.addSubnode(target)
    outer.addSubnode(first)
    outer.addSubnode(inner)
    let (bridge, registry) = await attachedBridge(
        root: outer,
        bounds: LayoutFrame(width: 300, height: 200)
    )
    _ = bridge.focus(first.id)
    #expect(bridge.revealFocusTarget(.down) == target.id)
    #expect(registry.backings[outer.id]?.contentOffset.y == 200)
    #expect(registry.backings[outer.id]?.childBackings[inner.id]?.contentOffset.y == 200)
    #expect(bridge.semanticSnapshot?.record(for: target.id)?.visibleBounds?.origin.y == 0)
}

@Test @MainActor
func test_r08_semanticCallbackCannotStartCommandOverTheCurrentDrag() async {
    let (bridge, registry, scroll, _) = await revealFixture()
    var outcome: ScrollCommandOutcome?
    bridge.onSemanticsPublished = { [weak bridge, weak scroll] _ in
        guard let bridge, let scroll else { return }
        bridge.scroll(.to(LayoutPoint(x: 0, y: 500), animated: true), on: scroll) { outcome = $0 }
    }
    registry.backings[scroll.id]?.simulateNativeOffset(LayoutPoint(x: 0, y: 10), phase: .dragging)
    #expect(outcome == .cancelledByUserInput)
    #expect(registry.backings[scroll.id]?.contentOffset.y == 10)
}

@Test @MainActor
func r09_presentedTransitionYieldsToScrollableContentAndClosesOnlyAtLeadingBoundary() async {
    let root = Node()
    root.style.width = 400
    root.style.height = 400
    let scroll = ScrollNode()
    scroll.configuration.axis = .vertical
    scroll.style.flexDirection = .column
    scroll.style.width = 400
    scroll.style.height = 400
    let source = Node()
    source.style.width = 100
    source.style.height = 100
    scroll.addSubnode(source)
    let articleBody = Node()
    articleBody.style.width = 400
    articleBody.style.height = 800
    scroll.addSubnode(articleBody)
    let destination = Node()
    destination.style.width = 100
    destination.style.height = 100
    root.addSubnode(scroll)
    root.addSubnode(destination)
    let (bridge, registry) = await attachedBridge(
        root: root,
        bounds: LayoutFrame(width: 400, height: 400)
    )
    let request = NodeHostBridge.TransitionRequest(
        source: source.id,
        destinationRoot: destination.id,
        roles: [.init(role: .hero, source: source.id, destination: destination.id)]
    )
    #expect(bridge.presentTransition(request))
    bridge.forceCompleteTransitionMotionForTesting()

    registry.backings[scroll.id]?.simulateNativeOffset(
        LayoutPoint(x: 0, y: 40),
        phase: .idle
    )
    #expect(
        !bridge.beginTransitionGesture(
            at: LayoutPoint(x: 200, y: 200),
            initialDelta: LayoutPoint(x: 0, y: 24)
        )
    )
    #expect(bridge.transitionSession?.state == .presented)

    registry.backings[scroll.id]?.simulateNativeOffset(
        LayoutPoint(x: 0, y: 0),
        phase: .idle
    )
    #expect(
        bridge.beginTransitionGesture(
            at: LayoutPoint(x: 200, y: 200),
            initialDelta: LayoutPoint(x: 0, y: 24)
        )
    )
    #expect(bridge.transitionSession?.state == .interactiveClosing)
}
