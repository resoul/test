import Testing

@testable import TrellisCore

// Case numbers refer to docs/validation/h01-contract.md §4. Thresholds: tap slop 10 pt, pan
// threshold 10 pt (D31).

@MainActor
private final class Log {
    var lines: [String] = []
}

@MainActor
private final class PreventingNode: Node {
    var preventsDefault = false
    override func handleEvent(_ event: Event) {
        if preventsDefault { event.preventDefault() }
    }
}

/// Root (0, 0, 400, 400) > `a` (0, 0, 200, 200) > `a1` (0, 0, 100, 100); sibling `b` at
/// (200, 0, 100, 100). Sessions run through `PointerSessions`, so the arena is built the way
/// production builds it: target's recognizers first, then ancestors'.
@MainActor
private struct Host {
    let log = Log()
    let root = PreventingNode()
    let a = PreventingNode()
    let a1 = PreventingNode()
    let b = PreventingNode()
    let sessions = PointerSessions()
    let snapshot: HitTestSnapshot

    init() {
        root.addSubnode(a)
        a.addSubnode(a1)
        root.addSubnode(b)
        let result = LayoutResult(
            placements: [
                LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 400, height: 400)),
                LayoutPlacement(identity: a.id, frame: LayoutFrame(width: 200, height: 200)),
                LayoutPlacement(identity: a1.id, frame: LayoutFrame(width: 100, height: 100)),
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
            mountEpoch: 1,
            bounds: LayoutFrame(width: 400, height: 400)
        )!
    }

    @discardableResult
    func tap(_ name: String, on node: Node) -> TapRecognizer {
        let tap = TapRecognizer()
        tap.onTap = { [log] point in log.lines.append("\(name):tap@\(Int(point.x))") }
        node.addGestureRecognizer(tap)
        return tap
    }

    @discardableResult
    func pan(_ name: String, on node: Node) -> PanRecognizer {
        let pan = PanRecognizer()
        pan.onPan = { [log] gesture in
            log.lines.append(
                "\(name):\(gesture.state) t=\(Int(gesture.translation.x)) d=\(Int(gesture.delta.x))"
            )
        }
        node.addGestureRecognizer(pan)
        return pan
    }

    @discardableResult
    func send(_ type: EventType, x: Double, y: Double = 50, pointer: UInt64 = 1) -> PointerOutcome {
        sessions.send(
            type,
            PointerData(point: LayoutPoint(x: x, y: y), pointerID: pointer),
            snapshot: snapshot,
            root: root
        )
    }
}

@Test
@MainActor
func test_gestures_tapWithoutMovementEndsAndPanResets() {
    // 1
    let host = Host()
    let tap = host.tap("tap", on: host.a1)
    let pan = host.pan("pan", on: host.a1)

    host.send(.pointerDown, x: 50)
    host.send(.pointerUp, x: 50)

    #expect(host.log.lines == ["tap:tap@50"])
    #expect(tap.state == .possible)  // reset for the next session
    #expect(pan.state == .possible)
    #expect(host.sessions.activeCount == 0)
}

@Test
@MainActor
func test_gestures_tapSlopBelowAtAndAboveThreshold() {
    // 2, 3, 4: 9 → tap; exactly 10 → tap, no pan; 11 → pan begins, tap fails.
    let host = Host()
    host.tap("tap", on: host.a1)
    let pan = host.pan("pan", on: host.a1)

    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 59)
    host.send(.pointerUp, x: 59)
    #expect(host.log.lines == ["tap:tap@59"])

    host.log.lines = []
    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 60)
    #expect(pan.state == .possible)
    host.send(.pointerUp, x: 60)
    #expect(host.log.lines == ["tap:tap@60"])

    host.log.lines = []
    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 61)
    #expect(pan.state == .began)
    #expect(host.log.lines == ["pan:began t=11 d=11"])
    host.send(.pointerUp, x: 61)
    #expect(host.log.lines == ["pan:began t=11 d=11", "pan:ended t=11 d=0"])
    #expect(!host.log.lines.contains { $0.hasPrefix("tap") })
}

@Test
@MainActor
func test_gestures_panReportsTranslationAndDeltaThenEnds() {
    // 5
    let host = Host()
    host.pan("pan", on: host.a1)

    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 61)
    host.send(.pointerMove, x: 70)
    host.send(.pointerUp, x: 70)

    #expect(
        host.log.lines == ["pan:began t=11 d=11", "pan:changed t=20 d=9", "pan:ended t=20 d=0"]
    )
}

@Test
@MainActor
func test_gestures_targetRecognizerBeatsAncestorRecognizer() {
    // 6: taps on A1 (target) and A (ancestor) — A1 wins; A is reset, hears nothing.
    let host = Host()
    let inner = host.tap("inner", on: host.a1)
    let outer = host.tap("outer", on: host.a)

    host.send(.pointerDown, x: 50)
    host.send(.pointerUp, x: 50)

    #expect(host.log.lines == ["inner:tap@50"])
    #expect(inner.state == .possible)
    #expect(outer.state == .possible)

    // Down on A itself (outside A1): only the outer tap is on the route.
    host.log.lines = []
    host.send(.pointerDown, x: 150)
    host.send(.pointerUp, x: 150)
    #expect(host.log.lines == ["outer:tap@150"])
}

@Test
@MainActor
func test_gestures_registrationOrderBreaksTiesOnOneNode() {
    // 7
    let host = Host()
    host.tap("first", on: host.a1)
    host.tap("second", on: host.a1)

    host.send(.pointerDown, x: 50)
    host.send(.pointerUp, x: 50)

    #expect(host.log.lines == ["first:tap@50"])
}

