import FlexEngine
import Foundation
import LayoutCore
import Testing

@testable import Nodes

private struct PreparedModel: Identifiable, Sendable {
    let id: Int
    var revision = 0
    var length = 30.0
}

private struct RowPlan: Sendable, Equatable {
    let id: Int
    let revision: Int
    let context: ItemPreparationContext
    let length: Double
}

private enum RowFailure: Error { case unavailable }

private func checkWorkerSegment() {
    #expect(!Thread.isMainThread)
}

/// Deliberately ignores cancellation until opened: cancelled workers must keep their slots.
private actor PreparationGate {
    struct Request: Sendable {
        let token: UUID
        let item: PreparedModel
        let context: ItemPreparationContext
    }
    nonisolated let events: AsyncStream<Request>
    private let eventSink: AsyncStream<Request>.Continuation
    private var pending: [UUID: (Request, CheckedContinuation<PreparedItem<RowPlan>, any Error>)] =
        [:]
    private var opened: Bool
    private var failOnce: Set<Int>
    private var requests: [Request] = []
    private var active = 0
    private var peak = 0

    init(open: Bool = false, failOnce: Set<Int> = []) {
        let pair = AsyncStream<Request>.makeStream()
        events = pair.stream
        eventSink = pair.continuation
        opened = open
        self.failOnce = failOnce
    }

    func prepare(_ item: PreparedModel, _ context: ItemPreparationContext) async throws
        -> PreparedItem<RowPlan>
    {
        let request = Request(token: UUID(), item: item, context: context)
        requests.append(request)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        eventSink.yield(request)
        if opened { return try result(for: request) }
        return try await withCheckedThrowingContinuation { pending[request.token] = (request, $0) }
    }

    func open() {
        opened = true
        let waiting = pending.values
        pending = [:]
        for (request, continuation) in waiting {
            do { continuation.resume(returning: try result(for: request)) } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func close() { opened = false }
    func recorded() -> [Request] { requests }
    func maximumActive() -> Int { peak }

    private func result(for request: Request) throws -> PreparedItem<RowPlan> {
        if failOnce.remove(request.item.id) != nil { throw RowFailure.unavailable }
        let plan = RowPlan(
            id: request.item.id,
            revision: request.item.revision,
            context: request.context,
            length: request.item.length
        )
        return PreparedItem(plan, length: plan.length)
    }
}

@MainActor
private final class PreparedCell: Node {
    let axis: ScrollAxis
    var length = 30.0
    init(axis: ScrollAxis) { self.axis = axis }
    override var layoutContent: LeafContent? {
        axis == .vertical ? .size(width: 20, height: length) : .size(width: length, height: 20)
    }
    func show(length: Double) {
        guard self.length != length else { return }
        self.length = length
        setNeedsLayout()
    }
}

@MainActor
private final class PlanRecorder {
    var cells: [Int: PreparedCell] = [:]
    var applied: [RowPlan] = []
    var failed: [Int] = []
    let axis: ScrollAxis
    init(axis: ScrollAxis) { self.axis = axis }
    func node(_ item: PreparedModel, _ state: PreparedItemState<RowPlan>) -> Node {
        MainActor.assertIsolated()
        let cell = cells[item.id] ?? PreparedCell(axis: axis)
        cells[item.id] = cell
        switch state {
        case .pending: cell.show(length: 30)
        case let .ready(result):
            applied.append(result.value)
            cell.show(length: result.value.length)
        case .failed:
            failed.append(item.id)
            cell.show(length: 30)
        }
        return cell
    }
}

@MainActor
private final class PreparedFeed: Node {
    let recorder: PlanRecorder
    let stack: LazyStack<PreparedModel>
    let scroll: Scroll
    init(
        count: Int = 100,
        axis: ScrollAxis = .vertical,
        lanes: Int = 1,
        policy: ItemPreparationPolicy = ItemPreparationPolicy(),
        gate: PreparationGate,
        synchronous: Bool = false
    ) {
        let recorder = PlanRecorder(axis: axis)
        self.recorder = recorder
        if synchronous {
            stack = LazyStack(
                axis,
                items: (0..<count).map { PreparedModel(id: $0) },
                lanes: lanes,
                estimatedLength: 30
            ) { item in
                let cell = recorder.cells[item.id] ?? PreparedCell(axis: axis)
                recorder.cells[item.id] = cell
                cell.show(length: item.length)
                return cell
            }
        } else {
            stack = LazyStack(
                axis,
                items: (0..<count).map { PreparedModel(id: $0) },
                lanes: lanes,
                estimatedLength: 30,
                preparation: policy,
                key: { $0.revision },
                prepare: { item, context in
                    checkWorkerSegment()
                    return try await gate.prepare(item, context)
                },
                content: { recorder.node($0, $1) }
            )
        }
        scroll = Scroll(axis, content: stack)
    }
    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            if scroll.axis == .horizontal { scroll.height(.points(100)) } else { scroll }
        }
    }
}

