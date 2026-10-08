import Foundation
import TrellisCore

/// Immutable host state captured with a submitted layout request.
///
/// Ownership: values are copied into the request. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public struct HostRenderRequest: Sendable, Hashable {
    /// The host that owns this request.
    ///
    /// Ownership: returns a copied scalar. Isolation: none. Errors: none. Cancellation: not applicable.
    public let hostID: UInt64
    /// Monotonic coordinator generation.
    ///
    /// Ownership: returns a copied scalar. Isolation: none. Errors: none. Cancellation: not applicable.
    public let generation: UInt64
    /// Root identity captured for this request.
    ///
    /// Ownership: returns an immutable identity. Isolation: none. Errors: none. Cancellation: not applicable.
    public let treeIdentity: NodeID
    /// Root geometry revision captured with the input snapshot.
    ///
    /// Ownership: returns a copied scalar. Isolation: none. Errors: none. Cancellation: not applicable.
    public let contentRevision: UInt64
    /// Root environment revision captured with the input snapshot.
    ///
    /// Ownership: returns a copied scalar. Isolation: none. Errors: none. Cancellation: not applicable.
    public let environmentRevision: UInt64
    /// Host bounds in root coordinates.
    ///
    /// Ownership: returns an immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bounds: LayoutFrame
    /// Pixel scale used for rounding.
    ///
    /// Ownership: returns a copied scalar. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scale: Double
    /// Root direction captured for this request.
    ///
    /// Ownership: returns an immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let direction: LayoutDirection

    /// Creates an immutable host request.
    ///
    /// Ownership: the returned value owns copied fields. Isolation: none. Errors: invalid frame
    /// and scale values are normalized by their value types. Cancellation: not applicable.
    public init(
        hostID: UInt64,
        generation: UInt64,
        treeIdentity: NodeID,
        contentRevision: UInt64,
        environmentRevision: UInt64,
        bounds: LayoutFrame,
        scale: Double,
        direction: LayoutDirection
    ) {
        self.hostID = hostID
        self.generation = generation
        self.treeIdentity = treeIdentity
        self.contentRevision = contentRevision
        self.environmentRevision = environmentRevision
        self.bounds = bounds
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.direction = direction
    }
}

/// Publication metadata kept beside, but deliberately outside, `HostRenderRequest` so layout
/// equality and hashing remain independent of animation policy (D64).
package struct AnimationCommitEnvelope: Sendable, Hashable {
    package let request: HostRenderRequest
    package let intents: [AnimationIntent]
    /// The mount epoch `intents` were resolved against — the same value `Node.animate`'s scope
    /// records carry as `AnimationIntent.epoch` and `LayerAnimator`'s own D64 key uses. Carried
    /// here, next to `intents`, rather than read back off the coordinator or re-derived from a
    /// bridge's own counter, so a consumer never resolves one commit's intents against a
    /// different commit's epoch (M04).
    package let epoch: UInt64
}

/// Coordinates coalesced tree invalidation, background layout, and synchronous geometry commit.
///
/// Ownership: retains its mounted root until unmount, replacement, or disposal, and owns one
/// scheduler. Isolation: MainActor. Errors: stale or malformed results are rejected before any
/// geometry callback. Cancellation: lifecycle changes cancel the scheduler's active worker.
@MainActor
public final class RenderCoordinator {
    /// Called immediately before the matching geometry/paint publication.
    ///
    /// Changes outside an animation scope carry an empty intent array; consumers diff only
    /// changed properties, so metadata publication never interrupts unrelated active animations.
    package var onAnimationCommit: (@MainActor (AnimationCommitEnvelope) -> Void)?
    /// Called after a fully validated result has updated every Node frame.
    ///
    /// Ownership: retained until replaced or disposed. Isolation: MainActor. Errors: none.
    /// Cancellation: never called for stale or malformed results.
    public var onCommitGeometry: (@MainActor @Sendable (LayoutResult, HostRenderRequest) -> Void)?

