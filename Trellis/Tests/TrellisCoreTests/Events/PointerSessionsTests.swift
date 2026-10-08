import Testing

@testable import TrellisCore

// Case numbers refer to docs/validation/h01-contract.md §3.

@MainActor
private final class Recorder {
    var calls: [String] = []
}

@MainActor
private final class RecordingNode: Node {
    let name: String
    let recorder: Recorder
    var onEvent: ((Event) -> Void)?

    init(_ name: String, _ recorder: Recorder) {
        self.name = name
        self.recorder = recorder
        super.init()
    }

    override func handleEvent(_ event: Event) {
        recorder.calls.append("\(name):\(event.type)@\(Int(event.pointer?.point.x ?? -1))")
        onEvent?(event)
    }

    override func handleBubble(_ event: Event) {
        recorder.calls.append("\(name):bubble:\(event.type)")
    }
}

/// Root (0, 0, 400, 400) with `a` at (0, 0, 100, 100) and `b` at (200, 0, 100, 100).
@MainActor
private struct Host {
    let recorder = Recorder()
    let root: RecordingNode
    let a: RecordingNode
    let b: RecordingNode
    let sessions = PointerSessions()
    var snapshot: HitTestSnapshot?

    init() {
        root = RecordingNode("R", recorder)
        a = RecordingNode("A", recorder)
        b = RecordingNode("B", recorder)
        root.addSubnode(a)
        root.addSubnode(b)
        commit(epoch: 1)
    }

    mutating func commit(epoch: UInt64, aWidth: Double = 100) {
        let result = LayoutResult(
            placements: [
                LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 400, height: 400)),
                LayoutPlacement(identity: a.id, frame: LayoutFrame(width: aWidth, height: 100)),
                LayoutPlacement(
                    identity: b.id,
                    frame: LayoutFrame(origin: LayoutPoint(x: 200, y: 0), width: 100, height: 100)
                ),
            ],
            treeIdentity: root.id
        )
        #expect(root.applyLayoutResult(result))
        snapshot = HitTestSnapshot(
            root: root,
            mountEpoch: epoch,
            bounds: LayoutFrame(width: 400, height: 400)
        )
    }

    @discardableResult
    func send(_ type: EventType, x: Double, pointer: UInt64 = 1) -> PointerOutcome {
        sessions.send(
            type,
            PointerData(point: LayoutPoint(x: x, y: 50), pointerID: pointer),
            snapshot: snapshot,
            root: root
        )
    }
}

private func delivered(_ outcome: PointerOutcome) -> EventResult? {
    if case .delivered(let result) = outcome { return result }
    return nil
}

@Test
@MainActor
func test_pointerSessions_routeIsFixedAtDownAndReleasedAtUp() {
    // 1: down on A, move over B, up over B — everything goes to A; B hears nothing.
    let host = Host()

    #expect(delivered(host.send(.pointerDown, x: 50))?.reachedTarget == true)
    #expect(host.sessions.activeCount == 1)
    #expect(host.sessions.route(for: 1) == [host.root.id, host.a.id])
    #expect(delivered(host.send(.pointerMove, x: 250))?.reachedTarget == true)
    #expect(delivered(host.send(.pointerUp, x: 250))?.reachedTarget == true)

    #expect(
        host.recorder.calls == [
            "A:pointerDown@50", "R:bubble:pointerDown",
            "A:pointerMove@250", "R:bubble:pointerMove",
            "A:pointerUp@250", "R:bubble:pointerUp",
        ]
    )
    #expect(host.sessions.activeCount == 0)
    // Released exactly once: a second up finds no session.
    #expect(host.send(.pointerUp, x: 250) == .noSession)
    #expect(host.send(.pointerMove, x: 250) == .noSession)
}

@Test
@MainActor
func test_pointerSessions_downOutsideAnyNodeOrWithoutSnapshotStartsNothing() {
    var host = Host()
    #expect(host.send(.pointerDown, x: 500) == .noTarget)
    #expect(host.sessions.activeCount == 0)

    host.snapshot = nil
    #expect(host.send(.pointerDown, x: 50) == .noTarget)
    #expect(host.recorder.calls.isEmpty)
}

@Test
@MainActor
func test_pointerSessions_commitOnSameMountKeepsSession() {
    // 2/3 (resize, unrelated mutation) and 9/10 (D34): a new commit with the same epoch does
    // not touch the session; the route stays the one from the down.
    var host = Host()
    host.send(.pointerDown, x: 50)

    host.commit(epoch: 1, aWidth: 10)  // `a` no longer under x = 50 on screen
    #expect(delivered(host.send(.pointerMove, x: 50))?.reachedTarget == true)
    #expect(delivered(host.send(.pointerUp, x: 50))?.reachedTarget == true)

    #expect(host.recorder.calls.filter { $0.hasPrefix("A:pointer") }.count == 3)
    #expect(host.sessions.activeCount == 0)
}

@Test
@MainActor
func test_pointerSessions_newMountCancelsSession() {
    // A new attach of the same root: the epoch differs, the old session must not reach it.
    var host = Host()
    host.send(.pointerDown, x: 50)
    host.commit(epoch: 2)

    #expect(host.send(.pointerMove, x: 50) == .noSession)

    #expect(host.sessions.activeCount == 0)
    #expect(host.recorder.calls.contains("A:pointerCancel@50"))
    #expect(host.send(.pointerUp, x: 50) == .noSession)
}

