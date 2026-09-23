import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private final class PointerStressControl: ControlNode {
    var activations = 0
    var events: [EventType] = []
    var panCancellations = 0
    var disposeOn: EventType?

    init() {
        super.init()
        activation = { [weak self] in self?.activations += 1 }
    }

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        events.append(event.type)
        if event.type == disposeOn { dispose() }
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) { self.value = value }
}

@MainActor
private func waitForPointerCommit(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<50_000 where bridge.committedCount < count { await Task.yield() }
    #expect(bridge.committedCount >= count)
}

@MainActor
private func pointer(at frame: LayoutFrame, id: UInt64, offset: Double = 0) -> PointerData {
    PointerData(
        point: LayoutPoint(
            x: frame.origin.x + frame.width / 2 + offset,
            y: frame.origin.y + frame.height / 2
        ),
        pointerID: id
    )
}

@MainActor
private func makePointerStressTree(count: Int) -> (Node, [PointerStressControl]) {
    let root = Node()
    root.style.flexDirection = .column
    let controls = (0..<count).map { _ in
        let control = PointerStressControl()
        control.style.width = 120
        control.style.height = 20
        root.addSubnode(control)
        return control
    }
    return (root, controls)
}

@Test
@MainActor
func test_pointerLoad_manyControlsAndSequentialPointerIDsLeaveNoSessionsOrArenas() async {
    let controlCount = 128
    let rounds = 8
    let (root, controls) = makePointerStressTree(count: controlCount)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 400, height: Double(controlCount * 20)),
            scale: 2
        )
    )
    await waitForPointerCommit(bridge, 1)

    var pointerID: UInt64 = 1
    for _ in 0..<rounds {
        for control in controls {
            guard let frame = control.calculatedFrame else {
                Issue.record("control has no committed frame")
                return
            }

            let data = pointer(at: frame, id: pointerID)
            guard case .delivered = bridge.send(.pointerDown, data) else {
                Issue.record("pointer down was not delivered for id \(pointerID)")
                return
            }
            guard case .delivered = bridge.send(.pointerUp, data) else {
                Issue.record("pointer up was not delivered for id \(pointerID)")
                return
            }
            pointerID += 1
        }
    }

    #expect(controls.allSatisfy { $0.activations == rounds })
    #expect(controls.allSatisfy { $0.events.count == rounds * 2 })
    #expect(bridge.activePointerSessionCount == 0)
    #expect(bridge.activeGestureArenaCount == 0)

    bridge.detach()
    #expect(bridge.materializedLayerCount == 0)
    #expect(bridge.activePointerSessionCount == 0)
    #expect(bridge.activeGestureArenaCount == 0)
}

@Test
@MainActor
func test_pointerLifecycle_repeatedActiveAttachDetachReleasesBridgeRootsAndControls() async {
    weak var weakBridge: NodeHostBridge?
    weak var weakHost: CALayer?
    var weakRoots: [WeakReference<Node>] = []
    var weakControls: [WeakReference<PointerStressControl>] = []

    do {
        let host = CALayer()
        let bridge = NodeHostBridge(hostLayer: host)
        weakHost = host
        weakBridge = bridge

        for round in 0..<24 {
            let (root, controls) = makePointerStressTree(count: 32)
            let control = controls[round % controls.count]
            weakRoots.append(WeakReference(root))
            weakControls.append(WeakReference(control))
            #expect(
                bridge.attach(
                    root: root,
                    bounds: LayoutFrame(width: 400, height: 640),
                    scale: 2
                )
            )
            await waitForPointerCommit(bridge, 1)
            guard let frame = control.calculatedFrame else {
                Issue.record("control has no committed frame")
                return
            }

            let pan = PanRecognizer()
            pan.onPan = { [weak control] gesture in
                if gesture.state == .cancelled { control?.panCancellations += 1 }
            }
            control.addGestureRecognizer(pan)
            let active = pointer(at: frame, id: UInt64(round + 1))
            bridge.send(.pointerDown, active)
            bridge.send(.pointerMove, pointer(at: frame, id: active.pointerID, offset: 12))
            #expect(bridge.activePointerSessionCount == 1)
            #expect(bridge.activeGestureArenaCount == 1)

            switch round % 3 {
            case 0:
                bridge.detach()
            case 1:
                bridge.suspend()
                // A stale release after cancellation cannot reach the control after resume.
                let eventCount = control.events.count
                bridge.resume()
                // `resume` can schedule layout, but it must not revive the old pointer session.
                // The old mount and snapshot are still valid; only the cancelled ID is stale.
                // The outcome is therefore `.noSession`, not `.hostInactive`.
                #expect(bridge.send(.pointerUp, active) == .noSession)
                #expect(control.events.count == eventCount)
                bridge.detach()
            default:
                let commits = bridge.committedCount
                bridge.updateBounds(LayoutFrame(width: 420, height: 660), scale: 2)
                await waitForPointerCommit(bridge, commits + 1)
                // Resize keeps the active route (D31/D34); teardown then cancels it once.
                #expect(bridge.activePointerSessionCount == 1)
                bridge.detach()
            }

            // The active pan sees one cancellation and no activation; both stores are empty.
            #expect(control.panCancellations == 1)
            #expect(control.activations == 0)
            #expect(!control.isPressed)
            #expect(bridge.activePointerSessionCount == 0)
            #expect(bridge.activeGestureArenaCount == 0)
            #expect(bridge.materializedLayerCount == 0)
            #expect(host.sublayers?.isEmpty ?? true)
            let eventCount = control.events.count
            #expect(bridge.send(.pointerMove, active) == .hostInactive)
            #expect(bridge.send(.pointerUp, active) == .hostInactive)
            #expect(control.events.count == eventCount)
        }

        bridge.cancelAllBindings()
        #expect(bridge.bindingCount == 0)
    }

    for _ in 0..<200 { await Task.yield() }
    #expect(weakRoots.allSatisfy { $0.value == nil })
    #expect(weakControls.allSatisfy { $0.value == nil })
    #expect(weakBridge == nil)
    #expect(weakHost == nil)
}

@Test
@MainActor
func test_pointerLifecycle_disposeFromEveryPointerPhaseCancelsWithoutLaterCallbacks() async {
    let phases: [EventType] = [.pointerDown, .pointerMove, .pointerUp, .pointerCancel]

    for (index, phase) in phases.enumerated() {
        let root = Node()
        let control = PointerStressControl()
        control.style.width = 100
        control.style.height = 40
        control.disposeOn = phase
        root.addSubnode(control)
        let host = CALayer()
        let bridge = NodeHostBridge(hostLayer: host)
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 100), scale: 2))
        await waitForPointerCommit(bridge, 1)
        guard let frame = control.calculatedFrame else {
            Issue.record("control has no committed frame")
            return
        }

        let data = pointer(at: frame, id: UInt64(index + 1))
        bridge.send(.pointerDown, data)
        if phase != .pointerDown {
            bridge.send(phase, data)
        }

        #expect(control.isDisposed)
        #expect(control.activations == 0)
        #expect(bridge.activePointerSessionCount == 0)
        #expect(bridge.activeGestureArenaCount == 0)
        let eventCount = control.events.count
        #expect(bridge.send(.pointerMove, data) == .noSession)
        #expect(bridge.send(.pointerUp, data) == .noSession)
        #expect(control.events.count == eventCount)

        bridge.detach()
        #expect(bridge.materializedLayerCount == 0)
    }
}