    /// Called synchronously after geometry callback and coordinator bookkeeping complete.
    ///
    /// Ownership: retained until replaced or disposed. Isolation: MainActor. Errors: none.
    /// Cancellation: never called for stale or malformed results.
    public var onPostCommit: (@MainActor @Sendable (HostRenderRequest) -> Void)?

    /// Called instead of a layout pass when a flush finds nothing the engine needs to redo
    /// — same tree revisions, environment and host state as the last commit — but the pending
    /// window carried `.appearance`: a paint-only change (C09/C29). The receiver re-applies
    /// presentation to the committed layers; no snapshot, measure or place runs.
    ///
    /// Ownership: retained until replaced or disposed. Isolation: MainActor. Errors: none.
    /// Cancellation: not called after dispose.
    public var onPaintOnly: (@MainActor @Sendable (HostRenderRequest) -> Void)?

    /// Called instead of a layout pass when a flush finds the pending window carried
    /// `.semantics` (A03, D41) — focus/accessibility metadata changed on already committed
    /// frames. Independent of `onPaintOnly`: a window with both reasons calls both, in that
    /// order. The receiver republishes its semantic snapshot from the last commit; no
    /// snapshot, measure or place runs, and an active solve is not cancelled for it.
    ///
    /// Ownership: retained until replaced or disposed. Isolation: MainActor. Errors: none.
    /// Cancellation: not called after dispose.
    public var onSemanticsOnly: (@MainActor @Sendable (HostRenderRequest) -> Void)?

    /// Called instead of a layout pass when a flush finds the pending window carried
    /// `.display` (ADR 0014, T04) — a color-only `TextNode.textStyle` write on already
    /// committed frames. Independent of `onPaintOnly`/`onSemanticsOnly`: a window with more
    /// than one of these reasons calls each in turn. The receiver schedules a display/raster
    /// pass (`DisplayScheduler`, T06) from the last commit's geometry; no snapshot, measure or
    /// place runs, and an active solve is not cancelled for it.
    ///
    /// Ownership: retained until replaced or disposed. Isolation: MainActor. Errors: none.
    /// Cancellation: not called after dispose.
    public var onDisplayOnly: (@MainActor @Sendable (HostRenderRequest) -> Void)?

    /// Stable identity of this coordinator's host.
    ///
    /// Ownership: returns a copied scalar. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let hostID: UInt64
    private(set) var isMounted = false
    private(set) var isSuspended = false
    private(set) var isDisposed = false
    /// Snapshot of this coordinator's counters — see `HostRenderStatistics`.
    var statistics: HostRenderStatistics {
        HostRenderStatistics(
            requested: requestedCount,
            coalesced: coalescedCount,
            stale: staleCount,
            committed: committedCount,
            retries: retryCount,
            cancelled: scheduler.cancellationCount
        )
    }

    private(set) var requestedCount = 0
    /// Layout input snapshots captured — the work a semantic-only or paint-only flush must
    /// not do (A03 acceptance); an internal counter, not part of `HostRenderStatistics`.
    private(set) var layoutSnapshotCount = 0
    private(set) var coalescedCount = 0
    private(set) var staleCount = 0
    private(set) var committedCount = 0
    private(set) var lastCommittedRequest: HostRenderRequest?
    private(set) var lastCommittedResult: LayoutResult?

    /// M07's layout axis of scene readiness (D69): `true` while a solve is active or a host
    /// state/tree change is waiting for one — i.e. whenever the next commit is already known to
    /// differ from what is on screen now. Deliberately does not look at `flushScheduled`: every
    /// worker completion unconditionally schedules one more housekeeping flush to check for
    /// additional work (`workerFinished`), which almost always finds `pendingHostState` already
    /// `nil` and resolves to a no-op one runloop turn later — that transient flag is not evidence
    /// of pending layout work, only of this bookkeeping not having run yet. `false` right after a
    /// commit or a coalesced same-work flush leaves nothing outstanding.
    var hasPendingLayoutWork: Bool {
        activeRequest != nil || pendingHostState != nil
    }

