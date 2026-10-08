import Testing

@testable import TrellisCore

// Case numbers refer to docs/validation/h01-contract.md §5. Root (0, 0, 400, 400) has one
// `ControlNode` at (0, 0, 100, 40); a plain decorative child sits at (10, 10, 20, 20) inside it.

@MainActor
private struct Host {
    let root = Node()
    let control = ControlNode()
    let decorative = Node()
    var snapshot: HitTestSnapshot!

    init() {
        root.addSubnode(control)
        control.addSubnode(decorative)
        commit(epoch: 1)
    }

    mutating func commit(
        epoch: UInt64,
        controlFrame: LayoutFrame = LayoutFrame(width: 100, height: 40)
    ) {
        let result = LayoutResult(
            placements: [
                LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 400, height: 400)),
                LayoutPlacement(identity: control.id, frame: controlFrame),
                LayoutPlacement(
                    identity: decorative.id,
                    frame: LayoutFrame(
                        origin: LayoutPoint(
                            x: controlFrame.origin.x + 10,
                            y: controlFrame.origin.y + 10
                        ),
                        width: 20,
                        height: 20
                    )
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
}

@MainActor
private final class Driver {
    let sessions = PointerSessions()

    @discardableResult
    func send(_ type: EventType, _ host: Host, x: Double, y: Double = 20, pointer: UInt64 = 1)
        -> PointerOutcome
    {
        sessions.send(
            type,
            PointerData(point: LayoutPoint(x: x, y: y), pointerID: pointer),
            snapshot: host.snapshot,
            root: host.root
        )
    }
}

@Test
@MainActor
func test_controlNode_downInsideSetsPressedAndInvalidates() {
    // 1
    let host = Host()
    let driver = Driver()
    // Pending invalidation is tracked at the current tree root (`host.root`), not on the node
    // whose appearance changed — the same path `appearance`'s own `didSet` uses. Drain whatever
    // building the fixture itself left pending before observing the press.
    host.root.consumePendingInvalidation()
    #expect(host.root.consumePendingInvalidation() == nil)

    driver.send(.pointerDown, host, x: 50)

    #expect(host.control.isPressed)
    let pending = host.root.consumePendingInvalidation()
    #expect(pending?.origin === host.control)
    #expect(pending?.reasons == .appearance)
}

@Test
@MainActor
func test_controlNode_moveOutsideClearsPressedMoveBackRestoresIt() {
    // 2
    let host = Host()
    let driver = Driver()
    driver.send(.pointerDown, host, x: 50)
    #expect(host.control.isPressed)

    driver.send(.pointerMove, host, x: 250)
    #expect(!host.control.isPressed)

    driver.send(.pointerMove, host, x: 50)
    #expect(host.control.isPressed)
}

@Test
@MainActor
func test_controlNode_upInsideActivatesExactlyOnceAndClearsPressed() {
    // 3
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50)
    driver.send(.pointerUp, host, x: 50)

    #expect(activations == 1)
    #expect(!host.control.isPressed)
    driver.send(.pointerUp, host, x: 50)  // no active session: no crash, no second activation
    #expect(activations == 1)
}

@Test
@MainActor
func test_controlNode_upOutsideDoesNotActivate() {
    // 4
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50)
    driver.send(.pointerMove, host, x: 250)
    driver.send(.pointerUp, host, x: 250)

    #expect(activations == 0)
    #expect(!host.control.isPressed)
}

@Test
@MainActor
func test_controlNode_cancelDoesNotActivateAndClearsPressed() {
    // 5: pointerCancel from the host.
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50)
    driver.send(.pointerCancel, host, x: 50)

    #expect(activations == 0)
    #expect(!host.control.isPressed)
}

@Test
@MainActor
func test_controlNode_hostCancelAllDoesNotActivateAndClearsPressed() {
    // 5: detach/suspend-style cancellation.
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50)
    driver.sessions.cancelAll(reason: .hostDetached, root: host.root)

    #expect(activations == 0)
    #expect(!host.control.isPressed)
}