@Test
@MainActor
func test_pointerSessions_disposingRouteNodeCancelsSessionWithoutDelivery() {
    // 4: down on A, A disposed, up — the up is not delivered, the session is gone.
    let host = Host()
    host.send(.pointerDown, x: 50)

    host.a.dispose()
    let outcome = host.send(.pointerUp, x: 50)

    #expect(delivered(outcome)?.routeBroken == true)
    #expect(delivered(outcome)?.reachedTarget == false)
    #expect(host.sessions.activeCount == 0)
    #expect(!host.recorder.calls.contains("A:pointerUp@50"))
    #expect(host.send(.pointerUp, x: 50) == .noSession)
}

@Test
@MainActor
func test_pointerSessions_handlerBreakingRouteMidDispatchCancelsSession() {
    // A move handler on the target reparents the target: that dispatch reports the break and
    // the session ends there.
    let host = Host()
    host.send(.pointerDown, x: 50)
    host.a.onEvent = { event in
        guard event.type == .pointerMove else { return }

        host.a.removeFromSupernode()
        host.b.addSubnode(host.a)
    }

    let outcome = host.send(.pointerMove, x: 60)

    #expect(delivered(outcome)?.routeBroken == true)
    #expect(host.sessions.activeCount == 0)
    #expect(host.send(.pointerUp, x: 60) == .noSession)
}

@Test
@MainActor
func test_pointerSessions_cancelAllDeliversOneCancelAndEmptiesStore() {
    // 5/6: detach / suspend cancel every session; handlers see the cancel with the last point.
    let host = Host()
    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 70)

    host.sessions.cancelAll(reason: .hostDetached, root: host.root)
    host.sessions.cancelAll(reason: .hostDetached, root: host.root)  // idempotent

    #expect(host.sessions.activeCount == 0)
    #expect(host.recorder.calls.filter { $0 == "A:pointerCancel@70" }.count == 1)
    #expect(host.send(.pointerUp, x: 70) == .noSession)
    // 6: a new session afterwards works.
    #expect(delivered(host.send(.pointerDown, x: 50))?.reachedTarget == true)
    #expect(host.sessions.activeCount == 1)
}

@Test
@MainActor
func test_pointerSessions_pointerCancelFromHostReleasesOnce() {
    let host = Host()
    host.send(.pointerDown, x: 50)

    #expect(delivered(host.send(.pointerCancel, x: 55))?.reachedTarget == true)

    #expect(host.sessions.activeCount == 0)
    #expect(host.recorder.calls.contains("A:pointerCancel@55"))
    #expect(host.send(.pointerCancel, x: 55) == .noSession)
}

@Test
@MainActor
func test_pointerSessions_pointerIDIsReusableAfterSessionEnds() {
    // 7
    let host = Host()
    host.send(.pointerDown, x: 50)
    host.send(.pointerUp, x: 50)

    #expect(delivered(host.send(.pointerDown, x: 250))?.reachedTarget == true)

    #expect(host.sessions.route(for: 1) == [host.root.id, host.b.id])
    #expect(host.recorder.calls.last == "R:bubble:pointerDown")
    #expect(host.recorder.calls.contains("B:pointerDown@250"))
}

@Test
@MainActor
func test_pointerSessions_secondPointerIsRefusedWhileOneIsActive() {
    // 8: single-touch.
    let host = Host()
    host.send(.pointerDown, x: 50, pointer: 1)

    #expect(host.send(.pointerDown, x: 250, pointer: 2) == .secondaryPointer)
    #expect(host.send(.pointerMove, x: 250, pointer: 2) == .noSession)
    #expect(host.send(.pointerUp, x: 250, pointer: 2) == .noSession)

    #expect(host.sessions.activeCount == 1)
    #expect(!host.recorder.calls.contains("B:pointerDown@250"))
    host.send(.pointerUp, x: 50, pointer: 1)
    #expect(delivered(host.send(.pointerDown, x: 250, pointer: 2))?.reachedTarget == true)
}

@Test
@MainActor
func test_pointerSessions_downWithoutPreviousUpRestartsDeterministically() {
    let host = Host()
    host.send(.pointerDown, x: 50)

    #expect(delivered(host.send(.pointerDown, x: 250))?.reachedTarget == true)

    #expect(host.sessions.activeCount == 1)
    #expect(host.sessions.route(for: 1) == [host.root.id, host.b.id])
    #expect(host.recorder.calls.contains("A:pointerCancel@50"))
}

@MainActor
private func startStaleSession(in sessions: PointerSessions) -> (Node?, Node?) {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 100, height: 100)),
            LayoutPlacement(identity: child.id, frame: LayoutFrame(width: 100, height: 100)),
        ],
        treeIdentity: root.id
    )
    guard root.applyLayoutResult(result) else { return (nil, nil) }

    let snapshot = HitTestSnapshot(
        root: root,
        mountEpoch: 1,
        bounds: LayoutFrame(width: 100, height: 100)
    )
    sessions.send(
        .pointerDown,
        PointerData(point: LayoutPoint(x: 1, y: 1), pointerID: 3),
        snapshot: snapshot,
        root: root
    )
    return (root, child)
}

@Test
@MainActor
func test_pointerSessions_retainsNoNode() async {
    let sessions = PointerSessions()
    weak var weakRoot: Node?
    weak var weakChild: Node?
    do {
        let (root, child) = startStaleSession(in: sessions)
        #expect(root != nil)
        #expect(sessions.activeCount == 1)
        weakRoot = root
        weakChild = child
    }
    for _ in 0..<200 { await Task.yield() }

    // A stale session — the tree is gone, the store still lists it — holds nothing.
    #expect(weakRoot == nil)
    #expect(weakChild == nil)
    #expect(sessions.activeCount == 1)
    sessions.cancelAll(reason: .hostDetached, root: nil)
    #expect(sessions.activeCount == 0)
}