    private lazy var scheduler: LayoutScheduler = LayoutScheduler(
        hostID: hostID,
        onResult: { [weak self] result in self?.handle(result) },
        onWorkerFinished: { [weak self] generation in self?.workerFinished(generation) }
    )
    private var root: Node?
    private var generation: UInt64 = 0
    private var activeRequest: HostRenderRequest?
    private var latestHostState: HostState?
    private var pendingHostState: HostState?
    private var animationEpoch: UInt64 = 0
    private var activeAnimationIntents: [AnimationIntent] = []
    private var carriedAnimationIntents: [AnimationIntent] = []
    package private(set) var lastCommittedAnimationIntents: [AnimationIntent] = []
    private var flushScheduled = false
    private let rejectResult: @MainActor (LayoutResult, HostRenderRequest, Node) -> String?
    private(set) var retryCount = 0
    private(set) var retryExhausted = false

    private static let maximumRetryCount = 8

    private struct HostState: Equatable {
        let bounds: LayoutFrame
        let scale: Double
    }

    /// Creates an idle coordinator for one host.
    ///
    /// Ownership: the coordinator owns its scheduler and callback wiring. Isolation: MainActor.
    /// Errors: none. Cancellation: no work starts until a mounted root is invalidated.
    public init(hostID: UInt64) {
        self.hostID = hostID
        rejectResult = { _, _, _ in nil }
    }

    init(
        hostID: UInt64,
        rejectResult: @escaping @MainActor (LayoutResult, HostRenderRequest, Node) -> String?
    ) {
        self.hostID = hostID
        self.rejectResult = rejectResult
    }

    /// Mounts `root` and begins receiving its coalesced invalidation pings.
    ///
    /// Ownership: retains `root` until lifecycle removal. Isolation: MainActor. Errors: none.
    /// Cancellation: replacing a different root cancels current work.
    public func mount(root: Node) {
        mount(root: root, animationEpoch: nil)
    }

    /// Mounts a root with the bridge's epoch so intent records share the renderer lifecycle.
    package func mount(root: Node, animationEpoch: UInt64) {
        mount(root: root, animationEpoch: Optional(animationEpoch))
    }

    private func mount(root: Node, animationEpoch requestedEpoch: UInt64?) {
        guard !isDisposed else { return }

        if self.root !== root { replaceRoot(newRoot: root) }
        isMounted = true
        if let requestedEpoch {
            animationEpoch = requestedEpoch
        } else {
            animationEpoch &+= 1
        }
        root.beginAnimationIntentCollection(epoch: animationEpoch)
        attachInvalidation(to: root)
    }

    /// Stops receiving tree invalidations and cancels owned layout work.
    ///
    /// Ownership: releases the root and callbacks attached to it. Isolation: MainActor. Errors:
    /// none. Cancellation: cancels active work.
    public func unmount() {
        guard !isDisposed else { return }
        root?.endAnimationIntentCollection()
        root?.onInvalidate = nil
        root = nil
        isMounted = false
        activeRequest = nil
        latestHostState = nil
        pendingHostState = nil
        activeAnimationIntents.removeAll(keepingCapacity: true)
        carriedAnimationIntents.removeAll(keepingCapacity: true)
        lastCommittedAnimationIntents.removeAll(keepingCapacity: true)
        scheduler.cancel()
    }

    /// Suspends new submissions and cancels in-flight work.
    ///
    /// Ownership: retains mounted state. Isolation: MainActor. Errors: none. Cancellation:
    /// active work is cancelled and a later resume uses the latest supplied host state.
    public func suspend() {
        guard !isDisposed, !isSuspended else { return }
        isSuspended = true
        root?.pauseAnimationIntentCollection()
        activeAnimationIntents.removeAll(keepingCapacity: true)
        carriedAnimationIntents.removeAll(keepingCapacity: true)
        lastCommittedAnimationIntents.removeAll(keepingCapacity: true)
        activeRequest = nil
        scheduler.cancel()
    }

