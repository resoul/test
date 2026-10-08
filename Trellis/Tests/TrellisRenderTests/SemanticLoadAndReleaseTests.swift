import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

#if canImport(AppKit)
    import AppKit

    @testable import TrellisAppKit
#endif

// A12 — load and release: 1000 semantic/focusable elements, bursts, fast moves, modal
// open/close, deep trees, and weak release of everything after detach. Counters, not
// wall-clock thresholds, are what is asserted here; timings live in
// docs/validation/measurements (Scripts/bench.py semantics-1000).

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<20_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func settle() async {
    for _ in 0..<300 { await Task.yield() }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<20_000 where !condition() { await Task.yield() }
}

@MainActor
private func makeGrid(_ count: Int) -> (Node, [ControlNode], Node) {
    let root = Node()
    root.style {
        $0.flexDirection = .row; $0.flexWrap = .wrap; $0.gap = 4
    }
    var controls: [ControlNode] = []
    for index in 0..<count {
        let control = ControlNode()
        control.style {
            $0.width = 40; $0.height = 24
        }
        control.accessibility.label = "Card \(index)"
        root.addSubnode(control)
        controls.append(control)
    }
    let modal = Node()
    modal.style {
        $0.width = 200; $0.height = 40; $0.flexDirection = .row
    }
    for _ in 0..<2 {
        let button = ControlNode()
        button.style {
            $0.width = 40; $0.height = 24
        }
        button.accessibility.label = "Dialog"
        modal.addSubnode(button)
    }
    root.addSubnode(modal)
    return (root, controls, modal)
}

@Test @MainActor
func a12_thousandElementsPublishOnceAndBurstsNeverSolve() async throws {
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)
    let (root, controls, modal) = makeGrid(1000)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 900, height: 4000), scale: 2))
    await waitForCommits(bridge, 1)

    let snapshot = try #require(bridge.semanticSnapshot)
    #expect(snapshot.count == 1004)
    #expect(snapshot.focusCandidates(scope: nil).count == 1002)
    #expect(bridge.accessibilityTree?.readingOrder.count == 1002)
    #expect(bridge.semanticPublishCount == 1)

    // Burst value changes on every control: one metadata-only publish, no solve.
    let requested = bridge.statistics.requested
    for (index, control) in controls.enumerated() { control.accessibility.value = "\(index)" }
    await settle()
    #expect(bridge.metadataOnlyPublishCount == 1)
    #expect(bridge.statistics.requested == requested)
    #expect(bridge.statistics.committed == 1)
    #expect(bridge.accessibilityTree?.element(for: controls[999].id)?.value == "999")

    // Fast moves: 1000 Tabs walk every candidate with one transition each, no layout.
    for _ in 0..<1000 { bridge.moveFocus(.next) }
    #expect(bridge.focusedID == controls[999].id)
    #expect(
        bridge.moveFocus(.next)
            == .moved(
                FocusChange(
                    previous: controls[999].id,
                    next: modal.subnodes[0].id,
                    reason: .navigation
                )
            )
    )
    #expect(bridge.statistics.requested == requested)

    // Modal open/close 100×: the tree is confined and restored every time, focus restored.
    bridge.focus(controls[5].id)
    let treesBefore = bridge.semanticPublishCount
    for _ in 0..<100 {
        bridge.setFocusScope(modal.id)
        #expect(bridge.accessibilityTree?.readingOrder.count == 2)
        #expect(bridge.focusedID == modal.subnodes[0].id)
        bridge.setFocusScope(nil)
        #expect(bridge.focusedID == controls[5].id)
    }
    #expect(bridge.accessibilityTree?.readingOrder.count == 1002)
    // Scope changes never republish the snapshot itself.
    #expect(bridge.semanticPublishCount == treesBefore)
    #expect(bridge.statistics.requested == requested)

    // Semantic-only burst never starts the solver; a geometry burst does exactly once.
    for control in controls { control.style.height = 26 }
    await waitForCommits(bridge, 2)
    #expect(bridge.statistics.requested == requested + 1)
    #expect(bridge.focusedID == controls[5].id)
    bridge.detach()
}

@Test @MainActor
func a12_detachReleasesBridgeRootControlsAndEngineStateWithNoLateCallbacks() async {
    weak var weakRoot: Node?
    weak var weakBridge: NodeHostBridge?
    weak var weakControl: ControlNode?
    var lateFocusChanges = 0
    var latePublishes = 0
    do {
        let hostLayer = CALayer()
        let bridge = NodeHostBridge(hostLayer: hostLayer)
        let (root, controls, modal) = makeGrid(200)
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 900, height: 2000), scale: 2))
        await waitForCommits(bridge, 1)
        bridge.onFocusChange = { _ in lateFocusChanges += 1 }
        bridge.onSemanticsPublished = { _ in latePublishes += 1 }
        bridge.focus(controls[3].id)
        bridge.setFocusScope(modal.id)
        bridge.send(.keyDown, key: KeyData(key: .returnKey))  // an open press cycle
        weakRoot = root
        weakBridge = bridge
        weakControl = controls[3]
        let focusChanges = lateFocusChanges
        let publishes = latePublishes
        bridge.detach()
        #expect(bridge.focusedID == nil)
        #expect(bridge.focusScopeID == nil)
        #expect(bridge.semanticSnapshot == nil)
        #expect(bridge.accessibilityTree == nil)
        #expect(bridge.activePointerSessionCount == 0)
        // Mutations after detach reach nobody.
        controls[4].accessibility.label = "late"
        controls[4].style.width = 50
        await settle()
        #expect(lateFocusChanges == focusChanges)
        #expect(latePublishes == publishes)
        bridge.onFocusChange = nil
        bridge.onSemanticsPublished = nil
    }
    #expect(weakRoot == nil)
    #expect(weakBridge == nil)
    #expect(weakControl == nil)
}

