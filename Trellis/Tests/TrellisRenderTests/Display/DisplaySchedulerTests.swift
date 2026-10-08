import CoreGraphics
import Foundation
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T06 — DisplayScheduler: many nodes' raster jobs sharing one maxConcurrency budget, one active
// + one coalesced pending job per node (LayoutScheduler's own per-host discipline, generalized).

/// A controllable `TextRasterizer`: an artificial delay holds a job "in flight" long enough for
/// a test to observe overlap/cancellation, and every call is counted — the same technique
/// `SchedulingStaleResultTests.SignallingEngine` uses for `LayoutScheduler`.
private final class ControllableRasterizer: TextRasterizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _concurrentCount = 0
    private var _maxObservedConcurrency = 0
    private var _shouldFail = false
    let delay: TimeInterval

    init(delay: TimeInterval = 0.05) { self.delay = delay }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var maxObservedConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxObservedConcurrency
    }

    func setShouldFail(_ value: Bool) {
        lock.lock()
        _shouldFail = value
        lock.unlock()
    }

    private static func tinyImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func rasterize(_ request: TextDisplayRequest, context: LayoutContext) throws -> DisplayArtifact
    {
        lock.lock()
        _callCount += 1
        _concurrentCount += 1
        _maxObservedConcurrency = max(_maxObservedConcurrency, _concurrentCount)
        let shouldFail = _shouldFail
        lock.unlock()
        defer {
            lock.lock()
            _concurrentCount -= 1
            lock.unlock()
        }

        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try context.checkCancellation()
        if shouldFail { throw LayoutCancellationError.cancelled }
        return DisplayArtifact(
            image: Self.tinyImage(),
            pixelWidth: 1,
            pixelHeight: 1,
            scale: request.scale
        )
    }
}

private func key(_ revision: UInt64, size: Double = 100) -> DisplayKey {
    DisplayKey(
        contentRevision: revision,
        displayRevision: 0,
        environmentRevision: 0,
        size: MeasuredSize(width: size, height: 20),
        scale: 2
    )
}

private func request(size: Double = 100) -> TextDisplayRequest {
    TextDisplayRequest(
        input: TextLayoutInput(
            document: TextDocument("text"),
            style: TextStyle(),
            direction: .leftToRight,
            localeIdentifier: "en",
            maxLines: nil,
            truncation: .tail
        ),
        size: MeasuredSize(width: size, height: 20),
        resolvedColor: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1),
        scale: 2
    )
}

@Test @MainActor
func t06_burstOfChangesOnOneNodeProducesExactlyOneArtifact() async {
    let rasterizer = ControllableRasterizer(delay: 0.03)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
    let node = NodeID(rawValue: 1)

    for revision in 1...100 {
        scheduler.schedule(nodeID: node, key: key(UInt64(revision)), request: request())
    }

    for _ in 0..<20_000 where scheduler.artifact(for: node) == nil { await Task.yield() }
    // Drain until the scheduler is fully idle: no active/pending work left.
    for _ in 0..<20_000 where scheduler.activeJobCount > 0 { await Task.yield() }

    #expect(scheduler.committedKey(for: node) == key(100))
    #expect(scheduler.statistics.scheduled == 100)
    #expect(scheduler.statistics.dropped > 0)
}

@Test @MainActor
func t06_resizeDuringRasterDiscardsTheStaleGeometryAndCommitsTheNewOne() async {
    let rasterizer = ControllableRasterizer(delay: 0.05)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
    let node = NodeID(rawValue: 1)

    scheduler.schedule(nodeID: node, key: key(1, size: 100), request: request(size: 100))
    // `drain()` starts a job synchronously inside `schedule()` — no await needed for it to
    // already be active before the resize below supersedes it.
    #expect(scheduler.activeJobCount == 1)
    scheduler.schedule(nodeID: node, key: key(2, size: 200), request: request(size: 200))

    for _ in 0..<20_000 where scheduler.committedKey(for: node) != key(2, size: 200) {
        await Task.yield()
    }
    #expect(scheduler.committedKey(for: node) == key(2, size: 200))
}

@Test @MainActor
func t06_disposeDuringRasterCommitsNothingLate() async {
    let rasterizer = ControllableRasterizer(delay: 0.05)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
    let node = NodeID(rawValue: 1)

    scheduler.schedule(nodeID: node, key: key(1), request: request())
    #expect(scheduler.activeJobCount == 1)
    scheduler.dispose()

    // Wait past the in-flight job's own delay: if it were going to commit late, it would have by now.
    try? await Task.sleep(nanoseconds: 150_000_000)
    #expect(scheduler.artifact(for: node) == nil)
}

@Test @MainActor
func t06_maxConcurrencyIsNeverExceeded() async {
    let rasterizer = ControllableRasterizer(delay: 0.05)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
    let nodes = (1...10).map { NodeID(rawValue: UInt64($0)) }

    for (index, node) in nodes.enumerated() {
        scheduler.schedule(nodeID: node, key: key(UInt64(index)), request: request())
    }
    for _ in 0..<40_000 where nodes.contains(where: { scheduler.artifact(for: $0) == nil }) {
        await Task.yield()
    }

    for node in nodes {
        #expect(scheduler.artifact(for: node) != nil)
    }
    #expect(rasterizer.maxObservedConcurrency <= 2)
    #expect(rasterizer.callCount == 10)
}

@Test @MainActor
func t06_everyScheduledNodeHasAnArtifactAfterDrainEvenOnHeavyOverflow() async {
    let rasterizer = ControllableRasterizer(delay: 0.01)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 1)
    let nodes = (1...20).map { NodeID(rawValue: UInt64($0)) }

    for (index, node) in nodes.enumerated() {
        scheduler.schedule(nodeID: node, key: key(UInt64(index)), request: request())
    }
    for _ in 0..<100_000 where nodes.contains(where: { scheduler.artifact(for: $0) == nil }) {
        await Task.yield()
    }

    for node in nodes {
        #expect(scheduler.artifact(for: node) != nil)
    }
    #expect(scheduler.statistics.completed == 20)
}

@Test @MainActor
func t06_alreadyCommittedKeyIsATrueNoOp() {
    let rasterizer = ControllableRasterizer(delay: 0)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
    let node = NodeID(rawValue: 1)

    scheduler.schedule(nodeID: node, key: key(1), request: request())
    scheduler.schedule(nodeID: node, key: key(1), request: request())
    #expect(scheduler.statistics.scheduled == 1)
}

@Test @MainActor
func t06_cancelPurgesActivePendingAndCommittedState() async {
    let rasterizer = ControllableRasterizer(delay: 0.05)
    let scheduler = DisplayScheduler(rasterizer: rasterizer, maxConcurrency: 2)
    let node = NodeID(rawValue: 1)

    scheduler.schedule(nodeID: node, key: key(1), request: request())
    for _ in 0..<20_000 where scheduler.artifact(for: node) == nil { await Task.yield() }
    #expect(scheduler.artifact(for: node) != nil)

    scheduler.cancel(nodeID: node)
    #expect(scheduler.artifact(for: node) == nil)
    #expect(scheduler.committedKey(for: node) == nil)
}
