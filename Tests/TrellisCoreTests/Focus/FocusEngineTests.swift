import Foundation
import Testing

@testable import TrellisCore

// A04 — FocusEngine: deterministic search (D38), the transition transaction (D39) and
// re-validation on publish (§3.1). Case numbers refer to
// docs/validation/a01-focus-accessibility-contract.md §4 and §5.

@MainActor
private final class Recorder: ControlNode {
    var log: [String] = []
    var onFocusIn: (() -> Void)?
    var onFocusOut: (() -> Void)?

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        guard let focus = event.focus else { return }

        log.append(
            "\(event.type):\(focus.previous.map { "\($0)" } ?? "nil")->\(focus.next.map { "\($0)" } ?? "nil"):\(focus.reason)"
        )
        if event.type == .focusIn { onFocusIn?() }
        if event.type == .focusOut { onFocusOut?() }
    }
}

private func frame(_ x: Double, _ y: Double, _ w: Double = 80, _ h: Double = 80) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: w, height: h)
}

/// `R > [A, B, C]` at (0,0), (100,0), (200,0), all focusable controls, host 400×400.
@MainActor
private final class Fixture {
    let root = Node()
    let a = Recorder()
    let b = Recorder()
    let c = Recorder()
    let engine = FocusEngine()
    var changes: [FocusChange] = []
    var generation: UInt64 = 0
    var frames: [NodeID: LayoutFrame] = [:]
    var epoch: UInt64 = 1

    init() {
        root.addSubnode(a)
        root.addSubnode(b)
        root.addSubnode(c)
        frames = [
            root.id: frame(0, 0, 400, 400), a.id: frame(0, 0), b.id: frame(100, 0),
            c.id: frame(200, 0),
        ]
        engine.onFocusChange = { [weak self] change in self?.changes.append(change) }
        publish()
    }

    var focused: Recorder? { [a, b, c].first { $0.id == engine.focusedID } }

    /// Applies the current `frames` to every live node that has one and publishes.
    func publish() {
        var placements: [LayoutPlacement] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if let frame = frames[node.id] {
                placements.append(LayoutPlacement(identity: node.id, frame: frame))
            }
            stack.append(contentsOf: node.subnodes)
        }
        let result = LayoutResult(placements: placements, treeIdentity: root.id)
        #expect(root.applyLayoutResult(result))
        guard
            let geometry = HitTestSnapshot(
                root: root,
                mountEpoch: epoch,
                bounds: frame(0, 0, 400, 400)
            )
        else {
            Issue.record("no geometry")
            return
        }
        generation += 1
        engine.apply(
            SemanticSnapshot(
                geometry: geometry,
                root: root,
                geometryGeneration: generation,
                revision: generation,
                previous: engine.snapshot
            ),
            root: root
        )
    }

    @discardableResult
    func move(_ direction: FocusDirection) -> FocusMoveResult { engine.move(direction, root: root) }

    @discardableResult
    func focus(_ node: Node?) -> FocusMoveResult { engine.focus(node?.id, root: root) }
}

// MARK: - §4 traversal

@Test @MainActor
func a04_tabWalksPreorderAndStopsAtTheBoundary() {
    let f = Fixture()
    #expect(f.engine.focusedID == nil)
    // 1
    #expect(f.move(.next) == .moved(FocusChange(previous: nil, next: f.a.id, reason: .navigation)))
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )  // 2
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.b.id, next: f.c.id, reason: .navigation))
    )
    #expect(f.move(.next) == .unchanged)  // 3: no wrap outside a modal scope
    #expect(f.engine.focusedID == f.c.id)
    #expect(
        f.move(.previous)
            == .moved(FocusChange(previous: f.c.id, next: f.b.id, reason: .navigation))
    )  // 4
    #expect(
        f.move(.previous)
            == .moved(FocusChange(previous: f.b.id, next: f.a.id, reason: .navigation))
    )
    #expect(f.move(.previous) == .unchanged)
    #expect(f.engine.transitionRevision == 5)
    #expect(f.changes.count == 5)
}

@Test @MainActor
func a04_previousWithoutFocusPicksTheLastAndPriorityPicksTheInitial() {
    let f = Fixture()
    #expect(
        f.move(.previous) == .moved(FocusChange(previous: nil, next: f.c.id, reason: .navigation))
    )  // 5
    f.focus(nil)
    f.b.focus.priority = 10
    f.publish()
    #expect(f.move(.next) == .moved(FocusChange(previous: nil, next: f.b.id, reason: .navigation)))
    // Priority never bends Tab order once there is a focus: B → C, not B → A.
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.b.id, next: f.c.id, reason: .navigation))
    )
}

