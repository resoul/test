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
    private let cache: any Cache
    private let loads = SharedLoads<String, Data, EqualDemand>()

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

        let cache = cache
        return try await loads.value(for: key) {
            let data = try await fetch()
            // A load cancelled by now — every caller left, or the loader was cleared — stores
            // nothing.
            try Task.checkCancellation()
            try? await cache.set(data, for: key, timeToLive: timeToLive)
            // Cancelled while the value was being written: the clearing has run or is about to,
            // and the write must not outlive it, so it is taken back.
            if Task.isCancelled {
                _ = try? await cache.remove(key)
                throw CancellationError()
            }
            return data
        }
    }

    /// Removes the value of `key` from the cache and stops a load of it that is running; the
    /// callers waiting for it throw `CancellationError`.
    public func remove(_ key: String) async throws(CacheError) {
        await loads.cancel(key)
        try await cache.remove(key)
    }

    /// Cancels every running load and clears the cache. See the type's documentation.
    public func invalidate() async throws(CacheError) {
        await loads.cancelAll()
        try await cache.removeAll()
    }

    /// How many callers are waiting for the load of `key`; for tests, which need to know that
    /// every caller has joined before they let the fetch finish.
    func waiterCount(for key: String) async -> Int { await loads.waiterCount(for: key) }
}
