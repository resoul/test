import Foundation
import Testing

@testable import TrellisCore

// A05 — one modal scope per engine with restoration (D40), and the lifecycle rules of
// docs/validation/a01-focus-accessibility-contract.md §5 7–11, 16–17.

@MainActor
private final class Recorder: ControlNode {
    var log: [String] = []

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        guard let focus = event.focus else { return }

        log.append("\(event.type):\(focus.reason)")
    }
}

private func frame(_ x: Double, _ y: Double, _ w: Double = 80, _ h: Double = 80) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: w, height: h)
}

/// `R > [A, modal > [X, Y]]` — A in the background at (0, 0); X, Y inside the modal at
/// (100, 100) and (200, 100). The modal container itself is not focusable.
@MainActor
private final class Fixture {
    let root = Node()
    let a = Recorder()
    let modal = Node()
    let x = Recorder()
    let y = Recorder()
    let engine = FocusEngine()
    var changes: [FocusChange] = []
    var frames: [NodeID: LayoutFrame] = [:]
    var generation: UInt64 = 0
    var epoch: UInt64 = 1

    init() {
        root.addSubnode(a)
        root.addSubnode(modal)
        modal.addSubnode(x)
        modal.addSubnode(y)
        frames = [
            root.id: frame(0, 0, 400, 400), a.id: frame(0, 0), modal.id: frame(100, 100, 200, 100),
            x.id: frame(100, 100), y.id: frame(200, 100),
        ]
        engine.onFocusChange = { [weak self] change in self?.changes.append(change) }
        publish()
    }

    func publish() {
        var placements: [LayoutPlacement] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if let frame = frames[node.id] {
                placements.append(LayoutPlacement(identity: node.id, frame: frame))
            }
            stack.append(contentsOf: node.subnodes)
        }
        #expect(root.applyLayoutResult(LayoutResult(placements: placements, treeIdentity: root.id)))
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
}

@Test @MainActor
func a05_openingAScopeConfinesFocusAndWrapsSequentialMovesInsideIt() {
    let f = Fixture()
    f.engine.focus(f.a.id, root: f.root)
    f.changes.removeAll()

    f.engine.setScope(f.modal.id, root: f.root)  // §5 7
    #expect(f.engine.scopeID == f.modal.id)
    #expect(f.engine.restorationID == f.a.id)
    #expect(f.engine.focusedID == f.x.id)
    #expect(f.changes == [FocusChange(previous: f.a.id, next: f.x.id, reason: .scope)])
    #expect(f.a.log.last == "focusOut:scope")
    #expect(f.x.log.last == "focusIn:scope")

    #expect(f.engine.focus(f.a.id, root: f.root) == .unavailable)  // background is off limits
    #expect(
        f.engine.move(.next, root: f.root)
            == .moved(FocusChange(previous: f.x.id, next: f.y.id, reason: .navigation))
    )
    #expect(
        f.engine.move(.next, root: f.root)
            == .moved(FocusChange(previous: f.y.id, next: f.x.id, reason: .navigation))
    )  // wrap
    #expect(
        f.engine.move(.previous, root: f.root)
            == .moved(FocusChange(previous: f.x.id, next: f.y.id, reason: .navigation))
    )  // wrap back
    #expect(f.engine.move(.right, root: f.root) == .unchanged)  // arrows never wrap
    #expect(f.engine.move(.up, root: f.root) == .unchanged)  // A is above but outside the scope
    #expect(f.engine.focusedID == f.y.id)
}

@Test @MainActor
func a05_overrideCannotLeaveTheScopeAndSameScopeTwiceIsNoOp() {
    let f = Fixture()
    f.x.focus.preferredNext[.up] = f.a.id
    f.publish()
    f.engine.setScope(f.modal.id, root: f.root)
    #expect(f.engine.focusedID == f.x.id)
    // The override to the background is ignored.
    #expect(f.engine.move(.up, root: f.root) == .unchanged)
    let revision = f.engine.transitionRevision
    f.engine.setScope(f.modal.id, root: f.root)  // §5 10
    #expect(f.engine.transitionRevision == revision)
    #expect(f.engine.restorationID == nil)  // nothing was focused before the scope opened
    f.engine.setScope(NodeID(rawValue: 555_555), root: f.root)  // unknown: rejected
    #expect(f.engine.scopeID == f.modal.id)
}

@Test @MainActor
func a05_emptyScopeHoldsNoFocusAndNeverReleasesItToTheBackground() {
    let f = Fixture()
    f.engine.focus(f.a.id, root: f.root)
    f.x.isEnabled = false
    f.y.isEnabled = false
    f.publish()
    f.engine.setScope(f.modal.id, root: f.root)  // §5 8
    #expect(f.engine.focusedID == nil)
    #expect(f.engine.move(.next, root: f.root) == .unchanged)
    #expect(f.engine.move(.previous, root: f.root) == .unchanged)
    #expect(f.engine.focus(f.a.id, root: f.root) == .unavailable)
    #expect(f.engine.focusedID == nil)

    // A candidate appearing inside the scope on a later publish does not steal focus by
    // itself; the next move finds it.
    f.y.isEnabled = true
    f.publish()
    #expect(f.engine.focusedID == nil)
    #expect(
        f.engine.move(.next, root: f.root)
            == .moved(FocusChange(previous: nil, next: f.y.id, reason: .navigation))
    )
}

