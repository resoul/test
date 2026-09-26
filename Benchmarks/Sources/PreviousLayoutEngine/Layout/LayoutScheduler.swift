import Foundation

/// The internal boundary around pure layout math (D11).
///
/// The scheduler owns concurrency and result freshness; an engine receives only immutable
/// values and cooperatively reports cancellation by throwing `LayoutCancellationError`.
protocol LayoutEngine: Sendable {
    func solve(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy,
        context: LayoutContext
    ) throws -> LayoutResult
}

struct FlexboxLayoutEngine: LayoutEngine {
    func solve(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy,
        context: LayoutContext
    ) throws -> LayoutResult {
        try FlexboxEngine.layoutContainer(
            input: input,
            frame: frame,
            roundingPolicy: roundingPolicy,
            context: context
        )
    }
}

/// MainActor owner of one host's asynchronous layout work.
///
/// A scheduler deliberately has one active worker and one replaceable pending request. A
/// superseding request cancels the active task but does not start another task until the old
/// solver has returned, so a slow cooperative checkpoint cannot cause multiple solvers for one
/// host to consume CPU or retain old snapshots at once (D09/C13).
///
/// Ownership: owns its worker and callbacks. Isolation: MainActor. Errors: none. Cancellation:
/// supersede, `cancel()`, and `dispose()` cooperatively cancel owned work.
@MainActor
public final class LayoutScheduler {
    /// Receives a current successful layout result on the main actor.
    ///
    /// Ownership: the scheduler retains the closure until `dispose()`. Isolation: MainActor.
    /// Errors: none. Cancellation: cancelled and stale work never invokes this closure.
    public typealias ResultHandler = @MainActor @Sendable (LayoutResult) -> Void

    /// Receives notice after an active worker has actually exited and its slot is free.
    ///
    /// Ownership: the scheduler retains the closure until `dispose()`. Isolation: MainActor.
    /// Errors: none. Cancellation: fires after successful, cancelled, and failed work.
    public typealias WorkerFinishedHandler = @MainActor @Sendable (UInt64) -> Void

    typealias WorkerStart = @Sendable (UInt64) async -> Void

    private struct Request: Sendable {
        let generation: UInt64
        let input: LayoutInputSnapshot
        let frame: LayoutFrame
        let roundingPolicy: PixelRoundingPolicy
    }

    private enum WorkerOutcome: Sendable {
        case result(LayoutResult)
        case cancelled
        case failed(String)
    }

    private let hostID: UInt64
    private let engine: any LayoutEngine
    private let beforeSolve: WorkerStart
    private var onResult: ResultHandler?
    private var onWorkerFinished: WorkerFinishedHandler?
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    /// The thread the active worker solves on once past `beforeSolve`, for `cancel()`.
    private var solverThread: Thread?
    private var activeGeneration: UInt64?
    private var pending: Request?
    private var disposed = false

    private(set) var requestCount = 0
    private(set) var resultCount = 0
    package private(set) var cancellationCount = 0
    private(set) var staleCount = 0
    private(set) var failureCount = 0

    var activeWorkerCount: Int { worker == nil ? 0 : 1 }

    var pendingContentRevision: UInt64? { pending?.input.contentRevision }

    /// Creates a scheduler for one host using Trellis's flex engine.
    ///
    /// Ownership: the scheduler owns its worker and retains both callbacks. Isolation: MainActor.
    /// Errors: none. Cancellation: no work starts until `request` is called.
    public init(
        hostID: UInt64,
        onResult: ResultHandler? = nil,
        onWorkerFinished: WorkerFinishedHandler? = nil
    ) {
        self.hostID = hostID
        engine = FlexboxLayoutEngine()
        beforeSolve = { _ in }
        self.onResult = onResult
        self.onWorkerFinished = onWorkerFinished
    }

    init(
        hostID: UInt64,
        engine: any LayoutEngine,
        beforeSolve: @escaping WorkerStart,
        onResult: ResultHandler? = nil,
        onWorkerFinished: WorkerFinishedHandler? = nil
    ) {
        self.hostID = hostID
        self.engine = engine
        self.beforeSolve = beforeSolve
        self.onResult = onResult
        self.onWorkerFinished = onWorkerFinished
    }

    /// Submits a fresh immutable state for this host.
    ///
    /// The newest state replaces any older pending state. If a solver is active, it is asked to
    /// cancel and remains the sole active worker until its synchronous engine call has exited.
    ///
    /// Ownership: copies the snapshot into scheduler-owned work. Isolation: MainActor. Errors:
    /// none. Cancellation: supersedes an older active or pending request.
    public func request(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy = PixelRoundingPolicy()
    ) {
        guard !disposed else { return }

        generation &+= 1
        requestCount += 1
        let request = Request(
            generation: generation,
            input: input,
            frame: frame,
            roundingPolicy: roundingPolicy
        )
        Log.on(
            .schedule,
            "request",
            host: hostID,
            generation: request.generation,
            node: input.identity,
            "frame=\(frame.width)x\(frame.height)"
        )

        guard worker != nil else {
            start(request)
            return
        }

        pending = request
        worker?.cancel()
        cancellationCount += 1
        Log.on(
            .schedule,
            "supersede",
            host: hostID,
            generation: request.generation,
            node: input.identity,
            "pending=latest"
        )
    }

