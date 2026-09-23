import Foundation
import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

/// An engine that reports, from the worker thread, the moment it has produced a result — so a
/// test can cancel exactly in the window between the worker's exit and its `finish` hop to
/// the MainActor, which a real invalidation racing a fast solver lands in.
private final class SignallingEngine: LayoutEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var solved = false

    var hasSolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return solved
    }

    func solve(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy,
        context: LayoutContext
    ) throws -> LayoutResult {
        let result = try FlexboxEngine.layoutContainer(
            input: input,
            frame: frame,
            roundingPolicy: roundingPolicy,
            context: context
        )
        lock.lock()
        solved = true
        lock.unlock()
        return result
    }
}

/// Defect #20: a result that arrived after `cancel()` — the worker had already exited, the
/// cancel only bumped the generation — was dropped as stale *without* `onWorkerFinished`.
/// The coordinator relies on that callback to release its active request; without it the
/// host never flushed again until the next attach.
@Test @MainActor
func test_layoutScheduler_staleResultStillReportsWorkerFinished() async {
    let engine = SignallingEngine()
    var finished: [UInt64] = []
    var results = 0
    let scheduler = LayoutScheduler(
        hostID: 7,
        engine: engine,
        beforeSolve: { _ in },
        onResult: { _ in results += 1 },
        onWorkerFinished: { finished.append($0) }
    )
    let input = LayoutInputSnapshot(identity: NodeID(rawValue: 1), contentRevision: 1)
    scheduler.request(input: input, frame: LayoutFrame(width: 10, height: 10))

    // Spin without yielding: the worker exits on its own thread, but its `finish` hop cannot
    // run on the MainActor until this test awaits — so the cancel below lands in the window.
    let deadline = Date().addingTimeInterval(5)
    while !engine.hasSolved, Date() < deadline { usleep(50) }
    #expect(engine.hasSolved)
    scheduler.cancel()

    for _ in 0..<10_000 where finished.isEmpty { await Task.yield() }
    #expect(finished.count == 1)
    #expect(results == 0)
    #expect(scheduler.staleCount == 1)
    #expect(scheduler.activeWorkerCount == 0)

    // And the slot is really free: a new request completes.
    scheduler.request(input: input, frame: LayoutFrame(width: 20, height: 20))
    for _ in 0..<10_000 where results == 0 { await Task.yield() }
    #expect(results == 1)
    #expect(finished.count == 2)
}

/// The same race end to end through the coordinator: after a stale result the host must go
/// on committing.
@Test @MainActor
func test_coordinator_recoversAfterStaleResult() async throws {
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    let root = Node()
    let child = Node()
    child.style.width = 10
    child.style.height = 10
    child.style.flexShrink = 0
    root.addSubnode(child)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 200), scale: 1))
    for _ in 0..<10_000 where bridge.committedCount < 1 { await Task.yield() }

    var width = 10.0
    for round in 0..<400 {
        width += 1
        child.style.width = .points(width)
        for _ in 0..<(round % 4) { await Task.yield() }
    }
    for _ in 0..<20_000 where child.calculatedFrame?.width != width { await Task.yield() }
    #expect(child.calculatedFrame?.width == width)
}