    /// Enables submissions again and flushes the latest known host state.
    ///
    /// Ownership: retains current root. Isolation: MainActor. Errors: none. Cancellation: none.
    public func resume() {
        guard !isDisposed, isSuspended else { return }
        isSuspended = false
        root?.resumeAnimationIntentCollection(epoch: animationEpoch)
        resetRetryBudget()
        pendingHostState = latestHostState
        scheduleFlush()
    }

    /// Replaces the mounted root and cancels requests belonging to the previous tree.
    ///
    /// Ownership: releases the old root and retains `newRoot`. Isolation: MainActor. Errors:
    /// none. Cancellation: active work is cancelled.
    public func replaceRoot(newRoot: Node) {
        guard !isDisposed else { return }
        root?.endAnimationIntentCollection()
        root?.onInvalidate = nil
        root = newRoot
        activeRequest = nil
        lastCommittedRequest = nil
        lastCommittedResult = nil
        activeAnimationIntents.removeAll(keepingCapacity: true)
        carriedAnimationIntents.removeAll(keepingCapacity: true)
        lastCommittedAnimationIntents.removeAll(keepingCapacity: true)
        resetRetryBudget()
        scheduler.cancel()
        if isMounted {
            animationEpoch &+= 1
            newRoot.beginAnimationIntentCollection(epoch: animationEpoch)
            attachInvalidation(to: newRoot)
        }
    }

    /// Records current host geometry and coalesces it with tree invalidation into one flush.
    ///
    /// Ownership: copies the scalar host state. Isolation: MainActor. Errors: invalid bounds or
    /// scale are ignored. Cancellation: a newer state supersedes an unsubmitted older state.
    public func invalidate(root: Node, bounds: LayoutFrame, scale: Double) {
        guard !isDisposed, isMounted, self.root === root, bounds.width >= 0, bounds.height >= 0,
            scale.isFinite, scale > 0
        else { return }

        let state = HostState(bounds: bounds, scale: scale)
        resetRetryBudget()
        latestHostState = state
        pendingHostState = state
        if activeRequest != nil { scheduler.cancel() }
        scheduleFlush()
    }

    /// Permanently releases the root, callbacks, and scheduler.
    ///
    /// Ownership: releases all owned references. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal; all active work is cancelled.
    public func dispose() {
        guard !isDisposed else { return }
        unmount()
        isDisposed = true
        scheduler.dispose()
        onCommitGeometry = nil
        onPostCommit = nil
        onPaintOnly = nil
        onSemanticsOnly = nil
        onDisplayOnly = nil
        onAnimationCommit = nil
    }

    private func attachInvalidation(to root: Node) {
        root.onInvalidate = { [weak self, weak root] _, reasons in
            guard let self, let root, self.root === root else { return }

            self.resetRetryBudget()
            if self.pendingHostState == nil { self.pendingHostState = self.latestHostState }
            // A paint-only or semantic-only ping does not invalidate a solve in flight: the
            // commit reads live appearance and metadata anyway (A03/D41). Only a layout
            // reason makes the running result stale.
            if self.activeRequest != nil,
                !reasons.isSubset(of: [.appearance, .semantics, .display])
            {
                self.scheduler.cancel()
            }
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.flush()
        }
    }

