import Foundation

/// Why a focus transition happened (A04/A05, D39).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FocusChangeReason: Sendable, Hashable {
    /// An explicit `focus(_:)` request.
    case request
    /// A `move(_:)` — Tab/Shift-Tab or an arrow.
    case navigation
    /// Focus returned to the node it was on before a scope opened or the host suspended.
    case restoration
    /// The focused node stopped being a candidate on a commit or publish — removed, disabled,
    /// hidden, clipped — and a fallback was chosen (or none was available).
    case invalidation
    /// A modal scope opened or closed.
    case scope
    /// The platform focus system reported the transition (tvOS, D44/D45); the engine mirrors
    /// it rather than initiating it.
    case native
    /// The host went inactive; focus cleared, identity kept for restoration.
    case suspend
    /// The host detached or reset the engine.
    case detach
}

/// Immutable focus transition (A04, D39): what had focus, what has it now, and why. Delivered
/// once per effective transition through `FocusEngine.onFocusChange`, after both `focusOut`
/// and `focusIn` events ran. Ported in spirit from Weave's `FocusChange`, plus `reason`.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct FocusChange: Sendable, Hashable {
    /// The node that had focus before, if any.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let previous: NodeID?

    /// The node that has focus now, if any.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let next: NodeID?

    /// Why.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let reason: FocusChangeReason

    /// Creates a transition value.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(previous: NodeID?, next: NodeID?, reason: FocusChangeReason) {
        self.previous = previous
        self.next = next
        self.reason = reason
    }
}

/// Diagnostic record of the last `move(_:)` search (A04): the candidates in the order they
/// were ranked and the one selected, or `nil` when there was none.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct FocusTrace: Sendable, Hashable {
    /// The direction searched.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let direction: FocusDirection

    /// Candidates in ranking order — for arrows by score, for `.next`/`.previous` the
    /// sequence considered.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let candidates: [NodeID]

    /// The winner, or `nil`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let selected: NodeID?

    /// Creates a trace.
    ///
    /// Ownership: arrays are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(direction: FocusDirection, candidates: [NodeID], selected: NodeID?) {
        self.direction = direction
        self.candidates = candidates
        self.selected = selected
    }
}

/// What a focus request did (A04, D38/D39).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FocusMoveResult: Sendable, Hashable {
    /// A transition ran; its events were delivered and `onFocusChange` was called.
    case moved(FocusChange)
    /// Nothing to do: the target already had focus, or no candidate exists in that direction
    /// (a host passes an unhandled Tab on to the platform, D38).
    case unchanged
    /// The request cannot be honoured: no snapshot, the target is not a candidate (unknown,
    /// disabled, hidden, out of scope, not live), or the engine was reset mid-transition.
    case unavailable
    /// Made from inside a transition callback: queued and run after the current transition
    /// completes, with fresh validation (D39). Its own result is reported through
    /// `onFocusChange` only.
    case deferred
}

/// What the focus engine did with a key event (A07).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum KeyOutcome: Sendable, Hashable {
    /// Consumed: focus moved, or the event was dispatched to the focused node.
    case handled
    /// Not consumed — no focus, no candidate in that direction, no snapshot: the host lets
    /// the platform's own traversal or responder chain have it (D38).
    case unhandled
}

/// Platform-neutral focus core (A04/A05, D35–D40): which committed node has keyboard/remote
/// focus, deterministic sequential and directional search over the committed snapshot, one
/// modal scope with restoration, and the transaction that moves focus. Ported in spirit from
/// Weave's `FocusTree` (`Focus.swift`) with its Flux output, strong `focusedNode` and
/// nearest-neighbour Tab replaced (defects #33/#34): the engine holds identities and values
/// only, a live `Node` is borrowed per call as `root`, and Tab is tree order.
///
/// A transition (D39) runs `focusOut` on the previous node, re-validates the next one against
/// the live tree, runs `focusIn`, then `onFocusChange` — each event through the ordinary
/// three-phase dispatch along the committed route. A request made from inside one of those
/// callbacks does not recurse: it is queued and run afterwards, up to `deferredRequestLimit`
/// per drain, so a callback loop ends with a diagnostic instead of a stack overflow. If a
/// callback resets the engine (host detach), the transition is abandoned there.
///
/// Ownership: retains identities, values and the callback; never a `Node`. Isolation:
/// MainActor. Errors: reported as `FocusMoveResult`. Cancellation: `reset()` clears
/// everything; `suspend(root:)` keeps only the restoration identity.
@MainActor
public final class FocusEngine {
    /// The node with focus, or `nil`. Written only by a completed transition.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var focusedID: NodeID?