@Test @MainActor
func a04_zIndexAndCreationOrderDoNotAffectTabOrder() {
    // 6: C's NodeID is allocated before A's and B sits in front — Tab still goes A → B → C.
    let root = Node()
    let c = ControlNode()
    let a = ControlNode()
    let b = ControlNode()
    b.style.visual = LayoutVisualProperties(zIndex: 5)
    root.addSubnode(a)
    root.addSubnode(b)
    root.addSubnode(c)
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: frame(0, 0, 400, 400)),
            LayoutPlacement(identity: a.id, frame: frame(0, 0)),
            LayoutPlacement(identity: b.id, frame: frame(100, 0)),
            LayoutPlacement(identity: c.id, frame: frame(200, 0)),
        ],
        treeIdentity: root.id
    )
    #expect(root.applyLayoutResult(result))
    let engine = FocusEngine()
    guard let geometry = HitTestSnapshot(root: root, mountEpoch: 1, bounds: frame(0, 0, 400, 400))
    else {
        Issue.record("no geometry")
        return
    }
    engine.apply(
        SemanticSnapshot(geometry: geometry, root: root, geometryGeneration: 1, revision: 1),
        root: root
    )
    engine.move(.next, root: root)
    engine.move(.next, root: root)
    #expect(engine.focusedID == b.id)
    engine.move(.next, root: root)
    #expect(engine.focusedID == c.id)
}

@Test @MainActor
func a04_arrowsUseStrictlyPositiveProjectionAndTheScoreFormula() {
    let f = Fixture()
    let d = Recorder()
    f.root.addSubnode(d)
    // 7: B moved below A (projection on x is 0 → not a candidate for `.right`); D to the right.
    f.frames[f.b.id] = frame(0, 100)
    f.frames[d.id] = frame(100, 0)
    f.frames[f.c.id] = frame(100, 60)
    f.publish()
    f.focus(f.a)
    // 8: D at (100, 0) scores 100; C at (100, 60) scores 100 + 0.5·60 = 130.
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: d.id, reason: .navigation))
    )
    #expect(
        f.engine.lastTrace
            == FocusTrace(direction: .right, candidates: [d.id, f.c.id], selected: d.id)
    )
    f.focus(f.a)
    #expect(
        f.move(.down) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
    // From B (0, 100) upwards: A scores 100 + 0.5·0 = 100, C scores 40 + 0.5·100 = 90 — the
    // secondary distance is weighted, not ignored, so C wins.
    #expect(f.move(.up) == .moved(FocusChange(previous: f.b.id, next: f.c.id, reason: .navigation)))
    #expect(f.engine.lastTrace?.candidates == [f.c.id, f.a.id, d.id])  // D: 100 + 0.5·100
    // From C (100, 60) leftwards: B scores 100 + 0.5·40 = 120, A 100 + 0.5·60 = 130.
    #expect(
        f.move(.left) == .moved(FocusChange(previous: f.c.id, next: f.b.id, reason: .navigation))
    )
    f.focus(f.a)
    #expect(f.move(.left) == .unchanged)
    #expect(f.engine.lastTrace == FocusTrace(direction: .left, candidates: [], selected: nil))
    #expect(f.engine.focusedID == f.a.id)
}

@Test @MainActor
func a04_equalScoresBreakTiesByTraversalIndexNotByIdentityOrder() {
    // 9: B and C share a frame; the registry order is irrelevant — traversal index wins.
    let f = Fixture()
    f.frames[f.c.id] = frame(100, 0)
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
    #expect(f.engine.lastTrace?.candidates == [f.b.id, f.c.id])

    // Reorder the siblings live and commit: C now comes first in pre-order.
    f.root.moveSubnode(from: 2, to: 1)
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.c.id, reason: .navigation))
    )
    // Identity survived the reorder: the same NodeID is selected under its new index.
    #expect(f.engine.snapshot?.record(for: f.c.id)?.traversalIndex == 2)
}

@Test @MainActor
func a04_explicitOverrideWinsWhenValidAndIsIgnoredOtherwise() {
    let f = Fixture()
    f.a.focus.preferredNext[.right] = f.c.id  // 10
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.c.id, reason: .navigation))
    )
    #expect(
        f.engine.lastTrace == FocusTrace(direction: .right, candidates: [f.c.id], selected: f.c.id)
    )

    // 11: self, a disposed id, a disabled target — each falls back to the geometric search.
    f.focus(f.a)
    f.a.focus.preferredNext[.right] = f.a.id
    f.publish()
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
    f.focus(f.a)
    f.a.focus.preferredNext[.right] = NodeID(rawValue: 999_999)
    f.publish()
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
    f.focus(f.a)
    f.a.focus.preferredNext[.right] = f.c.id
    f.c.isEnabled = false
    f.publish()
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
}

