import TrellisCore

/// Relative urgency of a raster job — drained high-first, never dropped (D53: overflow
/// reschedules, it never loses the most recent visible work).
///
/// Ownership: the value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
public enum DisplayPriority: Sendable, Hashable {
    case normal
    case high
}

/// Read-only counters of one `DisplayScheduler`'s work (T06 acceptance: scheduled/started/
/// completed/cancelled/dropped/stale). Deterministic under a synchronous burst against a
/// controllable test rasterizer, so tests assert on them.
///
/// Ownership: a copied value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct DisplayStatistics: Sendable, Hashable {
    /// Raster jobs accepted by `schedule(...)` — a call that found the node already up to date
    /// is not counted.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scheduled: Int
    /// Jobs that actually began rasterizing on a worker.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let started: Int
    /// Jobs whose artifact was committed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let completed: Int
    /// Jobs cancelled before producing a committed artifact — superseded while active, or the
    /// scheduler was disposed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let cancelled: Int
    /// Queued (not yet started) jobs superseded by a newer request for the same node before
    /// they ever ran — the coalescing that turns a burst of edits into one raster, not lost
    /// work (D53).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let dropped: Int
    /// Jobs that finished with a result no longer wanted — the scheduler was disposed while
    /// they were in flight.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let stale: Int

    /// Creates a statistics value.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        scheduled: Int,
        started: Int,
        completed: Int,
        cancelled: Int,
        dropped: Int,
        stale: Int
    ) {
        self.scheduled = scheduled
        self.started = started
        self.completed = completed
        self.cancelled = cancelled
        self.dropped = dropped
        self.stale = stale
    }
}

/// Schedules and tracks CoreText raster jobs across every text-bearing node of one mount (D53).
///
/// One node has at most one active job and one coalesced pending job at a time — the same
/// single-active/single-pending discipline `LayoutScheduler` applies per host, generalized here
/// to many nodes sharing one `maxConcurrency` budget instead of one host owning a single worker.
/// A `schedule(...)` call for a node with an active job for a different key cancels that job and
/// coalesces the new request into the pending slot; when the active job's cancellation is
/// observed, the pending job starts. A burst of edits on one node therefore produces exactly one
/// committed artifact, never one per edit.
///
/// Ownership: owns its active `Task`s and the committed-artifact table. Isolation: MainActor.
/// Errors: none. Cancellation: `dispose()` cancels every active job and discards the queue;
/// `LayoutCancellationError.cancelled`-equivalent failures inside a job are reported as
/// `cancelled`, never committed.
@MainActor
public final class DisplayScheduler {
    private struct PendingJob {
        let key: DisplayKey
        let request: TextDisplayRequest
        let priority: DisplayPriority
    }

    private struct ActiveJob {
        let key: DisplayKey
        let task: Task<Void, Never>
    }

    private enum JobOutcome: Sendable {
        case result(DisplayArtifact)
        case cancelled
        case failed
    }

    private let rasterizer: any TextRasterizer
    private let maxConcurrency: Int
    private var pendingByNode: [NodeID: PendingJob] = [:]
    private var activeJobs: [NodeID: ActiveJob] = [:]
    private var committedTable: [NodeID: (key: DisplayKey, artifact: DisplayArtifact)] = [:]
    private var readyHigh: [NodeID] = []
    private var readyNormal: [NodeID] = []
    private var readySet: Set<NodeID> = []
    private var isDisposed = false

    private(set) var scheduledCount = 0
    private(set) var startedCount = 0
    private(set) var completedCount = 0
    private(set) var cancelledCount = 0
    private(set) var droppedCount = 0
    private(set) var staleCount = 0

