/// Owns at most one running effect per key (R04, P6.7): an async unit of work started by
/// `run(_:onConflict:operation:apply:)`, whose result reaches `apply` **only if nothing
/// superseded it in the meantime** — a cancelled or replaced effect's result is discarded
/// structurally, not by convention the caller has to remember. This is the ownership
/// primitive `onLoad`/`onRefresh`/`onLoadMore`/`onRetry` hooks (P6.7) are built on; it does
/// not know about network, pagination, or `Node` — a future `ListNode`/`TableNode` (R10)
/// wires domain-specific keys and results through it, the same way this card's own fake-API
/// tests do.
///
/// Two effects on **different** keys never contend; `run` on the same key while one is
/// already occupied either replaces it (`.restart`: cancels the running `Task` and starts a
/// new one — matches "refresh заменяет актуальный запрос") or is refused
/// (`.ignoreIfRunning`: returns `false`, observable overflow — matches "для lifetime одной
/// модели допускается один initial request in-flight" and loadMore's "один page request на
/// cursor"). Neither policy ever silently drops a *result* your own operation already
/// computed: a stale one is discarded here, at the one point of truth, not by a scattered
/// generation check the caller has to duplicate in every hook.
///
/// Ownership: the caller that constructs this owns it — a "view-owned" effect scope is a
/// plain `EffectOwner` a mounted UI session holds and calls `cancelAll()` on when it detaches
/// (the same explicit-cancellation discipline `StateBinding`/`FluxStateBinding` already use);
/// a "model-owned" effect scope is a plain `EffectOwner` the model itself holds, independent
/// of any UI session's lifetime (P6.7: "model-owned запрос может продолжаться при уходе
/// страницы"). This type provides no automatic lifecycle wiring to any bridge or view by
/// itself. Isolation: MainActor. Errors: none — failure is whatever `Result` the caller's
/// own `operation` returns; this type is failure-agnostic. Cancellation: `cancel(_:)`,
/// `cancelAll()`, or superseding a key via `.restart`.
@MainActor
public final class EffectOwner<Key: Hashable & Sendable> {
    /// What `run` does when a key is already occupied by a running effect.
    ///
    /// Ownership: a value type, no ownership semantics. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public enum Conflict: Sendable {
        /// Cancel the running effect for this key and start the new one immediately —
        /// "refresh", "retry".
        case restart
        /// Leave the running effect alone and do not start a new one; `run` returns `false`
        /// — "initial" (already-in-flight is not duplicated), "loadMore" (one page request
        /// per demand, repeated events deduplicate).
        case ignoreIfRunning
    }

    private struct Slot {
        var task: Task<Void, Never>
        var generation: UInt64
    }

    private var slots: [Key: Slot] = [:]
    private var nextGeneration: UInt64 = 0

    /// Creates an owner with no running effects.
    ///
    /// Ownership: the caller owns the instance. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Starts `operation` under `key`, applying its result through `apply` only if this
    /// specific run is still the current one for `key` when `operation` finishes — not
    /// cancelled by `cancel(_:)`/`cancelAll()`, and not superseded by a later `run(key:...)`
    /// (whose own completion, in turn, gets the same guarantee: "запрос A завершается после
    /// B; применяется B, A освобождается" holds regardless of which finishes first).
    /// `operation` itself should still check `Task.isCancelled` before doing expensive work
    /// it can skip — this guarantee is about *applying results*, not about making a
    /// cancelled operation stop instantly.
    ///
    /// Returns `false` without starting anything when `onConflict` is `.ignoreIfRunning` and
    /// `key` already has a running effect — the caller observes this instead of a silently
    /// dropped request (P6.2: "overflow... видимо"). Returns `true` otherwise.
    ///
    /// Ownership: retains `operation`/`apply` only for the lifetime of this run. Isolation:
    /// MainActor for `apply` and for checking/mutating this owner's state; `operation` runs
    /// on whatever executor it itself awaits into. Errors: none — encode failure in `Result`.
    /// Cancellation: `cancel(key)`, `cancelAll()`, or a later `.restart` run on the same key.
    @discardableResult
    public func run<Result: Sendable>(
        _ key: Key,
        onConflict: Conflict = .restart,
        operation: @escaping @Sendable () async -> Result,
        apply: @escaping @MainActor (Result) -> Void
    ) -> Bool {
        if slots[key] != nil {
            switch onConflict {
            case .ignoreIfRunning:
                return false
            case .restart:
                slots[key]?.task.cancel()
            }
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        let task = Task { @MainActor [weak self] in
            let result = await operation()
            guard let self, self.slots[key]?.generation == generation else { return }
            self.slots[key] = nil
            apply(result)
        }
        slots[key] = Slot(task: task, generation: generation)
        return true
    }

    /// Whether `key` currently has a running (not yet completed, not cancelled) effect.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func isRunning(_ key: Key) -> Bool {
        slots[key] != nil
    }

    /// Cancels the running effect for `key`, if any. Its result, if it arrives later, is
    /// discarded by `run`'s own generation check — safe to call whether or not one is
    /// running. Leaves `key` immediately available for a new `run` (a retry after this is
    /// never refused as "already running").
    ///
    /// Ownership: releases this owner's reference to the task. Isolation: MainActor. Errors:
    /// none. Cancellation: this is the cancellation.
    public func cancel(_ key: Key) {
        slots[key]?.task.cancel()
        slots[key] = nil
    }

    /// Cancels every running effect — the whole-scope teardown a view session calls on
    /// detach (P6.7: "View-owned запрос отменяется при завершении его session").
    ///
    /// Ownership: releases every tracked task. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation, for every key at once.
    public func cancelAll() {
        for slot in slots.values {
            slot.task.cancel()
        }
        slots.removeAll()
    }

    deinit {
        // `Task.cancel()` is not actor-isolated and safe from any context (same reasoning as
        // `FluxStateBinding`'s deinit) — a defensive fallback; the intended path is an
        // explicit `cancelAll()` from whoever owns this instance's lifetime.
        for slot in slots.values {
            slot.task.cancel()
        }
    }
}