@MainActor
private func preparedHost(_ feed: PreparedFeed) -> NodeHost {
    let host = NodeHost(root: feed, size: LayoutSize(width: 200, height: 150))
    host.layoutIfNeeded()
    return host
}

@MainActor
private func settlePreparation(_ feed: PreparedFeed, _ host: NodeHost) async {
    for _ in 0..<16 {
        host.layoutIfNeeded()
        await feed.stack.preparationsFinished()
        await host.layoutFinished()
        if !host.needsLayout, feed.stack.preparationProgress.running == 0 { return }
    }
    Issue.record("Preparation and layout did not settle")
}

@Test @MainActor
func modelPlansArePreparedBeyondTheNodesCreatedByTheList() async throws {
    let gate = PreparationGate()
    let feed = PreparedFeed(gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    var events = gate.events.makeAsyncIterator()
    let started = await events.next()
    _ = try #require(started)
    #expect(feed.recorder.applied.isEmpty)
    #expect(feed.recorder.cells.count == 10)

    await gate.open()
    await feed.stack.preparationsFinished()
    let requests = await gate.recorded()
    #expect(requests.contains { $0.item.id >= 10 })
    #expect(feed.recorder.cells[10] == nil)
    #expect(feed.recorder.applied.isEmpty)
    await settlePreparation(feed, host)
    #expect(feed.recorder.applied.contains { $0.id == 0 })
    #expect(feed.recorder.cells[10] == nil)
}

@Test @MainActor
func preparationIncludesAnItemExactlyOnTheConfiguredRangeBoundary() async {
    let gate = PreparationGate(open: true)
    let range = ContentRangePolicy(
        preloadDistance: 0,
        displayDistance: 0,
        preloadRetentionDistance: 0,
        displayRetentionDistance: 0
    )
    let feed = PreparedFeed(count: 8, policy: ItemPreparationPolicy(range: range), gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    await settlePreparation(feed, host)
    let requests = await gate.recorded()
    #expect(Set(requests.map { $0.item.id }) == Set(0...5))
}

@Test @MainActor
func cancelledWorkersKeepTheirBudgetAndNewlyVisibleRowsPassOldQueuedRows() async throws {
    let gate = PreparationGate()
    let policy = ItemPreparationPolicy(
        maximumConcurrentTasks: 2,
        maximumQueuedItems: 3,
        maximumRetainedItems: 8
    )
    let feed = PreparedFeed(policy: policy, gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    var events = gate.events.makeAsyncIterator()
    let first = await events.next()
    let second = await events.next()
    _ = try #require(first)
    _ = try #require(second)
    #expect(
        feed.stack.preparationProgress
            == ItemPreparationProgress(running: 2, queued: 3, retained: 8)
    )

    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 1500)
    host.layoutIfNeeded()
    #expect(feed.stack.preparationProgress.running == 2)
    #expect(feed.stack.preparationProgress.queued <= 3)
    #expect(feed.stack.preparationProgress.retained <= 8)
    #expect(await gate.maximumActive() == 2)

    await gate.open()
    await settlePreparation(feed, host)
    let requests = await gate.recorded()
    #expect(requests.count > 2)
    #expect(requests[2].item.id == 50)
    #expect(await gate.maximumActive() <= 2)
    #expect(!feed.recorder.applied.contains { $0.id < 40 })
}

@Test @MainActor
func aSameIdentityWithANewRevisionCannotApplyTheOldPlan() async throws {
    let gate = PreparationGate()
    let feed = PreparedFeed(
        count: 1,
        policy: ItemPreparationPolicy(maximumConcurrentTasks: 1),
        gate: gate
    )
    let host = preparedHost(feed)
    defer { host.detach() }
    var events = gate.events.makeAsyncIterator()
    let started = await events.next()
    _ = try #require(started)
    feed.stack.items = [PreparedModel(id: 0, revision: 1, length: 90)]
    host.layoutIfNeeded()
    await gate.open()
    await settlePreparation(feed, host)
    #expect(!feed.recorder.applied.isEmpty)
    #expect(feed.recorder.applied.allSatisfy { $0.revision == 1 })
    #expect(feed.recorder.cells[0]?.frame.size.height == 90)
}

private enum PlanEnvironment: Sendable, CaseIterable {
    case width, locale, textScale, scale, direction
}

@Test(arguments: PlanEnvironment.allCases) @MainActor
private func changingTheEnvironmentBeforeTheNextLayoutRejectsTheWorker(_ change: PlanEnvironment)
    async throws
{
    let gate = PreparationGate()
    let feed = PreparedFeed(count: 1, gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    var events = gate.events.makeAsyncIterator()
    let startedValue = await events.next()
    let started = try #require(startedValue)
    switch change {
    case .width: host.size.width = 400
    case .locale: host.locale = Locale(identifier: "ru")
    case .textScale: host.conditions.textScale = 1.5
    case .scale: host.scale = 2
    case .direction: host.direction = .rightToLeft
    }
    await gate.open()
    await feed.stack.preparationsFinished()
    #expect(feed.recorder.applied.isEmpty)
    await settlePreparation(feed, host)
    #expect(!feed.recorder.applied.isEmpty)
    #expect(feed.recorder.applied.allSatisfy { $0.context != started.context })
}

@Test(arguments: [false, true]) @MainActor
func aPreparedLengthBeforeTheWindowPreservesItsVisibleAnchor(_ backgroundSolve: Bool) async throws {
    let gate = PreparationGate(open: true)
    let feed = PreparedFeed(count: 1000, gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    host.solvesInBackground = backgroundSolve
    feed.scroll.contentOffset = LayoutPoint(x: 0, y: 15000)
    await settlePreparation(feed, host)
    let cell = try #require(feed.recorder.cells[500])
    let before = try #require(feed.scroll.frame(of: cell))
    let beforeY = before.origin.y - feed.scroll.contentOffset.y
    await gate.close()
    feed.stack.items[499].revision = 1
    feed.stack.items[499].length = 90
    host.layoutIfNeeded()
    await gate.open()
    await settlePreparation(feed, host)
    let after = try #require(feed.scroll.frame(of: cell))
    #expect(after.origin.y - feed.scroll.contentOffset.y == beforeY)
    #expect(feed.recorder.cells[499]?.frame.size.height == 90)
}

@Test @MainActor
func preparedAndSynchronousRowsProduceTheSameAppliedGeometry() async {
    let gate = PreparationGate(open: true)
    let prepared = PreparedFeed(count: 24, gate: gate)
    let synchronous = PreparedFeed(count: 24, gate: gate, synchronous: true)
    let items = (0..<24).map { PreparedModel(id: $0, length: Double(30 + ($0 % 3) * 20)) }
    prepared.stack.items = items
    synchronous.stack.items = items
    // Both lists must know every length before comparing their total extents. Preparation
    // otherwise legitimately refines more offscreen estimates than the synchronous list.
    let size = LayoutSize(width: 200, height: 1500)
    let host = NodeHost(root: prepared, size: size)
    let reference = NodeHost(root: synchronous, size: size)
    host.layoutIfNeeded()
    reference.layoutIfNeeded()
    defer { host.detach(); reference.detach() }
    await settlePreparation(prepared, host)
    reference.layoutIfNeeded()
    #expect(prepared.stack.frame == synchronous.stack.frame)
    #expect(prepared.scroll.offsetRange == synchronous.scroll.offsetRange)
    for (id, cell) in prepared.recorder.cells where cell.isMounted {
        #expect(cell.frame == synchronous.recorder.cells[id]?.frame)
    }
}

@MainActor
private final class ListReference {
    weak var value: LazyStack<PreparedModel>?
    init(_ value: LazyStack<PreparedModel>?) { self.value = value }
}

@Test @MainActor
func aWorkerDoesNotKeepADetachedListAlive() async throws {
    let gate = PreparationGate()
    var feed: PreparedFeed? = PreparedFeed(count: 1, gate: gate)
    var host: NodeHost? = preparedHost(try #require(feed))
    let reference = ListReference(feed?.stack)
    var events = gate.events.makeAsyncIterator()
    let started = await events.next()
    _ = try #require(started)
    host?.detach()
    host = nil
    feed = nil
    #expect(reference.value == nil)
    await gate.open()
}

@Test @MainActor
func failedPlansUseTheErrorStateAndWaitForExplicitRetry() async {
    let gate = PreparationGate(open: true, failOnce: [0])
    let feed = PreparedFeed(count: 1, gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    await settlePreparation(feed, host)
    #expect(feed.recorder.failed.contains(0))
    for _ in 0..<3 { host.setNeedsLayout(); host.layoutIfNeeded() }
    #expect(await gate.recorded().count == 1)
    #expect(feed.stack.retryPreparation(for: 0))
    await settlePreparation(feed, host)
    #expect(await gate.recorded().count == 2)
    #expect(feed.recorder.applied.contains { $0.id == 0 })
    #expect(!feed.stack.retryPreparation(for: 0))
}

@Test @MainActor
func hidingTheHostCancelsPreparationAndShowingItStartsFreshWork() async throws {
    let gate = PreparationGate()
    let feed = PreparedFeed(count: 1, gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    var events = gate.events.makeAsyncIterator()
    let started = await events.next()
    _ = try #require(started)
    host.isShown = false
    #expect(feed.stack.preparationProgress.retained == 0)
    await gate.open()
    await feed.stack.preparationsFinished()
    #expect(feed.recorder.applied.isEmpty)
    #expect(feed.stack.preparationProgress.running == 0)
    host.isShown = true
    await settlePreparation(feed, host)
    #expect(feed.recorder.applied.contains { $0.id == 0 })
    host.detach()
    #expect(feed.stack.preparationProgress.retained == 0)
}

@Test(arguments: [ScrollAxis.vertical, .horizontal]) @MainActor
func preparedGridsUsePerLaneConstraintsAndApplyThePlanLength(_ axis: ScrollAxis) async {
    let gate = PreparationGate(open: true)
    let feed = PreparedFeed(count: 12, axis: axis, lanes: 2, gate: gate)
    let host = preparedHost(feed)
    defer { host.detach() }
    await settlePreparation(feed, host)
    #expect(!feed.recorder.applied.isEmpty)
    for plan in feed.recorder.applied {
        let across = axis == .vertical ? feed.stack.frame.size.width : feed.stack.frame.size.height
        #expect(plan.context.crossAxisLength == across / 2)
    }
    for cell in feed.recorder.cells.values where cell.isMounted {
        #expect((axis == .vertical ? cell.frame.size.height : cell.frame.size.width) == 30)
    }
}