@Test
@MainActor
func test_gestures_oneStepEndedLeavesNoWinnerBehind() {
    // 8 (G06): Tap goes .possible → .ended on the up; the arena that closes on that event
    // must not keep it as a winner.
    let tap = TapRecognizer()
    let pan = PanRecognizer()
    let arena = GestureArena(recognizers: [tap, pan])
    let down = Event(
        type: .pointerDown,
        targetID: NodeIDAllocator.allocate(),
        payload: .pointer(PointerData(point: LayoutPoint(x: 1, y: 1), pointerID: 1))
    )
    let up = Event(
        type: .pointerUp,
        targetID: down.targetID,
        payload: .pointer(PointerData(point: LayoutPoint(x: 1, y: 1), pointerID: 1))
    )

    #expect(arena.handle(down) == .ignored)
    #expect(arena.winner == nil)
    #expect(arena.handle(up) == .ended)

    #expect(arena.winner == nil)
    #expect(arena.isClosed)
    #expect(tap.state == .possible)
    #expect(pan.state == .possible)
    #expect(arena.handle(up) == .ignored)  // closed arena ignores everything
}

@Test
@MainActor
func test_gestures_pointerCancelCancelsActivePanOnceAndEmptiesArena() {
    // 9
    let host = Host()
    let pan = host.pan("pan", on: host.a1)
    let tap = host.tap("tap", on: host.a1)

    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 70)
    host.send(.pointerCancel, x: 70)

    #expect(host.log.lines == ["pan:began t=20 d=20", "pan:cancelled t=20 d=0"])
    #expect(pan.state == .possible)
    #expect(tap.state == .possible)
    #expect(host.sessions.activeCount == 0)
    // Host lifecycle cancel of an active pan: one `.cancelled`, directly through the arena.
    host.log.lines = []
    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 70)
    host.sessions.cancelAll(reason: .hostDetached, root: host.root)
    #expect(host.log.lines == ["pan:began t=20 d=20", "pan:cancelled t=20 d=0"])
    #expect(pan.state == .possible)
}

@Test
@MainActor
func test_gestures_brokenRouteResetsRecognizersDirectlyWithoutActivation() {
    // D21 via the arena: the target is disposed mid-pan by an ancestor's handler; the cancel
    // cannot travel the tree, the pan still gets its `.cancelled`, nothing activates.
    let host = Host()
    host.pan("pan", on: host.a1)
    host.tap("tap", on: host.a1)
    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 70)

    host.a1.dispose()  // also drops the node's recognizers; the arena still holds them
    host.send(.pointerUp, x: 70)

    #expect(host.log.lines == ["pan:began t=20 d=20", "pan:cancelled t=20 d=0"])
    #expect(host.sessions.activeCount == 0)
    #expect(host.a1.gestureRecognizers.isEmpty)
}

@Test
@MainActor
func test_gestures_sequentialSessionsDoNotMixWinners() {
    // 10: a pan session followed by a tap session on the same recognizers.
    let host = Host()
    let tap = host.tap("tap", on: host.a1)
    let pan = host.pan("pan", on: host.a1)

    host.send(.pointerDown, x: 50)
    host.send(.pointerMove, x: 80)
    host.send(.pointerUp, x: 80)
    host.send(.pointerDown, x: 50, pointer: 2)
    host.send(.pointerUp, x: 50, pointer: 2)

    #expect(host.log.lines == ["pan:began t=30 d=30", "pan:ended t=30 d=0", "tap:tap@50"])
    #expect(tap.state == .possible)
    #expect(pan.state == .possible)
}

@Test
@MainActor
func test_gestures_preventDefaultKeepsRecognizersOut() {
    // 11: preventDefault on the down — no recognizer sees the session, no activation; the
    // recognizers are clean for the next session.
    let host = Host()
    let tap = host.tap("tap", on: host.a1)
    host.a1.preventsDefault = true

    host.send(.pointerDown, x: 50)
    host.send(.pointerUp, x: 50)
    #expect(host.log.lines.isEmpty)

    host.a1.preventsDefault = false
    host.send(.pointerDown, x: 50)
    host.send(.pointerUp, x: 50)
    #expect(host.log.lines == ["tap:tap@50"])
    #expect(tap.state == .possible)

    // preventDefault on the up only: the down reached the tap, the up did not — no activation,
    // and still clean afterwards.
    host.log.lines = []
    host.send(.pointerDown, x: 50)
    host.a1.preventsDefault = true
    host.send(.pointerUp, x: 50)
    #expect(host.log.lines.isEmpty)
    #expect(tap.state == .possible)
}

@Test
@MainActor
func test_gestures_recognizerRegistrationOnNode() {
    let node = Node()
    let tap = TapRecognizer()
    let pan = PanRecognizer()
    node.addGestureRecognizer(tap)
    node.addGestureRecognizer(pan)
    node.addGestureRecognizer(tap)  // no duplicates
    #expect(node.gestureRecognizers.count == 2)
    #expect(node.gestureRecognizers[0] === tap)

    node.removeGestureRecognizer(tap)
    #expect(node.gestureRecognizers.count == 1)
    #expect(node.gestureRecognizers[0] === pan)

    node.dispose()
    #expect(node.gestureRecognizers.isEmpty)
    node.addGestureRecognizer(tap)
    #expect(node.gestureRecognizers.isEmpty)  // disposed: ignored
}

@Test
@MainActor
func test_gestures_configurationNormalizesInvalidThresholds() {
    let configuration = GestureConfiguration(tapSlop: -1, panThreshold: .nan)
    #expect(configuration.tapSlop == 10)
    #expect(configuration.panThreshold == 10)
    #expect(GestureConfiguration(tapSlop: 3, panThreshold: 4).panThreshold == 4)
}