    /// The modal scope, or `nil` for the whole tree (D40).
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var scopeID: NodeID?

    /// The focus to return to when the scope closes or the host resumes (D40).
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var restorationID: NodeID?

    /// Number of completed transitions.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var transitionRevision: UInt64 = 0

    /// Diagnostic record of the last `move(_:)`.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var lastTrace: FocusTrace?

    /// The snapshot searches run over — the host's last publish.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var snapshot: SemanticSnapshot?

    /// Called once after every completed transition, after `focusIn`.
    ///
    /// Ownership: retained until replaced; must not retain the engine's owner strongly.
    /// Isolation: MainActor. Errors: none. Cancellation: survives `reset()`; the owner clears
    /// it by assigning `nil`.
    public var onFocusChange: (@MainActor (FocusChange) -> Void)?

    /// Number of queued requests one transition chain may run before further ones are
    /// dropped with a diagnostic (D39) — the guard against a callback loop.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let deferredRequestLimit = 8

    /// Requests dropped because `deferredRequestLimit` was exceeded — a test hook.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var droppedRequestCount = 0

    private let dispatcher = EventDispatcher()
    private var inTransition = false
    private var deferred: [(NodeID?, FocusChangeReason)] = []
    private var drainBudget = 0
    /// Bumped by `reset()` so a transition interrupted by a detach from inside a callback
    /// can tell and stop.
    private var epoch: UInt64 = 0
    /// The candidate list of the current snapshot and scope with its positions, computed
    /// once per (publish, scope) rather than per move: a Tab over 1000 controls is then
    /// O(1) per step instead of a fresh pre-order walk each time (A12).
    private var candidateCache: CandidateCache?

    private struct CandidateCache {
        let mountEpoch: UInt64
        let revision: UInt64
        let scope: NodeID?
        let list: [NodeID]
        let position: [NodeID: Int]
    }

    /// Focus candidates of the current snapshot inside the current scope, cached per publish.
    private func candidates() -> [NodeID] {
        guard let snapshot else { return [] }

        if let cache = candidateCache, cache.mountEpoch == snapshot.mountEpoch,
            cache.revision == snapshot.revision, cache.scope == scopeID
        {
            return cache.list
        }
        let list = snapshot.focusCandidates(scope: scopeID)
        var position: [NodeID: Int] = [:]
        for (index, id) in list.enumerated() { position[id] = index }
        candidateCache = CandidateCache(
            mountEpoch: snapshot.mountEpoch,
            revision: snapshot.revision,
            scope: scopeID,
            list: list,
            position: position
        )
        return list
    }

    private func candidatePosition(of id: NodeID) -> Int? {
        _ = candidates()
        return candidateCache?.position[id]
    }

    /// Creates an engine with no snapshot and no focus.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init() {}

    // MARK: - Snapshot

    /// Adopts a newly published snapshot and re-validates the current focus and scope
    /// against it (A04 §3.1, A05 D40). A snapshot of a different mount clears everything
    /// first — a new attach never inherits the old epoch. A focused node that is no longer
    /// a candidate is replaced by the next live candidate in the previous traversal order,
    /// then the previous one, then the first in scope, else `nil` (`reason: .invalidation`).
    /// A scope whose root vanished closes with the same restoration rules as `setScope(nil)`.
    ///
    /// Ownership: `snapshot` is copied, `root` borrowed for the call. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func apply(_ snapshot: SemanticSnapshot, root: Node) {
        if let old = self.snapshot, old.mountEpoch != snapshot.mountEpoch {
            reset()
        }
        let previous = self.snapshot
        self.snapshot = snapshot

        if let scopeID, snapshot.record(for: scopeID) == nil {
            Log.on(.focus, "scope-lost", node: scopeID)
            self.scopeID = nil
            let restoration = restorationID
            restorationID = nil
            if let restoration, isCandidate(restoration) {
                transition(to: restoration, reason: .restoration, root: root)
                return
            }
        }
        guard let focusedID, !isCandidate(focusedID) else { return }

