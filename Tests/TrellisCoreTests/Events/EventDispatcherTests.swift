import Testing

@testable import TrellisCore

// Case numbers refer to docs/validation/h01-contract.md §2: route [R, A, A1], target A1.

@MainActor
private final class Recorder {
    var calls: [String] = []
}

@MainActor
private class RecordingNode: Node {
    let name: String
    let recorder: Recorder
    var onCapture: ((Event) -> Void)?
    var onTarget: ((Event) -> Void)?
    var onBubble: ((Event) -> Void)?

    init(_ name: String, _ recorder: Recorder) {
        self.name = name
        self.recorder = recorder
        super.init()
    }

    override func handleCapture(_ event: Event) {
        recorder.calls.append("capture:\(name)")
        #expect(event.phase == .capturing)
        onCapture?(event)
    }

    override func handleEvent(_ event: Event) {
        recorder.calls.append("target:\(name)")
        #expect(event.phase == .atTarget)
        onTarget?(event)
    }

    override func handleBubble(_ event: Event) {
        recorder.calls.append("bubble:\(name)")
        #expect(event.phase == .bubbling)
        onBubble?(event)
    }
}

@MainActor
private struct Fixture {
    let recorder = Recorder()
    let r: RecordingNode
    let a: RecordingNode
    let a1: RecordingNode
    let b: RecordingNode
    let route: [NodeID]

    init() {
        r = RecordingNode("R", recorder)
        a = RecordingNode("A", recorder)
        a1 = RecordingNode("A1", recorder)
        b = RecordingNode("B", recorder)
        r.addSubnode(a)
        a.addSubnode(a1)
        r.addSubnode(b)
        route = [r.id, a.id, a1.id]
    }

    func event(_ type: EventType = .pointerDown) -> Event {
        Event(
            type: type,
            targetID: a1.id,
            payload: .pointer(PointerData(point: LayoutPoint(x: 1, y: 1), pointerID: 1))
        )
    }
}

@Test
@MainActor
func test_eventDispatcher_runsCaptureTargetBubbleInExactOrder() {
    let fixture = Fixture()
    let event = fixture.event()

    let result = EventDispatcher().dispatch(event, route: fixture.route, root: fixture.r)

    // 1
    #expect(
        fixture.recorder.calls == ["capture:R", "capture:A", "target:A1", "bubble:A", "bubble:R"]
    )
    #expect(
        result
            == EventResult(
                propagationStopped: false,
                defaultPrevented: false,
                routeBroken: false,
                reachedTarget: true
            )
    )
    #expect(event.pointer?.pointerID == 1)
    #expect(event.targetID == fixture.a1.id)
}

@Test
@MainActor
func test_eventDispatcher_stopPropagationInEachPhase() {
    // 2: capture on A — A1 gets neither capture nor target; no bubble.
    let capture = Fixture()
    capture.a.onCapture = { $0.stopPropagation() }
    let captureResult = EventDispatcher().dispatch(
        capture.event(),
        route: capture.route,
        root: capture.r
    )
    #expect(capture.recorder.calls == ["capture:R", "capture:A"])
    #expect(captureResult.propagationStopped)
    #expect(!captureResult.reachedTarget)

    // 3: at target — capture already ran in full; no bubble.
    let target = Fixture()
    target.a1.onTarget = { $0.stopPropagation() }
    let targetResult = EventDispatcher().dispatch(
        target.event(),
        route: target.route,
        root: target.r
    )
    #expect(target.recorder.calls == ["capture:R", "capture:A", "target:A1"])
    #expect(targetResult.propagationStopped)
    #expect(targetResult.reachedTarget)

    // 4: bubble on A — R does not bubble.
    let bubble = Fixture()
    bubble.a.onBubble = { $0.stopPropagation() }
    _ = EventDispatcher().dispatch(bubble.event(), route: bubble.route, root: bubble.r)
    #expect(bubble.recorder.calls == ["capture:R", "capture:A", "target:A1", "bubble:A"])
}

@Test
@MainActor
func test_eventDispatcher_preventDefaultDoesNotStopPropagation() {
    // 5 (dispatcher half): every phase still runs; only the flag is reported.
    let fixture = Fixture()
    fixture.r.onCapture = { $0.preventDefault() }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(fixture.recorder.calls.count == 5)
    #expect(result.defaultPrevented)
    #expect(!result.propagationStopped)
    #expect(!result.routeBroken)
}

@Test
@MainActor
func test_eventDispatcher_disposingTargetDuringCaptureEndsDelivery() {
    // 6
    let fixture = Fixture()
    fixture.a.onCapture = { _ in fixture.a1.dispose() }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(fixture.recorder.calls == ["capture:R", "capture:A"])
    #expect(result.routeBroken)
    #expect(!result.reachedTarget)
    #expect(!result.propagationStopped)
}

