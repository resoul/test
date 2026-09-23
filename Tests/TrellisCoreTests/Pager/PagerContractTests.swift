import Testing

@testable import TrellisCore

// R13 (`implementation-plan-6.md`, P6.5, ADR 0036): pure pager contracts — the pan
// recognizer and continuing from the on-screen position when a pan grabs a settling pager.
// Bridge behaviour is covered by `PagerNodeHostTests`.

@MainActor
private func event(_ type: EventType, _ x: Double, _ y: Double) -> Event {
    Event(
        type: type,
        targetID: NodeIDAllocator.allocate(),
        payload: .pointer(PointerData(point: LayoutPoint(x: x, y: y), pointerID: 1))
    )
}

@MainActor
@Test
func test_pagerPan_horizontalBeginsWithVelocityVerticalAndVetoFail() {
    let pan = PagerPanRecognizer()
    var time = 0.0
    pan.now = { time }
    var reports: [(GestureState, Double, Double)] = []
    pan.onPan = { reports.append(($0, $1, $2)) }

    _ = pan.handle(event(.pointerDown, 200, 100))
    time = 0.02
    #expect(pan.handle(event(.pointerMove, 180, 102)) == .began)
    time = 0.05
    _ = pan.handle(event(.pointerMove, 150, 103))
    time = 0.06
    #expect(pan.handle(event(.pointerUp, 140, 103)) == .ended)
    #expect(reports.map(\.1) == [-20, -50, -60])
    #expect(abs(reports.last!.2 - -1_000) < 1)  // 60 pt in 60 ms

    pan.reset()
    _ = pan.handle(event(.pointerDown, 200, 100))
    #expect(pan.handle(event(.pointerMove, 204, 130)) == .failed)

    pan.reset()
    pan.shouldBegin = { false }
    _ = pan.handle(event(.pointerDown, 200, 100))
    #expect(pan.handle(event(.pointerMove, 170, 100)) == .failed)
}

/// Stands in for the bridge: records scroll commands and reports a presented offset.
@MainActor
private final class PresentingHost: ContainerHost {
    var presented: LayoutPoint?
    var commands: [ScrollCommand] = []
    let hostID: UInt64 = 9
    let materializationBudget = MaterializationBudget(host: 9)

    func bindContainerState<Value: Sendable & Equatable>(
        _ subject: StateSubject<Value>,
        update: @escaping @MainActor (Value) -> Void
    ) -> any ContainerBinding {
        fatalError("unused")
    }

    func adjustScrollOffset(
        of node: ScrollNode,
        by delta: LayoutPoint,
        applied: @escaping @MainActor () -> Void
    ) {}

    func scrollContainer(
        _ node: ScrollNode,
        _ command: ScrollCommand,
        completion: @escaping @MainActor (ScrollCommandOutcome) -> Void
    ) {
        commands.append(command)
    }

    func presentedScrollOffset(of node: ScrollNode) -> LayoutPoint? { presented }
}

@MainActor
private func layOut(_ node: Node, width: Double) throws {
    let input = node.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(width), height: .exact(300))
    )
    _ = node.applyLayoutResult(
        try FlexboxEngine.layoutContainer(
            input: input,
            frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: width, height: 300)
        )
    )
}

@MainActor
@Test
func test_pager_panGrabbingASettlingPagerContinuesFromThePositionOnScreen() throws {
    var style = LayoutStyle()
    style.width = 320
    style.height = 300
    let pager = PagerNode(
        tabs: ["a", "b", "c"].map { Tab(id: $0, title: $0) { Node() } },
        style: style
    )
    let host = PresentingHost()
    pager.hostDidAttach(host)
    try layOut(pager, width: 320)
    pager.hostDidCommit(ContainerCommit(generation: 1))
    var time = 0.0
    pager.pan.now = { time }

    pager.select("b")  // a timed scroll toward x = 320 is running (the fake never completes)
    #expect(pager.selection == "b")
    #expect(
        host.commands.last == .timed(LayoutPoint(x: 320, y: 0), animation: pager.settleAnimation)
    )
    // Mid-animation the page strip is on screen at x = 100: a pan continues from there.
    host.presented = LayoutPoint(x: 100, y: 0)
    _ = pager.pan.handle(event(.pointerDown, 200, 100))
    time = 0.5
    _ = pager.pan.handle(event(.pointerMove, 185, 100))
    #expect(host.commands.last == .to(LayoutPoint(x: 115, y: 0), animated: false))
    #expect(pager.progress.from == "a")
    #expect(pager.progress.settled == nil)

    // Released below half a page and slowly: back to the page it started from.
    time = 1.5
    _ = pager.pan.handle(event(.pointerUp, 185, 100))
    #expect(pager.selection == "a")
    #expect(host.commands.last == .timed(LayoutPoint(x: 0, y: 0), animation: pager.settleAnimation))
}