        let fallback = fallbackCandidate(after: focusedID, in: previous)
        Log.on(.focus, "invalidated", node: focusedID, "fallback=\(String(describing: fallback))")
        transition(to: fallback, reason: .invalidation, root: root)
    }

    // MARK: - Requests

    /// Moves focus to `id` (or clears it with `nil`), if it is a candidate in the current
    /// scope and still live under `root` (D37/D39).
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: see
    /// `FocusMoveResult`. Cancellation: a callback that resets the engine ends the transition.
    @discardableResult
    public func focus(_ id: NodeID?, root: Node, reason: FocusChangeReason = .request)
        -> FocusMoveResult
    {
        guard snapshot != nil else { return .unavailable }

        if let id {
            guard isCandidate(id), isLive(id, under: root) else {
                Log.on(.focus, "request-rejected", node: id, "reason=\(reason)")
                return .unavailable
            }
        }
        return transition(to: id, reason: reason, root: root)
    }

    /// Moves focus in `direction` (D38): `.next`/`.previous` over the committed pre-order of
    /// candidates in scope, arrows by the directional score, an explicit `preferredNext`
    /// override first. Without a current focus `.next` and the arrows pick the initial
    /// candidate (highest `priority`, then first in order), `.previous` the last. No wrap
    /// outside a modal scope; inside one `.next`/`.previous` wrap, arrows do not.
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: `.unchanged`
    /// when nothing is in that direction — the host hands the key to the platform.
    /// Cancellation: as `focus(_:root:reason:)`.
    @discardableResult
    public func move(_ direction: FocusDirection, root: Node) -> FocusMoveResult {
        guard let snapshot else { return .unavailable }

        let candidates = candidates()
        guard !candidates.isEmpty else {
            lastTrace = FocusTrace(direction: direction, candidates: [], selected: nil)
            return .unchanged
        }
        guard let current = focusedID, candidatePosition(of: current) != nil else {
            let initial = initialCandidate(
                candidates,
                snapshot: snapshot,
                last: direction == .previous
            )
            lastTrace = FocusTrace(direction: direction, candidates: candidates, selected: initial)
            return transition(to: initial, reason: .navigation, root: root)
        }

        if let override = snapshot.record(for: current)?.focus.preferredNext[direction],
            override != current, candidatePosition(of: override) != nil
        {
            lastTrace = FocusTrace(direction: direction, candidates: [override], selected: override)
            return transition(to: override, reason: .navigation, root: root)
        }

        let selected: NodeID?
        let ranked: [NodeID]
        switch direction {
        case .next, .previous:
            ranked = candidates
            selected = sequentialNeighbour(of: current, in: candidates, forward: direction == .next)
        case .up, .down, .left, .right:
            ranked = directionalRanking(
                from: current,
                direction: direction,
                in: candidates,
                snapshot: snapshot
            )
            selected = ranked.first
        }
        lastTrace = FocusTrace(direction: direction, candidates: ranked, selected: selected)
        guard let selected else { return .unchanged }

        return transition(to: selected, reason: .navigation, root: root)
    }

    // MARK: - Keys (A07)

    /// Routes one key event from a host adapter (A07, D38/D43). Navigation keys — Tab
    /// (Shift-Tab), arrows — become `move(_:)` on key-down; `.handled` when focus moved,
    /// `.unhandled` when there was nothing in that direction, so the host passes the key on
    /// to the platform instead of trapping it. Activation keys — Return, Space, Select — are
    /// dispatched as `keyDown`/`keyUp` events along the focused node's committed route
    /// (capture/target/bubble, `preventDefault()` honoured), then the focused control's
    /// default key action runs (`ControlNode`: press cycle, activation on key-up). Without a
    /// focused node an activation key is `.unhandled`.
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: reported as
    /// `KeyOutcome`. Cancellation: focus loss between key-down and key-up cancels the cycle.
    @discardableResult
    public func sendKey(_ data: KeyData, type: EventType, root: Node) -> KeyOutcome {
        guard snapshot != nil else { return .unhandled }
        guard type == .keyDown || type == .keyUp else { return .unhandled }

        switch data.key {
        case .tab, .upArrow, .downArrow, .leftArrow, .rightArrow:
            guard type == .keyDown else { return .unhandled }

            let direction: FocusDirection
            switch data.key {
            case .tab: direction = data.isShiftDown ? .previous : .next
            case .upArrow: direction = .up
            case .downArrow: direction = .down
            case .leftArrow: direction = .left
            default: direction = .right
            }
            if case .moved = move(direction, root: root) { return .handled }
            return .unhandled
        case .returnKey, .space, .select:
            guard let focusedID, let snapshot, let route = snapshot.route(to: focusedID) else {
                return .unhandled
            }

            let event = Event(type: type, targetID: focusedID, payload: .key(data))
            let result = dispatcher.dispatch(event, route: route, root: root)
            guard !result.routeBroken, let live = EventDispatcher.resolve(route, under: root),
                let control = live.last as? ControlNode
            else { return .handled }

            control.handleKeyDefault(
                event,
                defaultPrevented: result.defaultPrevented,
                source: data.key == .select ? .remote : .keyboard
            )
            return .handled
        }
    }

    /// Cancels an open key press cycle on the focused control without activating it (A08):
    /// the platform reported the press as cancelled, so no key-up is coming.
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: none.
    /// Cancellation: this is one; idempotent.
    public func cancelKeyPress(root: Node) {
        guard let focusedID, let snapshot, let route = snapshot.route(to: focusedID),
            let control = EventDispatcher.resolve(route, under: root)?.last as? ControlNode
        else { return }

        control.cancelKeyPress()
    }

    // MARK: - Scope and lifecycle (A05)

    /// Opens a modal scope at `id`, or closes it with `nil` (D40). Opening remembers the
    /// current focus for restoration and, if it is not inside the scope, moves focus to the
    /// first candidate there — or to `nil` when the scope has none; focus is never left in
    /// the background. Closing restores the remembered focus if it is a candidate, else the
    /// first candidate of the tree. The same scope twice is a no-op; an unknown scope id is
    /// rejected. A nested scope replaces the current one without a stack.
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: an id not in
    /// the snapshot is ignored. Cancellation: as transitions.
    public func setScope(_ id: NodeID?, root: Node) {
        guard let snapshot, id != scopeID else { return }

        if let id {
            guard snapshot.record(for: id) != nil else {
                Log.on(.focus, "scope-rejected", node: id, "reason=unknown")
                return
            }

            if scopeID == nil { restorationID = focusedID }
            scopeID = id
            Log.on(
                .focus,
                "scope-open",
                node: id,
                "restoration=\(String(describing: restorationID))"
            )
            if let focusedID, isCandidate(focusedID) { return }

            let candidates = snapshot.focusCandidates(scope: id)
            transition(
                to: initialCandidate(candidates, snapshot: snapshot, last: false),
                reason: .scope,
                root: root
            )
            return
        }

        scopeID = nil
        let restoration = restorationID
        restorationID = nil
        Log.on(.focus, "scope-close", node: restoration)
        if let restoration, isCandidate(restoration), isLive(restoration, under: root) {
            transition(to: restoration, reason: .restoration, root: root)
        } else if let focusedID, isCandidate(focusedID) {
            return
        } else {
            let candidates = snapshot.focusCandidates(scope: nil)
            transition(
                to: initialCandidate(candidates, snapshot: snapshot, last: false),
                reason: .scope,
                root: root
            )
        }
    }

    /// The host went inactive (D40): focus is cleared with `focusOut` delivered and its
    /// identity kept for `resume(root:)`; nothing activates on the way.
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: none.
    /// Cancellation: this is one for the current focus.
    public func suspend(root: Node) {
        guard let focusedID else { return }

        restorationID = focusedID
        Log.on(.focus, "suspend", node: focusedID)
        transition(to: nil, reason: .suspend, root: root)
    }

    /// The host is active again: the remembered focus returns if it is still a live candidate
    /// in the current snapshot, otherwise the next live candidate after it takes over
    /// (`.invalidation`); nothing activates (D40). The first publish after resume re-validates
    /// again through `apply`.
    ///
    /// Ownership: `root` is borrowed for the call. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func resume(root: Node) {
        guard focusedID == nil, let restoration = restorationID else { return }

        restorationID = nil
        guard isCandidate(restoration), isLive(restoration, under: root) else {
            // Gone, disabled or hidden while suspended: land where an invalidation would —
            // the next live candidate after it — rather than nowhere.
            let fallback = fallbackCandidate(after: restoration, in: snapshot)
            Log.on(
                .focus,
                "resume-lost",
                node: restoration,
                "fallback=\(String(describing: fallback))"
            )
            transition(to: fallback, reason: .invalidation, root: root)
            return
        }
        transition(to: restoration, reason: .restoration, root: root)
    }

    /// Forgets everything — focus, scope, restoration, snapshot, queued requests — without
    /// delivering events: the tree is going away (D40). A transition running on the stack
    /// above this call stops as soon as its current callback returns.
    ///
    /// Ownership: releases all identities. Isolation: MainActor. Errors: none. Cancellation:
    /// this is it; idempotent.
    public func reset() {
        epoch &+= 1
        focusedID = nil
        scopeID = nil
        restorationID = nil
        snapshot = nil
        lastTrace = nil
        deferred.removeAll()
        Log.on(.focus, "reset")
    }

    // MARK: - Transition (D39)

    @discardableResult
    private func transition(to next: NodeID?, reason: FocusChangeReason, root: Node)
        -> FocusMoveResult
    {
        guard next != focusedID else { return .unchanged }
        guard !inTransition else {
            guard deferred.count + drainBudget < deferredRequestLimit else {
                droppedRequestCount += 1
                Log.on(
                    .focus,
                    "request-dropped",
                    node: next,
                    "reason=\(reason) limit=\(deferredRequestLimit)"
                )
                return .unavailable
            }
            deferred.append((next, reason))
            Log.on(.focus, "request-deferred", node: next, "reason=\(reason)")
            return .deferred
        }

        inTransition = true
        let result = runTransition(to: next, reason: reason, root: root)
        inTransition = false
        drainDeferred(root: root)
        return result
    }

    private func runTransition(to requested: NodeID?, reason: FocusChangeReason, root: Node)
        -> FocusMoveResult
    {
        let startEpoch = epoch
        let previous = focusedID
        var next = requested
        var effectiveReason = reason

        if let previous {
            deliver(
                .focusOut,
                to: previous,
                previous: previous,
                next: next,
                reason: reason,
                root: root
            )
            guard epoch == startEpoch else { return .unavailable }
        }
        // Re-validate after `focusOut`: the callback may have disposed, disabled or detached
        // the target (D39).
        if let candidate = next, !(isCandidate(candidate) && isLive(candidate, under: root)) {
            Log.on(.focus, "next-invalidated", node: candidate, "reason=\(reason)")
            next = nil
            effectiveReason = .invalidation
        }

        focusedID = next
        transitionRevision &+= 1
        if let next {
            deliver(
                .focusIn,
                to: next,
                previous: previous,
                next: next,
                reason: effectiveReason,
                root: root
            )
            guard epoch == startEpoch else { return .unavailable }
        }

        let change = FocusChange(previous: previous, next: next, reason: effectiveReason)
        Log.on(
            .focus,
            "changed",
            node: next,
            "previous=\(String(describing: previous)) reason=\(effectiveReason)"
        )
        onFocusChange?(change)
        return .moved(change)
    }

    private func drainDeferred(root: Node) {
        drainBudget = 0
        while !deferred.isEmpty {
            let (next, reason) = deferred.removeFirst()
            drainBudget += 1
            guard next.map({ isCandidate($0) && isLive($0, under: root) }) ?? true else {
                Log.on(.focus, "deferred-invalid", node: next, "reason=\(reason)")
                continue
            }
            inTransition = true
            _ = runTransition(to: next, reason: reason, root: root)
            inTransition = false
        }
        drainBudget = 0
    }

    private func deliver(
        _ type: EventType,
        to target: NodeID,
        previous: NodeID?,
        next: NodeID?,
        reason: FocusChangeReason,
        root: Node
    ) {
        guard let snapshot, let route = snapshot.route(to: target) else { return }

        let event = Event(
            type: type,
            targetID: target,
            payload: .focus(FocusData(previous: previous, next: next, reason: reason))
        )
        dispatcher.dispatch(event, route: route, root: root)
    }

    // MARK: - Eligibility

    private func isCandidate(_ id: NodeID) -> Bool {
        guard let snapshot, let record = snapshot.record(for: id), record.isFocusCandidate
        else { return false }
        guard let scopeID else { return true }

        return snapshot.isDescendantOrSelf(id, of: scopeID)
    }

    /// The committed route to `id` still describes the live tree under `root`, and the node
    /// itself is not disposed and still enabled (D36 live guard).
    private func isLive(_ id: NodeID, under root: Node) -> Bool {
        guard let snapshot, snapshot.root == root.id, let route = snapshot.route(to: id),
            let live = EventDispatcher.resolve(route, under: root), let target = live.last
        else { return false }

        return !target.isDisposed && target.isEnabledForSemantics
    }

    // MARK: - Search (D38)

    private func initialCandidate(_ candidates: [NodeID], snapshot: SemanticSnapshot, last: Bool)
        -> NodeID?
    {
        var best: (id: NodeID, priority: Int, index: Int)?
        for id in candidates {
            guard let record = snapshot.record(for: id) else { continue }

            let entry = (id: id, priority: record.focus.priority, index: record.traversalIndex)
            guard let current = best else {
                best = entry
                continue
            }

            if entry.priority > current.priority
                || (entry.priority == current.priority
                    && (last ? entry.index > current.index : entry.index < current.index))
            {
                best = entry
            }
        }
        return best?.id
    }

    private func sequentialNeighbour(of current: NodeID, in candidates: [NodeID], forward: Bool)
        -> NodeID?
    {
        guard let position = candidatePosition(of: current) else { return nil }

        let neighbour = forward ? position + 1 : position - 1
        if candidates.indices.contains(neighbour) { return candidates[neighbour] }
        // Wrap only inside a modal scope (D38).
        guard scopeID != nil, candidates.count > 1 else { return nil }

        return forward ? candidates[0] : candidates[candidates.count - 1]
    }

    private func directionalRanking(
        from current: NodeID,
        direction: FocusDirection,
        in candidates: [NodeID],
        snapshot: SemanticSnapshot
    ) -> [NodeID] {
        guard let origin = snapshot.record(for: current)?.visibleBounds else { return [] }

        let originCenter = Self.center(of: origin)
        var scored: [(id: NodeID, score: Double, index: Int)] = []
        for id in candidates where id != current {
            guard let record = snapshot.record(for: id), let bounds = record.visibleBounds else {
                continue
            }

            let center = Self.center(of: bounds)
            let dx = center.x - originCenter.x
            let dy = center.y - originCenter.y
            let primary: Double
            let secondary: Double
            switch direction {
            case .up:
                primary = -dy
                secondary = abs(dx)
            case .down:
                primary = dy
                secondary = abs(dx)
            case .left:
                primary = -dx
                secondary = abs(dy)
            case .right:
                primary = dx
                secondary = abs(dy)
            case .next, .previous:
                continue
            }
            // Strictly positive projection onto the direction (D38).
            guard primary > 0 else { continue }

            scored.append((id: id, score: primary + 0.5 * secondary, index: record.traversalIndex))
        }
        return
            scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score < rhs.score : lhs.index < rhs.index
            }
            .map(\.id)
    }

    private func fallbackCandidate(after lost: NodeID, in previous: SemanticSnapshot?) -> NodeID? {
        guard let snapshot else { return nil }

        let current = snapshot.focusCandidates(scope: scopeID)
        if let previous,
            let position = previous.focusCandidates(scope: scopeID).firstIndex(of: lost)
        {
            let old = previous.focusCandidates(scope: scopeID)
            for id in old[(position + 1)...] where current.contains(id) { return id }
            for id in old[..<position].reversed() where current.contains(id) { return id }
        }
        return current.first
    }

    private static func center(of frame: LayoutFrame) -> LayoutPoint {
        LayoutPoint(x: frame.origin.x + frame.width / 2, y: frame.origin.y + frame.height / 2)
    }
}

extension SemanticSnapshot {
    /// The committed route from the root down to `identity`, or `nil` if it was not
    /// committed — what a focus event is dispatched along (D28/D39).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func route(to identity: NodeID) -> [NodeID]? {
        guard var record = record(for: identity) else { return nil }

        var route = [identity]
        while let parent = record.parent, let parentRecord = self.record(for: parent) {
            route.append(parent)
            record = parentRecord
        }

        return route.reversed()
    }
}
