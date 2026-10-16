import Foundation

/// What the callers sharing one load want of it, taken together: a load that several callers
/// wait for reads it while it runs — to set its priority by the most urgent of them, say.
///
/// One demand is made for each load when it starts. Callers are added as they join and removed
/// as they leave, before the load ends or after; the load reads the demand from its own task, so
/// a conforming type serialises its own state.
public protocol LoadDemand: AnyObject, Sendable {
    /// What one caller brings to the load.
    associatedtype Want: Sendable

    /// A demand with no callers yet.
    init()

    /// A caller joined the load with `want`.
    func add(_ want: Want, for caller: UInt64)

    /// The caller left the load: it was cancelled, or the load ended for everyone.
    func remove(_ caller: UInt64)
}

/// The demand of loads whose callers all want them alike.
public final class EqualDemand: LoadDemand {
    public init() {}

    public func add(_ want: Void, for caller: UInt64) {}

    public func remove(_ caller: UInt64) {}
}

/// Runs one load per key for all the callers that ask for it while it runs.
///
/// **Sharing.** The first caller of a key starts the load; callers that come while it runs wait
/// for the same one, and all get its value or its error. A finished load is forgotten: the next
/// caller starts a new one, so a cache in front of the loads decides what is reused.
///
/// **Cancellation.** Each caller waits on its own: cancelling one caller's task makes its call
/// throw `CancellationError` at once and leaves the others waiting. The load itself is cancelled
/// when no caller is left waiting for it, and by ``cancel(_:)`` and ``cancelAll()``, which also
/// release its callers with `CancellationError`. A cancelled load is only asked to stop: what it
/// already did — a file written, a cache entry stored — stays, and the load can check
/// `Task.isCancelled` after such a step to take it back.
///
/// The load runs in a task of its own, not in any caller's, at the priority of the caller that
/// started it.
public actor SharedLoads<Key: Hashable & Sendable, Value: Sendable, Demand: LoadDemand> {
    private struct Load {
        let id: UInt64
        let task: Task<Void, Never>
        let demand: Demand
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
    }

    private var loads: [Key: Load] = [:]
    private var nextID: UInt64 = 0

    /// Creates an owner of loads, with none running.
    public init() {}

    /// The value of the load of `key`: the one running, or one `start` begins.
    ///
    /// - Parameters:
    ///   - want: What this caller wants of the load; it joins the load's demand while it waits.
    ///   - start: Runs the load, reading the demand of all its callers. Called only when no load
    ///     of `key` is running, in a task of its own.
    /// - Throws: The load's error, or `CancellationError` when this caller or the load is
    ///   cancelled.
    public func value(
        for key: Key,
        want: Demand.Want,
        start: @escaping @Sendable (Demand) async throws -> Value
    ) async throws -> Value {
        nextID &+= 1
        let waiter = nextID
        let load = loads[key] ?? begin(key, start: start)
        load.demand.add(want, for: waiter)
        return try await wait(waiter, for: key, load: load.id)
    }

    /// The value of the load of `key`, for loads whose callers all want them alike.
    public func value(
        for key: Key,
        start: @escaping @Sendable () async throws -> Value
    ) async throws -> Value where Demand == EqualDemand {
        try await value(for: key, want: ()) { _ in try await start() }
    }

    /// Cancels the load of `key`, if one runs; its callers throw `CancellationError`.
    public func cancel(_ key: Key) {
        guard let load = loads.removeValue(forKey: key) else { return }

        end(load, with: .failure(CancellationError()))
        load.task.cancel()
    }

    /// Cancels every running load; their callers throw `CancellationError`.
    public func cancelAll() {
        for key in Array(loads.keys) { cancel(key) }
    }

    /// How many callers wait for the load of `key`; zero when none runs.
    public func waiterCount(for key: Key) -> Int {
        loads[key]?.waiters.count ?? 0
    }

    private func begin(
        _ key: Key,
        start: @escaping @Sendable (Demand) async throws -> Value
    ) -> Load {
        nextID &+= 1
        let id = nextID
        let demand = Demand()
        let task = Task { [weak self] in
            let result: Result<Value, any Error>
            do {
                result = .success(try await start(demand))
            } catch {
                result = .failure(error)
            }
            await self?.finish(key, load: id, with: result)
        }
        let load = Load(id: id, task: task, demand: demand)
        loads[key] = load
        return load
    }

    private func finish(_ key: Key, load id: UInt64, with result: Result<Value, any Error>) {
        // A load that was cancelled has already released its callers.
        guard loads[key]?.id == id, let load = loads.removeValue(forKey: key) else { return }

        end(load, with: result)
    }

    private func end(_ load: Load, with result: Result<Value, any Error>) {
        for (waiter, continuation) in load.waiters {
            load.demand.remove(waiter)
            continuation.resume(with: result)
        }
    }

    private func wait(_ waiter: UInt64, for key: Key, load id: UInt64) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard loads[key]?.id == id else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                loads[key]?.waiters[waiter] = continuation
                // A task cancelled before it got here has already run its handler, which found
                // nothing to drop.
                if Task.isCancelled { drop(waiter, of: key) }
            }
        } onCancel: {
            Task { await self.drop(waiter, of: key) }
        }
    }

    private func drop(_ waiter: UInt64, of key: Key) {
        guard var load = loads[key], let continuation = load.waiters.removeValue(forKey: waiter)
        else { return }

        load.demand.remove(waiter)
        continuation.resume(throwing: CancellationError())
        if load.waiters.isEmpty {
            load.task.cancel()
            loads[key] = nil
        } else {
            loads[key] = load
        }
    }
}