@Test
@MainActor
func test_controlNode_disposeDuringPressDoesNotActivate() {
    // 5
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50)
    host.control.dispose()
    driver.send(.pointerUp, host, x: 50)

    #expect(activations == 0)
}

@Test
@MainActor
func test_controlNode_arbitrationLossToPersDoesNotActivateAndClearsPressed() {
    // 5: a PanRecognizer on the root wins arbitration (registered before the control's tap in
    // the arena's order — target first, then ancestors, so the root's recognizer only wins by
    // out-threshold movement; the control's own tap has already failed by then anyway, this
    // exercises the same "arbitration loss" path from the control's perspective).
    let host = Host()
    let pan = PanRecognizer()
    host.root.addGestureRecognizer(pan)
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50)
    driver.send(.pointerMove, host, x: 65)  // past the 10 pt pan threshold: pan begins, tap resets
    driver.send(.pointerUp, host, x: 65)

    #expect(activations == 0)
    #expect(!host.control.isPressed)
}

@Test
@MainActor
func test_controlNode_activationMayDisposeControlWithoutRepeatedDeliveryOrCrash() {
    // 6
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { [weak control = host.control] in
        activations += 1
        control?.dispose()
    }

    driver.send(.pointerDown, host, x: 50)
    driver.send(.pointerUp, host, x: 50)

    #expect(activations == 1)
    #expect(host.control.isDisposed)
    #expect(driver.sessions.activeCount == 0)
}

@Test
@MainActor
func test_controlNode_activationMayDetachTheWholeTreeWithoutRepeatedDeliveryOrCrash() {
    // 6
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { [sessions = driver.sessions, root = host.root] in
        activations += 1
        sessions.cancelAll(reason: .hostDetached, root: root)
    }

    driver.send(.pointerDown, host, x: 50)
    driver.send(.pointerUp, host, x: 50)

    #expect(activations == 1)
    #expect(driver.sessions.activeCount == 0)
}

@Test
@MainActor
func test_controlNode_decorativeChildHitStillRoutesActivationToControl() {
    // 7: down and up land on the decorative child (10, 10, 20, 20) inside the control.
    let host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    #expect(host.snapshot.hitTest(LayoutPoint(x: 15, y: 15)) == host.decorative.id)
    driver.send(.pointerDown, host, x: 15, y: 15)
    #expect(driver.sessions.route(for: 1) == [host.root.id, host.control.id, host.decorative.id])
    #expect(host.control.isPressed)
    driver.send(.pointerUp, host, x: 15, y: 15)

    #expect(activations == 1)
    #expect(!host.control.isPressed)
}

@Test
@MainActor
func test_controlNode_commitBetweenDownAndUpUsesLatestGeometry() {
    // D22/D34: the control moves between down and up; up-inside is judged by the commit in
    // effect at up, not the one at down.
    var host = Host()
    let driver = Driver()
    var activations = 0
    host.control.activation = { activations += 1 }

    driver.send(.pointerDown, host, x: 50, y: 20)
    host.commit(
        epoch: 1,
        controlFrame: LayoutFrame(origin: LayoutPoint(x: 10, y: 200), width: 100, height: 40)
    )

    // Same host point as down, but the control moved away from under it in the new commit.
    driver.send(.pointerUp, host, x: 50, y: 20)
    #expect(activations == 0)

    // A fresh session, up now landing where the control moved to.
    driver.send(.pointerDown, host, x: 50, y: 220)
    driver.send(.pointerUp, host, x: 50, y: 220)
    #expect(activations == 1)
}

@Test
@MainActor
func test_controlNode_moveTrackingFollowsLatestCommitTooD34() {
    var host = Host()
    let driver = Driver()

    driver.send(.pointerDown, host, x: 50, y: 20)
    #expect(host.control.isPressed)

    host.commit(
        epoch: 1,
        controlFrame: LayoutFrame(origin: LayoutPoint(x: 10, y: 200), width: 100, height: 40)
    )
    // Same host point, but the control is no longer there in the latest commit.
    driver.send(.pointerMove, host, x: 50, y: 20)
    #expect(!host.control.isPressed)

    driver.send(.pointerMove, host, x: 50, y: 220)
    #expect(host.control.isPressed)
}