    private func flush() {
        guard !isDisposed, isMounted, !isSuspended, activeRequest == nil,
            let root, let hostState = pendingHostState
        else {
            flushScheduled = false
            return
        }

        // Semantic-only / paint-only fast path (A03): when the pending window carries no
        // layout reason and nothing the engine reads has moved since the last commit, there
        // is no layout snapshot to take at all — the C29 same-work check below still captures
        // one before it can tell. `.arrangement` is a layout reason, so no resolve is skipped.
        if let last = lastCommittedRequest, publishFromLastCommit(root: root, last: last) {
            flushScheduled = false
            return
        }

        // Resolve pending `Arrangement`s before the snapshot (C32, D13) — and before
        // `flushScheduled` is cleared, so the invalidation pings the resolver's own tree
        // mutations raise are absorbed by this flush instead of scheduling a second one. The
        // snapshot below already sees the resolved tree; `consumePendingInvalidation()` then
        // drains what the resolve added to the pending window.
        root.resolveDirtyArrangements()
        flushScheduled = false

        let constraint = SizeConstraint(
            width: .exact(hostState.bounds.width),
            height: .exact(hostState.bounds.height)
        )
        let snapshot = root.makeLayoutInputSnapshot(constraint: constraint)
        layoutSnapshotCount += 1
        let request = HostRenderRequest(
            hostID: hostID,
            generation: generation &+ 1,
            treeIdentity: snapshot.identity,
            contentRevision: snapshot.contentRevision,
            environmentRevision: snapshot.environmentRevision,
            bounds: hostState.bounds,
            scale: hostState.scale,
            direction: snapshot.direction
        )
        if let last = lastCommittedRequest, request.describesSameWork(as: last) {
            coalescedCount += 1
            pendingHostState = nil
            let intents = mergedAnimationIntents(
                carriedAnimationIntents,
                root.pendingAnimationIntentRecords
            )
            let pending = root.consumePendingInvalidation()
            carriedAnimationIntents.removeAll(keepingCapacity: true)
            deliverNonLayoutWork(
                pending?.reasons ?? [],
                last: last,
                root: root,
                intents: intents
            )
            return
        }
        generation = request.generation
        pendingHostState = nil
        activeAnimationIntents = mergedAnimationIntents(
            carriedAnimationIntents,
            root.pendingAnimationIntentRecords
        )
        carriedAnimationIntents.removeAll(keepingCapacity: true)
        root.consumePendingInvalidation()
        activeRequest = request
        requestedCount += 1
        scheduler.request(
            input: snapshot,
            frame: hostState.bounds,
            roundingPolicy: PixelRoundingPolicy(scale: hostState.scale)
        )
    }

    /// The fast path of `flush()`: `true` when the pending window held only appearance and/or
    /// semantics reasons and every input the engine reads — tree revisions, environment,
    /// direction, host bounds and scale — still equals the last commit, in which case the
    /// window is drained and the paint-only/semantic-only callbacks run without a snapshot.
    private func publishFromLastCommit(root: Node, last: HostRenderRequest) -> Bool {
        let reasons = root.pendingInvalidationReasons
        guard !reasons.isEmpty, reasons.isSubset(of: [.appearance, .semantics, .display]),
            let hostState = pendingHostState, hostState.bounds == last.bounds,
            hostState.scale == last.scale,
            max(root.structureRevision, root.geometryRevision) == last.contentRevision
        else { return false }

        let environment = root.environmentSnapshot
        guard environment.revision == last.environmentRevision,
            environment.values.layoutDirection == last.direction
        else { return false }

        coalescedCount += 1
        pendingHostState = nil
        let intents = mergedAnimationIntents(
            carriedAnimationIntents,
            root.pendingAnimationIntentRecords
        )
        let pending = root.consumePendingInvalidation()
        carriedAnimationIntents.removeAll(keepingCapacity: true)
        deliverNonLayoutWork(
            pending?.reasons ?? [],
            last: last,
            root: root,
            intents: intents
        )
        return true
    }

