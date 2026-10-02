import Foundation

/// Loads values through a ``Cache``: a stored fresh value is returned at once, and otherwise
/// the value is fetched, stored, and returned.
///
/// **Shared loads.** Callers asking for the same key while a fetch is running share it; the
/// fetch runs once. Each caller waits independently: cancelling one caller's task makes that
/// call throw `CancellationError` and leaves the others waiting. The fetch itself is cancelled
/// only when no caller is left waiting for it.
///
/// **Clearing.** ``invalidate()`` is for the end of an account or a session. It cancels every
/// load that is running — their callers throw `CancellationError` — and clears the cache. A fetch
/// that does not stop in time and finishes afterwards stores nothing, and a write that was already
/// under way is taken back: a late answer does not bring back what was cleared.
///
/// A failed fetch is not stored, and every caller waiting for it gets the same error. A stale
/// value counts as a miss here; to show a stale value while loading, read the cache first.
public actor CachedLoader {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]
    }

    private let cache: any Cache
    private var flights: [String: Flight] = [:]

    public init(cache: any Cache) {
        self.cache = cache
    }

    /// The value for `key`, from the cache when it is fresh there, otherwise from `fetch`.
    ///
    /// - Parameters:
    ///   - timeToLive: How long the fetched value stays fresh; the cache policy's time when `nil`.
    ///   - fetch: Produces the value. It runs in a task of its own, not in the caller's, and is
    ///     asked to stop when no caller is waiting any more or the loader is invalidated.
    /// - Throws: The error of `fetch`, `CancellationError`, or ``CacheError`` when the cache
    ///   itself fails to answer. A cache that fails to *store* the fetched value is not an error:
    ///   the caller still gets the value.
    public func value(
        for key: String,
        timeToLive: TimeInterval? = nil,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if case .hit(let data, _) = try await cache.get(key) { return data }

        // The cache read suspended, so another call may have started the fetch meanwhile.
        if flights[key] == nil { start(key, timeToLive: timeToLive, fetch: fetch) }
        return try await wait(for: key)
    }

    /// Removes the value of `key` from the cache and stops a load of it that is running; the
    /// callers waiting for it throw `CancellationError`.
    public func remove(_ key: String) async throws(CacheError) {
        cancelFlight(key)
        try await cache.remove(key)
    }

    /// Cancels every running load and clears the cache. See the type's documentation.
    public func invalidate() async throws(CacheError) {
        for key in Array(flights.keys) { cancelFlight(key) }
        try await cache.removeAll()
    }

    /// How many callers are waiting for the load of `key`; for tests, which need to know that
    /// every caller has joined before they let the fetch finish.
    func waiterCount(for key: String) -> Int { flights[key]?.waiters.count ?? 0 }

    private func start(
        _ key: String,
        timeToLive: TimeInterval?,
        fetch: @escaping @Sendable () async throws -> Data
    ) {
        let flightID = UUID()
        let task = Task { [weak self] in
            let result: Result<Data, any Error>
            do {
                result = .success(try await fetch())
            } catch {
                result = .failure(error)
            }
            await self?.finish(key, flight: flightID, timeToLive: timeToLive, result: result)
        }
        flights[key] = Flight(id: flightID, task: task)
    }

    private func finish(
        _ key: String,
        flight flightID: UUID,
        timeToLive: TimeInterval?,
        result: Result<Data, any Error>
    ) async {
        // A flight that was cancelled has nothing left to deliver or store.
        guard flights[key]?.id == flightID else { return }

        if case .success(let data) = result {
            // The flight stays registered during the write, so callers that arrive now join it
            // and one that is cancelled now is still found.
            try? await cache.set(data, for: key, timeToLive: timeToLive)
            if flights[key]?.id != flightID {
                // The load was cancelled or the loader cleared while the value was being
                // written, so the write must not outlive that: take it back.
                _ = try? await cache.remove(key)
                return
            }
        }
        guard let current = flights.removeValue(forKey: key) else { return }

        for waiter in current.waiters.values { waiter.resume(with: result) }
    }

    private func wait(for key: String) async throws -> Data {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                flights[key]?.waiters[waiter] = continuation
                // A task that was cancelled before it got here has already run its handler.
                if Task.isCancelled { dropWaiter(waiter, of: key) }
            }
        } onCancel: {
            Task { await self.dropWaiter(waiter, of: key) }
        }
    }

    private func dropWaiter(_ waiter: UUID, of key: String) {
        guard var flight = flights[key],
            let continuation = flight.waiters.removeValue(forKey: waiter)
        else { return }

        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights[key] = nil
        } else {
            flights[key] = flight
        }
    }

    private func cancelFlight(_ key: String) {
        guard let flight = flights.removeValue(forKey: key) else { return }

        flight.task.cancel()
        for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
    }
}