@Test @MainActor
func a05_closingRestoresThePreviousFocusOrFallsBackToTheFirstCandidate() {
    let f = Fixture()
    f.engine.focus(f.a.id, root: f.root)
    f.engine.setScope(f.modal.id, root: f.root)
    f.engine.move(.next, root: f.root)
    f.changes.removeAll()
    f.engine.setScope(nil, root: f.root)  // §5 9
    #expect(f.engine.scopeID == nil)
    #expect(f.engine.restorationID == nil)
    #expect(f.engine.focusedID == f.a.id)
    #expect(f.changes == [FocusChange(previous: f.y.id, next: f.a.id, reason: .restoration)])

    // The restoration target went away while the scope was open: first candidate instead.
    f.engine.setScope(f.modal.id, root: f.root)
    f.a.isEnabled = false
    f.publish()
    f.engine.setScope(nil, root: f.root)
    #expect(f.engine.focusedID == f.x.id)  // still focused inside; stays — it is a candidate
    f.engine.focus(nil, root: f.root)
    f.engine.setScope(f.modal.id, root: f.root)
    f.engine.setScope(nil, root: f.root)
    #expect(f.engine.focusedID == f.x.id)  // nothing to restore, X is the first candidate now
    #expect(f.changes.last?.reason == .scope)
}

@Test @MainActor
func a05_removingTheModalRootOnCommitClosesTheScopeAndRestores() {
    let f = Fixture()
    f.engine.focus(f.a.id, root: f.root)
    f.engine.setScope(f.modal.id, root: f.root)
    #expect(f.engine.focusedID == f.x.id)
    f.changes.removeAll()

    f.modal.removeFromSupernode()  // §5 11
    f.publish()
    #expect(f.engine.scopeID == nil)
    #expect(f.engine.restorationID == nil)
    #expect(f.engine.focusedID == f.a.id)
    #expect(f.changes == [FocusChange(previous: f.x.id, next: f.a.id, reason: .restoration)])
}

@Test @MainActor
func a05_currentFocusInsideTheScopeIsRevalidatedLikeAnywhereElse() {
    let f = Fixture()
    f.engine.setScope(f.modal.id, root: f.root)
    #expect(f.engine.focusedID == f.x.id)

    f.x.isEnabled = false  // disable current → Y
    f.publish()
    #expect(f.engine.focusedID == f.y.id)

    f.y.removeFromSupernode()  // dispose/remove current → nothing left in scope
    f.publish()
    #expect(f.engine.focusedID == nil)
    #expect(f.engine.scopeID == f.modal.id)

    f.x.isEnabled = true
    f.root.addSubnode(f.y)  // reparent Y outside the scope
    f.frames[f.y.id] = frame(300, 0)
    f.publish()
    #expect(
        f.engine.move(.next, root: f.root)
            == .moved(FocusChange(previous: nil, next: f.x.id, reason: .navigation))
    )
    #expect(f.engine.focus(f.y.id, root: f.root) == .unavailable)  // outside the scope now
}

@Test @MainActor
func a05_suspendKeepsOnlyTheRestorationIdentityAndResumeRestoresIt() {
    let f = Fixture()
    f.engine.setScope(f.modal.id, root: f.root)
    f.engine.move(.next, root: f.root)
    f.changes.removeAll()

    f.engine.suspend(root: f.root)  // §5 16
    #expect(f.engine.focusedID == nil)
    #expect(f.engine.restorationID == f.y.id)
    #expect(f.engine.scopeID == f.modal.id)
    #expect(f.y.log.last == "focusOut:suspend")
    f.engine.suspend(root: f.root)  // idempotent
    #expect(f.changes.count == 1)

    f.engine.resume(root: f.root)
    #expect(f.engine.focusedID == f.y.id)
    #expect(f.engine.restorationID == nil)
    #expect(f.y.log.last == "focusIn:restoration")
    f.engine.resume(root: f.root)  // idempotent
    #expect(f.changes.count == 2)
}

@Test @MainActor
func a05_detachClearsEverythingWithoutEventsAndOldRootRemountedIsFresh() {
    let f = Fixture()
    f.engine.setScope(f.modal.id, root: f.root)
    f.engine.move(.next, root: f.root)
    f.changes.removeAll()
    let logBefore = f.y.log

    f.engine.reset()  // §5 17: what the bridge does on detach
    #expect(f.engine.focusedID == nil)
    #expect(f.engine.scopeID == nil)
    #expect(f.engine.restorationID == nil)
    #expect(f.engine.snapshot == nil)
    #expect(f.changes.isEmpty)
    #expect(f.y.log == logBefore)
    #expect(f.engine.focus(f.y.id, root: f.root) == .unavailable)

    f.epoch = 2  // the same root mounted again: a new epoch, nothing inherited
    f.publish()
    #expect(f.engine.focusedID == nil)
    #expect(
        f.engine.focus(f.y.id, root: f.root)
            == .moved(FocusChange(previous: nil, next: f.y.id, reason: .request))
    )
}

@Test @MainActor
func a05_twoEnginesWithTheSameGenerationDoNotInterfere() {
    // Two hosts, two trees, both at generation 1 — identities and snapshots are per engine.
    let first = Fixture()
    let second = Fixture()
    first.engine.focus(first.a.id, root: first.root)
    #expect(second.engine.focus(first.a.id, root: second.root) == .unavailable)
    #expect(second.engine.focusedID == nil)
    second.engine.setScope(second.modal.id, root: second.root)
    #expect(first.engine.scopeID == nil)
    #expect(first.engine.focusedID == first.a.id)
    #expect(second.engine.focusedID == second.x.id)
}
