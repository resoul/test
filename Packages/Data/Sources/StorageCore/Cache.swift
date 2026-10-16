import Foundation

/// What a cache knows about a key.
public enum CacheLookup<Value: Sendable>: Sendable {
    /// A stored value that has not expired.
    case hit(Value, storedAt: Date)
    /// A stored value whose time to live has run out. It is still held, so a screen can show it
    /// while fresh data is loaded; whether it is good enough is the caller's decision.
    case stale(Value, storedAt: Date)
    /// Nothing usable is stored: the key was never written, was removed or evicted, or was
    /// written under another ``CachePolicy/version``.
    case miss

    /// The same lookup with its value converted; a miss stays a miss.
    public func map<Other: Sendable>(_ transform: (Value) throws -> Other) rethrows
        -> CacheLookup<Other>
    {
        switch self {
        case .hit(let value, let date): .hit(try transform(value), storedAt: date)
        case .stale(let value, let date): .stale(try transform(value), storedAt: date)
        case .miss: .miss
        }
    }
}

/// Why a cache operation failed. A miss and a stale value are not failures: see ``CacheLookup``.
public enum CacheError: Error, Sendable, Equatable {
    /// The storage under the cache failed; the case says how.
    case file(FileError)
    /// A stored entry is damaged. Thrown only under ``CorruptionHandling/throwError``; the
    /// damaged entry has been removed by then, so asking again is a miss.
    case corrupted(key: String, reason: String)
    /// The value alone is bigger than the cache may hold, so it was not stored.
    case entryTooLarge(size: Int64, limit: Int64)
}

/// What a cache does when a stored entry turns out to be damaged.
public enum CorruptionHandling: Sendable {
    /// Remove the entry, report it to the diagnostics, and answer as for a miss. A cache holds
    /// only what can be rebuilt, so this is the right default.
    case treatAsMiss
    /// Remove the entry and throw ``CacheError/corrupted(key:reason:)``.
    case throwError
}

/// Limits and rules for one cache.
public struct CachePolicy: Sendable {
    /// The most bytes of values the cache keeps; the least recently used entries go first, after
    /// the expired ones. `nil` means no limit.
    public var maxBytes: Int64?
    /// How long a value stays fresh after it is stored, in seconds. `nil` means for ever. A call
    /// to `set` can give a value its own time.
    public var timeToLive: TimeInterval?
    /// The format of what is stored. Entries written under another version are not read: change it
    /// when the meaning of the bytes changes, and the old entries are dropped instead of misread.
    /// Only a cache that outlives the process cares.
    public var version: Int
    public var corruption: CorruptionHandling

    public init(
        maxBytes: Int64? = nil,
        timeToLive: TimeInterval? = nil,
        version: Int = 1,
        corruption: CorruptionHandling = .treatAsMiss
    ) {
        self.maxBytes = maxBytes
        self.timeToLive = timeToLive
        self.version = version
        self.corruption = corruption
    }
}

/// Something worth knowing that the cache handled by itself.
public enum CacheEvent: Sendable, Equatable {
    /// Entries were removed to make room.
    case evicted(entries: Int, bytes: Int64)
    /// An entry was damaged and has been removed; `reason` says what was wrong with it.
    case corrupted(key: String?, reason: String)
}

/// A place that keeps byte values by key for a while, and may forget them.
///
/// A cache is `Sendable` and serialises its own state, so calls may come from any isolation. A
/// stored value is not promised to stay: it can expire, be evicted for space, or be lost with the
/// storage under it, and a miss is a normal answer. Keep in a cache only what can be rebuilt;
/// anything else belongs in a file store or the database.
///
/// Cancelling the calling task stops an operation that is waiting for storage; what it had
/// already written stays written.
public protocol Cache: Sendable {
    func get(_ key: String) async throws(CacheError) -> CacheLookup<Data>

    /// Stores `data` under `key`, replacing what was there, and makes room if the policy's size
    /// limit needs it.
    ///
    /// - Parameter timeToLive: How long the value stays fresh, in seconds; the policy's own
    ///   time when `nil`.
    /// - Throws: ``CacheError/entryTooLarge(size:limit:)`` for a value over the size limit.
    func set(_ data: Data, for key: String, timeToLive: TimeInterval?) async throws(CacheError)

    /// Removes the value of `key`. Removing nothing is not an error.
    ///
    /// - Returns: Whether something was removed.
    @discardableResult
    func remove(_ key: String) async throws(CacheError) -> Bool

    /// Removes everything the cache holds.
    func removeAll() async throws(CacheError)

    /// Removes the entries whose time has run out.
    ///
    /// - Returns: How many were removed.
    @discardableResult
    func removeExpired() async throws(CacheError) -> Int
}

extension Cache {
    public func set(_ data: Data, for key: String) async throws(CacheError) {
        try await set(data, for: key, timeToLive: nil)
    }

    /// The value stored under `key`, decoded from JSON.
    ///
    /// A stored value that does not decode — written by an older shape of `Value`, say — is
    /// removed and reported as a miss: a cache is rebuilt, not repaired. Change the policy's
    /// ``CachePolicy/version`` when the shape changes on purpose.
    public func get<Value: Decodable & Sendable>(_ type: Value.Type, for key: String)
        async throws(CacheError) -> CacheLookup<Value>
    {
        let lookup = try await get(key)
        do {
            return try lookup.map { try JSONDecoder().decode(Value.self, from: $0) }
        } catch {
            try await remove(key)
            return .miss
        }
    }

    /// Stores `value` as JSON under `key`.
    ///
    /// - Throws: The errors of ``set(_:for:timeToLive:)``; a value that cannot be encoded is
    ///   ``CacheError/corrupted(key:reason:)``, with nothing stored.
    public func set<Value: Encodable & Sendable>(
        _ value: Value,
        for key: String,
        timeToLive: TimeInterval? = nil
    ) async throws(CacheError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw .corrupted(key: key, reason: "the value cannot be encoded: \(error)")
        }
        try await set(data, for: key, timeToLive: timeToLive)
    }
}