    /// Cancels active and pending work while leaving the scheduler available for a later request.
    ///
    /// Ownership: releases pending request state. Isolation: MainActor. Errors: none.
    /// Cancellation: requests cooperative cancellation of an active worker.
    public func cancel() {
        generation &+= 1
        pending = nil
        guard worker != nil else { return }

        worker?.cancel()
        solverThread?.cancel()
        cancellationCount += 1
        Log.on(.schedule, "cancel", host: hostID, generation: activeGeneration)
    }

    /// Cancels owned work permanently and releases callbacks.
    ///
    /// Ownership: releases all callbacks and pending state. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal; requests cooperative cancellation of an active worker.
    public func dispose() {
        guard !disposed else { return }

        disposed = true
        pending = nil
        generation &+= 1
        if worker != nil {
            worker?.cancel()
            solverThread?.cancel()
            cancellationCount += 1
        }
        onResult = nil
        onWorkerFinished = nil
        Log.on(.schedule, "dispose", host: hostID, generation: activeGeneration)
    }

    /// Stack given to a solver thread. The engine recurses once per nesting level in both
    /// passes; on the cooperative pool's 512 KiB stack that overflowed at ~200 levels in
    /// Release and ~60 in Debug (defect #22). 16 MiB moves the limit past any tree a screen
    /// can hold; `Thread` is also the only way to ask for it — a `Task` has no stack size.
    nonisolated static let workerStackSize = 16 << 20

    private func start(_ request: Request) {
        precondition(worker == nil)
        activeGeneration = request.generation
        let engine = engine
        let hostID = hostID
        let beforeSolve = beforeSolve
        // The task owns the cancellable wait at `beforeSolve`; the solve itself runs on a
        // dedicated thread for its stack size (`workerStackSize`) — a task cannot ask for
        // one. Cancellation stays cooperative (D09): `cancel()` cancels the task and flags
        // the thread, and the engine's checkpoints read `Thread.current.isCancelled` through
        // `LayoutContext`. The outcome hops back to the MainActor exactly as before.
        worker = Task.detached { [weak self] in
            await beforeSolve(request.generation)
            guard !Task.isCancelled else {
                Log.on(.schedule, "worker-exit", host: hostID, generation: request.generation)
                await self?.finish(.cancelled, generation: request.generation)
                return
            }
            // A `let` copy of the weak capture: the thread body and its hop are `@Sendable`
            // closures and may not re-capture the mutable weak `self` variable.
            let scheduler = self
            let outcome = await withCheckedContinuation { continuation in
                let thread = Thread {
                    // Registered from inside the body, once it is certainly running: a
                    // `Thread.cancel()` that lands before a thread's body has started keeps
                    // that body from ever running, and the continuation would never resume.
                    let running = Thread.current
                    Task { @MainActor in
                        scheduler?.adoptSolverThread(running, generation: request.generation)
                    }
                    let outcome: WorkerOutcome
                    do {
                        let context = LayoutContext(cancellationCheck: {
                            Thread.current.isCancelled
                        })
                        try context.checkCancellation()
                        let result = try engine.solve(
                            input: request.input,
                            frame: request.frame,
                            roundingPolicy: request.roundingPolicy,
                            context: context
                        )
                        try context.checkCancellation()
                        outcome = .result(result)
                    } catch is LayoutCancellationError {
                        outcome = .cancelled
                    } catch {
                        outcome = .failed(String(describing: error))
                    }
                    continuation.resume(returning: outcome)
                }
                thread.name = "trellis.layout.solver"
                thread.stackSize = Self.workerStackSize
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            Log.on(.schedule, "worker-exit", host: hostID, generation: request.generation)
            await self?.finish(outcome, generation: request.generation)
        }
    }

    /// Remembers the active worker's solver thread so `cancel()` can flag it; a thread whose
    /// generation was superseded before this hop ran is flagged immediately instead. A
    /// cancel that lands before the hop is not lost either: the solve runs on and its result
    /// arrives stale, which frees the slot like any other outcome.
    private func adoptSolverThread(_ thread: Thread, generation: UInt64) {
        if activeGeneration == generation, worker != nil, !disposed, generation == self.generation {
            solverThread = thread
        } else {
            thread.cancel()
        }
    }

    private func finish(_ outcome: WorkerOutcome, generation workerGeneration: UInt64) {
        guard activeGeneration == workerGeneration else {
            staleCount += 1
            return
        }

        worker = nil
        solverThread = nil
        activeGeneration = nil

        switch outcome {
        case .result(let result):
            guard !disposed, workerGeneration == generation, pending == nil else {
                // Stale: superseded or cancelled while the worker was already exiting. The
                // worker slot is free all the same, and the owner must hear so — a
                // coordinator that never gets `onWorkerFinished` keeps its active request
                // forever and never flushes again (defect #20).
                staleCount += 1
                Log.on(.schedule, "stale", host: hostID, generation: workerGeneration)
                onWorkerFinished?(workerGeneration)
                startPendingIfNeeded()
                return
            }
            resultCount += 1
            Log.on(
                .commit,
                "result",
                host: hostID,
                generation: workerGeneration,
                node: result.treeIdentity
            )
            onResult?(result)
        case .cancelled:
            Log.on(.schedule, "cancelled", host: hostID, generation: workerGeneration)
        case .failed(let description):
            failureCount += 1
            Log.on(
                .schedule,
                "failure",
                host: hostID,
                generation: workerGeneration,
                description
            )
        }

        onWorkerFinished?(workerGeneration)
        startPendingIfNeeded()
    }

    private func startPendingIfNeeded() {
        guard !disposed, worker == nil, let next = pending else { return }

        pending = nil
        start(next)
    }
}