    private func deliverNonLayoutWork(
        _ reasons: DirtyReasons,
        last: HostRenderRequest,
        root: Node,
        intents: [AnimationIntent]
    ) {
        publishAnimationMetadata(request: last, intents: intents)
        if reasons.contains(.appearance) {
            Log.on(.commit, "paint-only", host: hostID, generation: last.generation, node: root.id)
            onPaintOnly?(last)
        }
        if reasons.contains(.semantics) {
            Log.on(
                .commit,
                "semantics-only",
                host: hostID,
                generation: last.generation,
                node: root.id
            )
            onSemanticsOnly?(last)
        }
        if reasons.contains(.display) {
            Log.on(
                .commit,
                "display-only",
                host: hostID,
                generation: last.generation,
                node: root.id
            )
            onDisplayOnly?(last)
        }
    }

    private func handle(_ result: LayoutResult) {
        guard let request = activeRequest, let root else { return }

        if let failure = validationFailure(for: result, request: request, root: root) {
            handleValidationFailure(failure, request: request)
            return
        }

        let currentIntents = consumePendingNonLayoutState(root: root)
        let committedIntents = mergedAnimationIntents(activeAnimationIntents, currentIntents)
        activeAnimationIntents.removeAll(keepingCapacity: true)
        activeRequest = nil
        lastCommittedRequest = request
        lastCommittedResult = result
        committedCount += 1
        resetRetryBudget()
        Log.on(.commit, "applied", host: hostID, generation: request.generation, node: root.id)
        publishAnimationMetadata(request: request, intents: committedIntents)
        onCommitGeometry?(result, request)
        onPostCommit?(request)
    }

    private func validationFailure(
        for result: LayoutResult,
        request: HostRenderRequest,
        root: Node
    ) -> String? {
        guard !isDisposed, isMounted, !isSuspended else { return "lifecycle-not-active" }
        guard result.treeIdentity == request.treeIdentity else {
            return "tree expected=\(request.treeIdentity) actual=\(result.treeIdentity)"
        }
        guard result.contentRevision == request.contentRevision else {
            return "content expected=\(request.contentRevision) actual=\(result.contentRevision)"
        }
        guard result.environmentRevision == request.environmentRevision else {
            return
                "environment expected=\(request.environmentRevision) actual=\(result.environmentRevision)"
        }
        let liveContentRevision = max(root.structureRevision, root.geometryRevision)
        guard liveContentRevision == request.contentRevision else {
            return "live-content expected=\(request.contentRevision) actual=\(liveContentRevision)"
        }
        let environment = root.environmentSnapshot
        guard environment.revision == request.environmentRevision else {
            return
                "live-environment expected=\(request.environmentRevision) actual=\(environment.revision)"
        }
        guard environment.values.layoutDirection == request.direction else {
            return
                "direction expected=\(request.direction) actual=\(environment.values.layoutDirection)"
        }

        if let injectedFailure = rejectResult(result, request, root) { return injectedFailure }
        guard root.applyLayoutResult(result) else { return "incomplete-or-malformed-result" }
        return nil
    }

    private func handleValidationFailure(_ failure: String, request: HostRenderRequest) {
        staleCount += 1
        carriedAnimationIntents = mergedAnimationIntents(
            carriedAnimationIntents,
            activeAnimationIntents
        )
        activeAnimationIntents.removeAll(keepingCapacity: true)
        activeRequest = nil
        retryCount += 1
        if retryCount >= Self.maximumRetryCount {
            retryExhausted = true
            pendingHostState = nil
            Log.on(
                .commit,
                "retry-exhausted",
                host: hostID,
                generation: request.generation,
                "level=error n=\(retryCount) \(failure)"
            )
            return
        }
        let level = retryCount >= 3 ? "warn" : "info"
        Log.on(
            .commit,
            "retry",
            host: hostID,
            generation: request.generation,
            "level=\(level) n=\(retryCount) \(failure)"
        )
        pendingHostState = latestHostState
        scheduleFlush()
    }

    private func resetRetryBudget() {
        retryCount = 0
        retryExhausted = false
    }

