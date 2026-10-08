import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private func waitForBridgeCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private final class CountingNode: Node {
    var received: [EventType] = []
    override func handleEvent(_ event: Event) { received.append(event.type) }
}

private func pointer(_ x: Double, id: UInt64 = 1) -> PointerData {
    PointerData(point: LayoutPoint(x: x, y: 20), pointerID: id)
}

/// Root 400×400 with one 100×40 control at the origin.
@MainActor
private func makeHost() -> (CALayer, NodeHostBridge, Node, CountingNode) {
    let root = Node()
    let control = CountingNode()
    control.style.width = 100
    control.style.height = 40
    root.addSubnode(control)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    return (host, bridge, root, control)
}

@Test
@MainActor
func test_nodeHostBridge_pointerEventsFollowSessionAcrossCommits() async throws {
    let (host, bridge, root, control) = makeHost()
    _ = host
    #expect(bridge.send(.pointerDown, pointer(10)) == .hostInactive)  // nothing attached
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    #expect(bridge.send(.pointerDown, pointer(10)) == .noTarget)  // attached, not committed
    await waitForBridgeCommits(bridge, 1)

    guard case .delivered(let down) = bridge.send(.pointerDown, pointer(10)) else {
        Issue.record("down not delivered")
        return
    }
    #expect(down.reachedTarget)
    #expect(bridge.activePointerSessionCount == 1)

    // Resize (a new commit, same mount) — the session and its route survive (D34).
    bridge.updateBounds(LayoutFrame(width: 300, height: 300), scale: 2)
    await waitForBridgeCommits(bridge, 2)
    #expect(bridge.activePointerSessionCount == 1)
    guard case .delivered(let move) = bridge.send(.pointerMove, pointer(250)) else {
        Issue.record("move not delivered")
        return
    }
    #expect(move.reachedTarget)  // over nothing now, still routed to the control
    guard case .delivered(let up) = bridge.send(.pointerUp, pointer(250)) else {
        Issue.record("up not delivered")
        return
    }
    #expect(up.reachedTarget)
    #expect(control.received == [.pointerDown, .pointerMove, .pointerUp])
    #expect(bridge.activePointerSessionCount == 0)
}

@Test
@MainActor
func test_nodeHostBridge_suspendAndDetachCancelSessions() async throws {
    let (host, bridge, root, control) = makeHost()
    _ = host
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    await waitForBridgeCommits(bridge, 1)

    bridge.send(.pointerDown, pointer(10))
    bridge.suspend()
    #expect(bridge.activePointerSessionCount == 0)
    #expect(control.received == [.pointerDown, .pointerCancel])
    #expect(bridge.send(.pointerUp, pointer(10)) == .hostInactive)
    #expect(bridge.send(.pointerDown, pointer(10)) == .hostInactive)

    bridge.resume()
    bridge.send(.pointerDown, pointer(10))
    #expect(bridge.activePointerSessionCount == 1)
    bridge.detach()
    #expect(bridge.activePointerSessionCount == 0)
    #expect(control.received == [.pointerDown, .pointerCancel, .pointerDown, .pointerCancel])
    #expect(bridge.send(.pointerUp, pointer(10)) == .hostInactive)

    // Reattach: a fresh mount, no leftover session, new downs work after the commit.
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    await waitForBridgeCommits(bridge, 1)
    guard case .delivered(let down) = bridge.send(.pointerDown, pointer(10)) else {
        Issue.record("down not delivered after reattach")
        return
    }
    #expect(down.reachedTarget)
    #expect(bridge.activePointerSessionCount == 1)
}

@Test
@MainActor
func test_nodeHostBridge_flattenedWrappersRefusePointerInput() async throws {
    let (host, bridge, root, _) = makeHost()
    _ = host
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    await waitForBridgeCommits(bridge, 1)

    bridge.skipsLayoutOnlyWrappers = true
    #expect(bridge.send(.pointerDown, pointer(10)) == .hostInactive)
    #expect(bridge.activePointerSessionCount == 0)
}

@Test
@MainActor
func test_nodeHostBridge_replacingRootCancelsSessionOnOldTree() async throws {
    let (host, bridge, root, control) = makeHost()
    _ = host
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 400), scale: 2))
    await waitForBridgeCommits(bridge, 1)
    bridge.send(.pointerDown, pointer(10))

    let other = Node()
    #expect(bridge.attach(root: other, bounds: LayoutFrame(width: 400, height: 400), scale: 2))

    #expect(control.received == [.pointerDown, .pointerCancel])
    #expect(bridge.activePointerSessionCount == 0)
    #expect(bridge.mountEpoch == 2)
}