@Test
@MainActor
func test_eventDispatcher_removingAncestorAtTargetEndsBubble() {
    // 7: the target detaches A — bubble on A is skipped, and so is R.
    let fixture = Fixture()
    fixture.a1.onTarget = { _ in fixture.a.removeFromSupernode() }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(fixture.recorder.calls == ["capture:R", "capture:A", "target:A1"])
    #expect(result.routeBroken)
    #expect(result.reachedTarget)
}

@Test
@MainActor
func test_eventDispatcher_reparentingTargetAtTargetEndsBubble() {
    // 8: A1 moves under B — the old route no longer describes where it is.
    let fixture = Fixture()
    fixture.a1.onTarget = { _ in
        fixture.a1.removeFromSupernode()
        fixture.b.addSubnode(fixture.a1)
    }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(fixture.recorder.calls == ["capture:R", "capture:A", "target:A1"])
    #expect(result.routeBroken)
    #expect(fixture.a1.supernode === fixture.b)
}

@Test
@MainActor
func test_eventDispatcher_removingAndReaddingUnderSameParentKeepsRoute() {
    // A handler that takes a node out and puts it back where it was has not broken the route.
    let fixture = Fixture()
    fixture.a1.onTarget = { _ in
        fixture.a1.removeFromSupernode()
        fixture.a.addSubnode(fixture.a1)
    }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(fixture.recorder.calls.count == 5)
    #expect(!result.routeBroken)
}

@Test
@MainActor
func test_eventDispatcher_nestedDispatchHasItsOwnRoute() {
    // 9: A's capture dispatches a second event to B; the outer dispatch continues unaffected.
    let fixture = Fixture()
    let inner = Event(
        type: .pointerMove,
        targetID: fixture.b.id,
        payload: .pointer(PointerData(point: LayoutPoint(x: 2, y: 2), pointerID: 2))
    )
    fixture.a.onCapture = { outer in
        let result = EventDispatcher().dispatch(
            inner,
            route: [fixture.r.id, fixture.b.id],
            root: fixture.r
        )
        #expect(result.reachedTarget)
        #expect(outer.phase == .capturing)
    }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(
        fixture.recorder.calls == [
            "capture:R", "capture:A",
            "capture:R", "target:B", "bubble:R",
            "target:A1", "bubble:A", "bubble:R",
        ]
    )
    #expect(!result.routeBroken)
    #expect(inner.phase == .bubbling)
}

@Test
@MainActor
func test_eventDispatcher_unresolvableRouteDeliversNothing() {
    // 10: the target is no longer in the mounted tree — or the route is not this root's.
    let fixture = Fixture()
    fixture.a1.removeFromSupernode()
    let gone = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)
    #expect(fixture.recorder.calls.isEmpty)
    #expect(
        gone
            == EventResult(
                propagationStopped: false,
                defaultPrevented: false,
                routeBroken: true,
                reachedTarget: false
            )
    )

    let foreign = EventDispatcher().dispatch(
        fixture.event(),
        route: [fixture.a.id],
        root: fixture.r
    )
    #expect(foreign.routeBroken)
    let empty = EventDispatcher().dispatch(fixture.event(), route: [], root: fixture.r)
    #expect(empty.routeBroken)
    #expect(fixture.recorder.calls.isEmpty)

    fixture.r.dispose()
    let disposed = EventDispatcher().dispatch(
        fixture.event(),
        route: [fixture.r.id],
        root: fixture.r
    )
    #expect(disposed.routeBroken)
    #expect(fixture.recorder.calls.isEmpty)
}

@Test
@MainActor
func test_eventDispatcher_handlerMayDisposeWholeTreeSynchronously() {
    // The activation-style mutation: the target tears everything down. No crash, no delivery
    // after, route reported broken.
    let fixture = Fixture()
    fixture.a1.onTarget = { _ in fixture.r.dispose() }

    let result = EventDispatcher().dispatch(fixture.event(), route: fixture.route, root: fixture.r)

    #expect(fixture.recorder.calls == ["capture:R", "capture:A", "target:A1"])
    #expect(result.routeBroken)
    #expect(fixture.r.isDisposed)
}

@Test
@MainActor
func test_hitTestSnapshot_routeIsRootFirst() throws {
    let fixture = Fixture()
    let frames = [fixture.r, fixture.a, fixture.a1, fixture.b].map {
        LayoutPlacement(identity: $0.id, frame: LayoutFrame(width: 10, height: 10))
    }
    #expect(
        fixture.r.applyLayoutResult(LayoutResult(placements: frames, treeIdentity: fixture.r.id))
    )
    let snapshot = try #require(
        HitTestSnapshot(root: fixture.r, mountEpoch: 1, bounds: LayoutFrame(width: 10, height: 10))
    )

    #expect(snapshot.route(to: fixture.a1.id) == [fixture.r.id, fixture.a.id, fixture.a1.id])
    #expect(snapshot.route(to: fixture.r.id) == [fixture.r.id])
    #expect(snapshot.route(to: Node().id) == nil)
}