    /// Snapshot of this scheduler's counters.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var statistics: DisplayStatistics {
        DisplayStatistics(
            scheduled: scheduledCount,
            started: startedCount,
            completed: completedCount,
            cancelled: cancelledCount,
            dropped: droppedCount,
            stale: staleCount
        )
    }

    /// Called on the MainActor immediately after an artifact is committed for `nodeID`.
    ///
    /// Ownership: retained until replaced or `dispose()`. Isolation: MainActor. Errors: none.
    /// Cancellation: never called for a cancelled, failed, or stale job.
    public var onArtifactCommitted: (@MainActor (NodeID, DisplayArtifact) -> Void)?

    /// Number of jobs currently rasterizing — never more than `maxConcurrency`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var activeJobCount: Int { activeJobs.count }

    /// Number of jobs coalesced and waiting for a `maxConcurrency` slot — distinct from
    /// `activeJobCount`: a node here has not started rasterizing yet (M07's display readiness
    /// axis, D69, treats "queued" the same as "in flight" — both mean a bitmap is still stale).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var pendingJobCount: Int { pendingByNode.count }

    /// Creates a scheduler bounded to `maxConcurrency` simultaneous raster jobs.
    ///
    /// Ownership: retains `rasterizer`. Isolation: MainActor. Errors: none. Cancellation: no
    /// work starts until `schedule(...)` is called.
    public init(rasterizer: any TextRasterizer = CoreTextRenderer(), maxConcurrency: Int = 4) {
        self.rasterizer = rasterizer
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// The committed artifact for `nodeID`, if its `key` matches what was last requested and
    /// nothing has superseded it since.
    ///
    /// Ownership: returns a value; the scheduler retains the artifact. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func artifact(for nodeID: NodeID) -> DisplayArtifact? {
        committedTable[nodeID]?.artifact
    }

    /// The key of the currently committed artifact for `nodeID`, or `nil` before any commit.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func committedKey(for nodeID: NodeID) -> DisplayKey? { committedTable[nodeID]?.key }

    /// Requests a raster pass for `nodeID` at `key`/`request`, unless `nodeID` is already
    /// committed or in flight for exactly this `key` (D53).
    ///
    /// Ownership: copies `request` into scheduler-owned work. Isolation: MainActor. Errors:
    /// none. Cancellation: supersedes an older active or pending job for the same node.
    public func schedule(
        nodeID: NodeID,
        key: DisplayKey,
        request: TextDisplayRequest,
        priority: DisplayPriority = .normal
    ) {
        guard !isDisposed else { return }

        if committedTable[nodeID]?.key == key { return }

        if let active = activeJobs[nodeID] {
            if active.key == key {
                pendingByNode[nodeID] = nil
                return
            }
            active.task.cancel()
        }

        let wasQueued = pendingByNode[nodeID] != nil
        pendingByNode[nodeID] = PendingJob(key: key, request: request, priority: priority)
        if wasQueued { droppedCount += 1 }
        scheduledCount += 1

        if activeJobs[nodeID] == nil { markReady(nodeID, priority: priority) }
        drain()
    }

    /// Cancels and purges every trace of `nodeID` — active job, queued job, and committed
    /// artifact (D58: a removed node's display work does not linger).
    ///
    /// Ownership: releases anything retained for `nodeID`. Isolation: MainActor. Errors: none.
    /// Cancellation: cancels an active job for `nodeID`, if any.
    public func cancel(nodeID: NodeID) {
        if let active = activeJobs.removeValue(forKey: nodeID) {
            active.task.cancel()
            cancelledCount += 1
        }
        if pendingByNode.removeValue(forKey: nodeID) != nil {
            droppedCount += 1
        }
        readySet.remove(nodeID)
        readyHigh.removeAll { $0 == nodeID }
        readyNormal.removeAll { $0 == nodeID }
        committedTable[nodeID] = nil
    }

    /// Cancels every active and queued job and discards all committed artifacts (D58: `detach`/
    /// `replaceRoot` never let a late raster commit).
    ///
    /// Ownership: releases every owned job and the committed table. Isolation: MainActor.
    /// Errors: none. Cancellation: cancels every active job.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        for job in activeJobs.values {
            job.task.cancel()
            cancelledCount += 1
        }
        activeJobs.removeAll()
        pendingByNode.removeAll()
        readyHigh.removeAll()
        readyNormal.removeAll()
        readySet.removeAll()
        committedTable.removeAll()
        onArtifactCommitted = nil
    }

    private func markReady(_ nodeID: NodeID, priority: DisplayPriority) {
        guard readySet.insert(nodeID).inserted else { return }
        switch priority {
        case .high: readyHigh.append(nodeID)
        case .normal: readyNormal.append(nodeID)
        }
    }

    private func popReady() -> NodeID? {
        if !readyHigh.isEmpty { return readyHigh.removeFirst() }
        if !readyNormal.isEmpty { return readyNormal.removeFirst() }
        return nil
    }

    private func drain() {
        while activeJobs.count < maxConcurrency {
            guard let nodeID = popReady() else { return }
            readySet.remove(nodeID)
            guard activeJobs[nodeID] == nil, let job = pendingByNode.removeValue(forKey: nodeID)
            else { continue }
            start(nodeID: nodeID, job: job)
        }
    }

    private func start(nodeID: NodeID, job: PendingJob) {
        startedCount += 1
        let rasterizer = rasterizer
        let request = job.request
        let key = job.key
        let task = Task.detached {
            let outcome: JobOutcome
            do {
                try Task.checkCancellation()
                let context = LayoutContext.currentTask()
                let artifact = try rasterizer.rasterize(request, context: context)
                outcome = .result(artifact)
            } catch is CancellationError {
                outcome = .cancelled
            } catch is LayoutCancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed
            }
            await MainActor.run { [weak self] in
                self?.finish(nodeID: nodeID, key: key, outcome: outcome)
            }
        }
        activeJobs[nodeID] = ActiveJob(key: key, task: task)
    }

    private func finish(nodeID: NodeID, key: DisplayKey, outcome: JobOutcome) {
        guard !isDisposed else { return }
        guard activeJobs[nodeID]?.key == key else {
            staleCount += 1
            return
        }
        activeJobs[nodeID] = nil

        switch outcome {
        case .result(let artifact):
            committedTable[nodeID] = (key, artifact)
            completedCount += 1
            onArtifactCommitted?(nodeID, artifact)
        case .cancelled:
            cancelledCount += 1
        case .failed:
            cancelledCount += 1
        }

        if let pending = pendingByNode[nodeID] {
            markReady(nodeID, priority: pending.priority)
        }
        drain()
    }
}