@Test @MainActor
func a04_rightToLeftDoesNotChangePhysicalDirections() {
    let f = Fixture()
    f.root.setLayoutDirection(.rightToLeft)  // 12: geometry is what it is — frames unchanged here
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.right) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
    #expect(
        f.move(.left) == .moved(FocusChange(previous: f.b.id, next: f.a.id, reason: .navigation))
    )
}

@Test @MainActor
func a04_disabledInvisibleClippedAreSkippedButAccessibilityHideIsNot() {
    let f = Fixture()
    f.focus(f.a)
    f.b.isEnabled = false  // 13
    f.publish()
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.a.id, next: f.c.id, reason: .navigation))
    )

    f.b.isEnabled = true
    f.b.style.visual = LayoutVisualProperties(opacity: 0)  // 14
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.a.id, next: f.c.id, reason: .navigation))
    )

    f.b.style.visual = LayoutVisualProperties()
    f.frames[f.b.id] = frame(500, 500)  // 15: outside the host — nothing visible
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.a.id, next: f.c.id, reason: .navigation))
    )

    f.frames[f.b.id] = frame(100, 0)
    f.b.accessibility.childrenPolicy = .hide  // 16
    f.publish()
    f.focus(f.a)
    #expect(
        f.move(.next) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .navigation))
    )
}

@Test @MainActor
func a04_focusRequestRejectsNonCandidatesAndNonLiveTargets() {
    let f = Fixture()
    let plain = Node()
    f.root.addSubnode(plain)
    f.frames[plain.id] = frame(300, 0)
    f.publish()
    #expect(f.focus(plain) == .unavailable)  // not focusable
    #expect(f.engine.focus(NodeID(rawValue: 777_777), root: f.root) == .unavailable)
    #expect(f.focus(f.b) == .moved(FocusChange(previous: nil, next: f.b.id, reason: .request)))
    #expect(f.focus(f.b) == .unchanged)  // §5 2

    // Live guard: committed but reparented before the next commit — refused until it commits.
    f.c.removeFromSupernode()
    f.b.addSubnode(f.c)
    #expect(f.focus(f.c) == .unavailable)  // §5 14
    f.publish()
    #expect(f.focus(f.c) == .moved(FocusChange(previous: f.b.id, next: f.c.id, reason: .request)))

    // Live guard: disabled live but not yet published.
    f.a.isEnabled = false
    #expect(f.focus(f.a) == .unavailable)
    // An engine without a snapshot refuses everything.
    let cold = FocusEngine()
    #expect(cold.focus(f.a.id, root: f.root) == .unavailable)
    #expect(cold.move(.next, root: f.root) == .unavailable)
}

// MARK: - §5 transitions

@Test @MainActor
func a04_transitionDeliversFocusOutThenFocusInThenOneNotification() {
    let f = Fixture()
    f.focus(f.a)
    f.focus(f.b)  // 1
    #expect(f.a.log == ["focusIn:nil->\(f.a.id):request", "focusOut:\(f.a.id)->\(f.b.id):request"])
    #expect(f.b.log == ["focusIn:\(f.a.id)->\(f.b.id):request"])
    #expect(
        f.changes == [
            FocusChange(previous: nil, next: f.a.id, reason: .request),
            FocusChange(previous: f.a.id, next: f.b.id, reason: .request),
        ]
    )
    #expect(f.engine.transitionRevision == 2)
    f.focus(f.b)  // 2: no-op
    #expect(f.b.log.count == 1)
    #expect(f.changes.count == 2)
    #expect(f.engine.transitionRevision == 2)
}

@Test @MainActor
func a04_disposingNextInsideFocusOutEndsWithNoFocusAndOneNotification() {
    let f = Fixture()
    f.focus(f.a)
    f.changes.removeAll()
    f.a.onFocusOut = { [unowned f] in f.b.dispose() }
    let result = f.focus(f.b)  // 3
    #expect(result == .moved(FocusChange(previous: f.a.id, next: nil, reason: .invalidation)))
    #expect(f.engine.focusedID == nil)
    #expect(f.b.log.isEmpty)
    #expect(f.changes == [FocusChange(previous: f.a.id, next: nil, reason: .invalidation)])
}

@Test @MainActor
func a04_resetInsideFocusOutAbandonsTheTransition() {
    let f = Fixture()
    f.focus(f.a)
    f.changes.removeAll()
    f.a.onFocusOut = { [unowned f] in f.engine.reset() }  // 4: what a detach does
    #expect(f.focus(f.b) == .unavailable)
    #expect(f.engine.focusedID == nil)
    #expect(f.engine.snapshot == nil)
    #expect(f.b.log.isEmpty)
    #expect(f.changes.isEmpty)
}

