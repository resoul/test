import Testing

@testable import TrellisCore

@MainActor
private final class ResultRecorder {
    var revisions: [UInt64] = []

    func record(_ result: LayoutResult) {
        revisions.append(result.contentRevision)
    }
}

private actor WorkerGate {
    private var entries: [UInt64] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func waitBeforeSolve(generation: UInt64) async {
        entries.append(generation)
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for (count, continuation) in waitingForEntry {
            if entries.count >= count {
                continuation.resume()
            } else {
                entryWaiters.append((count, continuation))
            }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForEntry(_ count: Int) async {
        guard entries.count < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }

        waiters.removeFirst().resume()
    }
}

private struct FailingEngine: LayoutEngine {
    enum Failure: Error { case expected }

    func solve(
        input _: LayoutInputSnapshot,
        frame _: LayoutFrame,
        roundingPolicy _: PixelRoundingPolicy,
        context _: LayoutContext
    ) throws -> LayoutResult {
        throw Failure.expected
    }
}

private func schedulerInput(_ revision: UInt64) -> LayoutInputSnapshot {
    LayoutInputSnapshot(identity: flexID(1), contentRevision: revision)
}

@Test
@MainActor
func test_layoutScheduler_keepsOneWorkerAndReplacesPendingWithLatestRequest() async {
    let gate = WorkerGate()
    let recorder = ResultRecorder()
    let scheduler = LayoutScheduler(
        hostID: 7,
        engine: FlexboxLayoutEngine(),
        beforeSolve: { generation in await gate.waitBeforeSolve(generation: generation) },
        onResult: { recorder.record($0) }
    )
    let frame = LayoutFrame(width: 10, height: 10)

    scheduler.request(input: schedulerInput(1), frame: frame)
    await gate.waitForEntry(1)
    #expect(scheduler.activeWorkerCount == 1)

    scheduler.request(input: schedulerInput(2), frame: frame)
    scheduler.request(input: schedulerInput(3), frame: frame)
    #expect(scheduler.activeWorkerCount == 1)
    #expect(scheduler.pendingContentRevision == 3)

    await gate.releaseOne()
    await gate.waitForEntry(2)
    #expect(scheduler.activeWorkerCount == 1)
    await gate.releaseOne()

    for _ in 0..<100 where recorder.revisions.isEmpty { await Task.yield() }
    #expect(recorder.revisions == [3])
    #expect(scheduler.requestCount == 3)
    #expect(scheduler.cancellationCount == 2)
    #expect(scheduler.resultCount == 1)
    #expect(scheduler.staleCount == 0)
}

@Test
@MainActor
func test_layoutScheduler_cancelAndDisposePreventLateResultCallbacks() async {
    let gate = WorkerGate()
    let recorder = ResultRecorder()
    let scheduler = LayoutScheduler(
        hostID: 8,
        engine: FlexboxLayoutEngine(),
        beforeSolve: { generation in await gate.waitBeforeSolve(generation: generation) },
        onResult: { recorder.record($0) }
    )
    let frame = LayoutFrame(width: 10, height: 10)

    scheduler.request(input: schedulerInput(1), frame: frame)
    await gate.waitForEntry(1)
    scheduler.cancel()
    await gate.releaseOne()
    for _ in 0..<100 where scheduler.activeWorkerCount != 0 { await Task.yield() }
    #expect(recorder.revisions.isEmpty)

    scheduler.request(input: schedulerInput(2), frame: frame)
    await gate.waitForEntry(2)
    scheduler.dispose()
    await gate.releaseOne()
    for _ in 0..<100 where scheduler.activeWorkerCount != 0 { await Task.yield() }
    #expect(recorder.revisions.isEmpty)
    #expect(scheduler.cancellationCount == 2)
}

@Test
@MainActor
func test_layoutScheduler_diagnosesUnexpectedEngineFailureWithoutResult() async {
    let recorder = ResultRecorder()
    let scheduler = LayoutScheduler(
        hostID: 9,
        engine: FailingEngine(),
        beforeSolve: { _ in },
        onResult: { recorder.record($0) }
    )

    scheduler.request(input: schedulerInput(1), frame: LayoutFrame(width: 10, height: 10))
    for _ in 0..<100 where scheduler.failureCount == 0 { await Task.yield() }
    #expect(scheduler.failureCount == 1)
    #expect(scheduler.resultCount == 0)
    #expect(recorder.revisions.isEmpty)
}