@Test @MainActor
func a12_repeatedAttachDetachDoesNotAccumulateAndDeepTreesBuildIteratively() async {
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)
    for cycle in 0..<20 {
        let (root, controls, _) = makeGrid(100)
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 900, height: 1000), scale: 2))
        await waitForCommits(bridge, 1)
        bridge.focus(controls[cycle % 100].id)
        bridge.moveFocus(.next)
        bridge.detach()
        #expect(bridge.semanticSnapshot == nil)
        #expect(bridge.focusedID == nil)
    }
    #expect(bridge.mountEpoch == 20)

    // A deep chain: the semantic snapshot and the tree are built without recursion over
    // depth — the test thread's 512 KiB stack is enough.
    let root = Node()
    var parent = root
    var deepest: ControlNode?
    for level in 0..<1500 {
        let child: Node = level == 1499 ? ControlNode() : Node()
        child.style {
            $0.width = 400; $0.height = 400
        }
        // Every 50th level is a labelled group on the way down; the rest are transparent.
        child.accessibility = AccessibilityProperties(
            isElement: level % 50 == 0 || level == 1499,
            label: level % 50 == 0 || level == 1499 ? "L\(level)" : nil
        )
        parent.addSubnode(child)
        parent = child
        deepest = child as? ControlNode
    }
    let result = LayoutResult(
        placements: sequence(first: root, next: { $0.subnodes.first }).map {
            LayoutPlacement(identity: $0.id, frame: LayoutFrame(width: 400, height: 400))
        },
        treeIdentity: root.id
    )
    #expect(root.applyLayoutResult(result))
    guard
        let geometry = HitTestSnapshot(
            root: root,
            mountEpoch: 1,
            bounds: LayoutFrame(width: 400, height: 400)
        )
    else {
        Issue.record("no geometry")
        return
    }
    let snapshot = SemanticSnapshot(
        geometry: geometry,
        root: root,
        geometryGeneration: 1,
        revision: 1
    )
    #expect(snapshot.count == 1501)
    #expect(snapshot.record(for: deepest?.id ?? root.id)?.traversalIndex == 1500)
    let tree = AccessibilityTree.build(from: snapshot, scope: nil)
    #expect(tree.readingOrder.count == 1)  // only the deepest control is a leaf
    #expect(tree.count == 31)  // 30 labelled groups on the way down plus the leaf
    #expect(snapshot.focusCandidates(scope: nil) == [deepest?.id].compactMap { $0 })
}

#if canImport(AppKit)
    @MainActor
    private func waitForAppKitCommit(_ host: TrellisHostView) async {
        for _ in 0..<20_000 where host.layer?.sublayers?.isEmpty != false { await Task.yield() }
    }

    @Test @MainActor
    func a12_appKitElementsAreBoundedByTheTreeNotByCommitsAndReleaseOnDetach() async {
        weak var weakElement: TrellisAccessibilityElement?
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 2000))
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let (root, controls, _) = makeGrid(300)
        host.attach(root: root)
        await waitForAppKitCommit(host)
        await settle()
        #expect(host.nativeAccessibilityElementCount == 302)
        let created = host.createdNativeAccessibilityElementTotal
        #expect(created == 302)
        weakElement = host.accessibilityCoordinatorForTesting?.element(for: controls[0].id)

        // 20 geometry commits and 20 value bursts: no new element is ever created.
        for i in 0..<20 {
            let target = host.accessibilityCoordinatorForTesting.map { _ in i } ?? i
            for control in controls { control.style.height = .points(Double(25 + (i % 2))) }
            for control in controls { control.accessibility.value = "\(i)" }
            await waitUntil {
                host.accessibilityCoordinatorForTesting?.element(for: controls[0].id)?
                    .accessibilityValue() as? String == "\(target)"
            }
        }
        #expect(host.nativeAccessibilityElementCount == 302)
        #expect(host.createdNativeAccessibilityElementTotal == created)

        // A removed control drops exactly its element; a re-added one gets a new one.
        controls[10].removeFromSupernode()
        await waitUntil { host.nativeAccessibilityElementCount == 301 }
        #expect(host.nativeAccessibilityElementCount == 301)
        root.addSubnode(controls[10])
        await waitUntil { host.nativeAccessibilityElementCount == 302 }
        #expect(host.nativeAccessibilityElementCount == 302)
        #expect(host.createdNativeAccessibilityElementTotal == created + 1)

        host.detach()
        #expect(host.nativeAccessibilityElementCount == 0)
        await settle()
        #expect(weakElement == nil)
    }
#endif