    private func workerFinished(_: UInt64) {
        // C14 submits no second request while `activeRequest` is set, so the scheduler callback
        // that frees its single worker slot always belongs to that request. Scheduler and
        // coordinator generations are deliberately independent counters.
        if activeRequest != nil {
            carriedAnimationIntents = mergedAnimationIntents(
                carriedAnimationIntents,
                activeAnimationIntents
            )
            activeAnimationIntents.removeAll(keepingCapacity: true)
            activeRequest = nil
        }
        scheduleFlush()
    }

    private func consumePendingNonLayoutState(root: Node) -> [AnimationIntent] {
        let reasons = root.pendingInvalidationReasons
        guard !reasons.isEmpty, reasons.isSubset(of: [.appearance, .semantics, .display]) else {
            return []
        }

        let intents = root.pendingAnimationIntentRecords
        pendingHostState = nil
        root.consumePendingInvalidation()
        return intents
    }

    private func publishAnimationMetadata(
        request: HostRenderRequest,
        intents: [AnimationIntent]
    ) {
        lastCommittedAnimationIntents = intents
        onAnimationCommit?(
            AnimationCommitEnvelope(request: request, intents: intents, epoch: animationEpoch)
        )
    }

    private func mergedAnimationIntents(
        _ older: [AnimationIntent],
        _ newer: [AnimationIntent]
    ) -> [AnimationIntent] {
        var byIdentity: [AnimationIntentIdentity: AnimationIntent] = [:]
        for intent in older where intent.epoch == animationEpoch {
            byIdentity[AnimationIntentIdentity(intent)] = intent
        }
        for intent in newer where intent.epoch == animationEpoch {
            byIdentity[AnimationIntentIdentity(intent)] = intent
        }
        return byIdentity.values.sorted { $0.sequence < $1.sequence }
    }

    private struct AnimationIntentIdentity: Hashable {
        let epoch: UInt64
        let sequence: UInt64

        init(_ intent: AnimationIntent) {
            epoch = intent.epoch
            sequence = intent.sequence
        }
    }
}

extension HostRenderRequest {
    /// Whether a layout pass for `self` would recompute exactly what `other` already
    /// committed: every input the engine reads is equal. `generation` is deliberately left
    /// out — it is a per-request counter, so comparing whole requests (as C14 first did) can
    /// never coalesce and turned every paint-only ping into a full solve.
    func describesSameWork(as other: HostRenderRequest) -> Bool {
        hostID == other.hostID && treeIdentity == other.treeIdentity
            && contentRevision == other.contentRevision
            && environmentRevision == other.environmentRevision && bounds == other.bounds
            && scale == other.scale && direction == other.direction
    }
}

/// Read-only counters of one host's render pipeline (C31): how many layout requests were
/// submitted, how many flushes found nothing new to solve (coalesced), how many results
/// arrived stale, how many committed, how many commit retries and solver cancellations
/// happened. Deterministic under a synchronous burst, so tests assert on them; measurement
/// runs record them next to timings. Not a profiler: no timings live here.
///
/// Ownership: a copied value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct HostRenderStatistics: Sendable, Hashable {
    /// Layout requests handed to the scheduler.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let requested: Int
    /// Flushes that found the last commit already describes the same work.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let coalesced: Int
    /// Results rejected because the tree or environment moved on while they were solved.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let stale: Int
    /// Results applied to the tree and handed to the renderer.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let committed: Int
    /// Consecutive commit retries currently counted toward the retry budget.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let retries: Int
    /// Solver workers cancelled before producing a result.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let cancelled: Int

    /// Creates a statistics value.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation:
    /// not applicable.
    public init(
        requested: Int,
        coalesced: Int,
        stale: Int,
        committed: Int,
        retries: Int,
        cancelled: Int
    ) {
        self.requested = requested
        self.coalesced = coalesced
        self.stale = stale
        self.committed = committed
        self.retries = retries
        self.cancelled = cancelled
    }
}