@Test @MainActor
func a04_requestInsideFocusInIsDeferredAndRunsAfterTheCurrentTransition() {
    let f = Fixture()
    f.focus(f.a)
    f.changes.removeAll()
    var deferredResult: FocusMoveResult?
    f.b.onFocusIn = { [unowned f] in
        deferredResult = f.focus(f.c)  // 5
        #expect(f.engine.focusedID == f.b.id)
    }
    #expect(f.focus(f.b) == .moved(FocusChange(previous: f.a.id, next: f.b.id, reason: .request)))
    #expect(deferredResult == .deferred)
    #expect(f.engine.focusedID == f.c.id)
    #expect(
        f.changes == [
            FocusChange(previous: f.a.id, next: f.b.id, reason: .request),
            FocusChange(previous: f.b.id, next: f.c.id, reason: .request),
        ]
    )
    #expect(
        f.b.log == [
            "focusIn:\(f.a.id)->\(f.b.id):request", "focusOut:\(f.b.id)->\(f.c.id):request",
        ]
    )
    #expect(f.c.log == ["focusIn:\(f.b.id)->\(f.c.id):request"])
}

@Test @MainActor
func a04_callbackLoopIsCutAtTheDeferredLimit() {
    let f = Fixture()
    f.a.onFocusIn = { [unowned f] in f.focus(f.b) }  // 6
    f.b.onFocusIn = { [unowned f] in f.focus(f.a) }
    f.focus(f.a)
    #expect(f.changes.count == f.engine.deferredRequestLimit + 1)
    #expect(f.engine.droppedRequestCount == 1)
    #expect(f.engine.focusedID == f.a.id || f.engine.focusedID == f.b.id)
    // The engine is consistent afterwards: a plain request works and nothing is queued.
    f.a.onFocusIn = nil
    f.b.onFocusIn = nil
    let before = f.changes.count
    let current = f.engine.focusedID
    #expect(f.focus(f.c) == .moved(FocusChange(previous: current, next: f.c.id, reason: .request)))
    #expect(f.changes.count == before + 1)
}

@Test @MainActor
func a04_teardownInsideFocusInDoesNotCrashOrNotifyTwice() {
    let f = Fixture()
    f.focus(f.a)
    f.changes.removeAll()
    f.b.onFocusIn = { [unowned f] in
        f.root.dispose()
        f.engine.reset()
    }
    #expect(f.focus(f.b) == .unavailable)
    #expect(f.engine.focusedID == nil)
    #expect(f.changes.isEmpty)
}

// MARK: - §3.1 re-validation on publish

@Test @MainActor
func a04_removedFocusedNodeFallsBackToTheNextThenPreviousThenFirst() {
    let f = Fixture()
    f.focus(f.b)
    f.changes.removeAll()
    f.b.removeFromSupernode()  // 12: B gone → C (next by the previous order)
    f.publish()
    #expect(f.engine.focusedID == f.c.id)
    #expect(f.changes == [FocusChange(previous: f.b.id, next: f.c.id, reason: .invalidation)])
    #expect(f.c.log.last == "focusIn:\(f.b.id)->\(f.c.id):invalidation")

    f.c.removeFromSupernode()  // nothing after C → A (previous)
    f.publish()
    #expect(f.engine.focusedID == f.a.id)

    f.a.removeFromSupernode()  // empty → nil
    f.publish()
    #expect(f.engine.focusedID == nil)
    #expect(f.changes.last == FocusChange(previous: f.a.id, next: nil, reason: .invalidation))
    #expect(f.engine.snapshot?.focusCandidates(scope: nil) == [])
}

@Test @MainActor
func a04_disablingOrClippingTheFocusedNodeOnPublishFallsBack() {
    let f = Fixture()
    f.focus(f.b)
    f.b.isEnabled = false  // 13
    f.publish()
    #expect(f.engine.focusedID == f.c.id)
    #expect(f.b.log.last == "focusOut:\(f.b.id)->\(f.c.id):invalidation")

    f.frames[f.c.id] = frame(-500, 0)  // fully off the host
    f.publish()
    #expect(f.engine.focusedID == f.a.id)
}

@Test @MainActor
func a04_resizeKeepsFocusAndNewMountNeverInheritsTheOldEpoch() {
    let f = Fixture()
    f.focus(f.b)
    f.frames[f.root.id] = frame(0, 0, 800, 800)  // 15: resize
    f.publish()
    #expect(f.engine.focusedID == f.b.id)
    #expect(f.changes.count == 1)

    f.epoch = 2  // 17: a new attach
    f.publish()
    #expect(f.engine.focusedID == nil)
    #expect(f.engine.snapshot?.mountEpoch == 2)
    #expect(f.changes.count == 1)  // no events: the old tree was reset, not transitioned
}
