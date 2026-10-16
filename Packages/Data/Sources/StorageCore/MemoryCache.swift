import Foundation

/// A ``Cache`` that keeps values in memory. Nothing survives the process or the object.
///
/// When the policy's size limit is passed, expired values go first, oldest expiry first, then
/// the least recently read or written. Finding the victim looks at every entry, which is fine for
/// the hundreds or few thousands of entries a screen's data makes; a cache of a very large number
/// of small entries wants a different structure.
public actor MemoryCache: Cache {
    private struct Entry {
        var data: Data
        var storedAt: Date
        var expiresAt: Date?
        var lastUse: UInt64
    }

    private let policy: CachePolicy
    private let now: @Sendable () -> Date
    private let diagnostics: (@Sendable (CacheEvent) -> Void)?
    private var entries: [String: Entry] = [:]
    private var byteCount: Int64 = 0
    private var tick: UInt64 = 0

    /// - Parameters:
    ///   - policy: Limits and time to live. Its version and corruption rule do not apply to
    ///     memory.
    ///   - now: The clock that decides what has expired; tests pass their own.
    ///   - diagnostics: Told when entries are evicted. Called on the cache's executor, so keep it
    ///     short.
    public init(
        policy: CachePolicy = CachePolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: (@Sendable (CacheEvent) -> Void)? = nil
    ) {
        self.policy = policy
        self.now = now
        self.diagnostics = diagnostics
    }

    public func get(_ key: String) -> CacheLookup<Data> {
        guard var entry = entries[key] else { return .miss }

        tick += 1
        entry.lastUse = tick
        entries[key] = entry
        if let expiresAt = entry.expiresAt, expiresAt <= now() {
            return .stale(entry.data, storedAt: entry.storedAt)
        }
        return .hit(entry.data, storedAt: entry.storedAt)
    }

    public func set(_ data: Data, for key: String, timeToLive: TimeInterval?) throws(CacheError) {
        let size = Int64(data.count)
        if let limit = policy.maxBytes, size > limit {
            throw .entryTooLarge(size: size, limit: limit)
        }
        let date = now()
        let lifetime = timeToLive ?? policy.timeToLive
        byteCount -= Int64(entries[key]?.data.count ?? 0)
        tick += 1
        entries[key] = Entry(
            data: data,
            storedAt: date,
            expiresAt: lifetime.map { date.addingTimeInterval($0) },
            lastUse: tick
        )
        byteCount += size
        evictIfNeeded(keeping: key)
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
        guard let entry = entries.removeValue(forKey: key) else { return false }

        byteCount -= Int64(entry.data.count)
        return true
    }

    public func removeAll() {
        entries.removeAll()
        byteCount = 0
    }

    @discardableResult
    public func removeExpired() -> Int {
        let date = now()
        let expired = entries.filter { $0.value.expiresAt.map { $0 <= date } ?? false }
        for key in expired.keys { remove(key) }
        return expired.count
    }

    /// Makes the cache fit its size limit. The entry just written is never the victim, so a
    /// value that fits alone is kept even when it pushes everything else out.
    private func evictIfNeeded(keeping newest: String) {
        guard let limit = policy.maxBytes, byteCount > limit else { return }

        let date = now()
        var count = 0
        var bytes: Int64 = 0
        while byteCount > limit {
            let candidates = entries.filter { $0.key != newest }
            let victim =
                candidates.filter { $0.value.expiresAt.map { $0 <= date } ?? false }
                .min { $0.value.expiresAt! < $1.value.expiresAt! }
                ?? candidates.min { $0.value.lastUse < $1.value.lastUse }
            guard let victim else { break }

            bytes += Int64(victim.value.data.count)
            count += 1
            remove(victim.key)
        }
        if count > 0 { diagnostics?(.evicted(entries: count, bytes: bytes)) }
    }
}
