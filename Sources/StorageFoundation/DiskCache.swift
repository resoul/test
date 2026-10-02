import CryptoKit
import Foundation
import StorageCore

/// A ``Cache`` that keeps values in files of a ``FileStore``, so it survives a restart.
///
/// The cache owns the store it is given: everything in it is the cache's, and ``removeAll()``
/// empties it. Give it a store of its own — a directory under the system's caches location is the
/// usual place — and make one cache per user or account if their data must not mix, so that
/// signing out is a ``removeAll()``.
///
/// **Entries.** A key is hashed into a file name that also records the policy version and the
/// moment the value expires, so one listing of the store tells what is there, how big it is and
/// what has run out, without reading any file. The file starts with a header holding the key
/// and a checksum of the value. A file that is cut short, altered, or does not start with the
/// header is damaged; see ``CorruptionHandling``. Files whose version differs from the policy's
/// are deleted when the cache first looks at the store.
///
/// **Size limit.** The limit counts what is written: the value plus a header of about forty bytes
/// and the key. When it is passed, expired entries go first, then the least recently used ones.
/// Use is remembered in memory, so after a restart the order is the order of writing.
///
/// **Concurrency.** Operations run one at a time in the order they arrive, from the first
/// suspension to the last, so a write and an eviction never see each other half done.
public actor DiskCache: Cache {
    private struct Entry {
        var name: FilePath
        var size: Int64
        var storedAt: Date
        var expiresAt: Date?
        var lastUse: UInt64
    }

    private static let magic = Data("ESCH".utf8)
    private static let headerOverhead = 4 + 4 + 32

    private let store: any FileStore
    private let policy: CachePolicy
    private let now: @Sendable () -> Date
    private let diagnostics: (@Sendable (CacheEvent) -> Void)?
    /// What the store holds, by file stem. Filled from the store on first use.
    private var index: [String: Entry] = [:]
    private var isIndexed = false
    private var tick: UInt64 = 0
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - store: Where the files live; owned by the cache from now on.
    ///   - policy: Limits, time to live, format version and what to do with damaged entries.
    ///   - now: The clock that decides what has expired; tests pass their own.
    ///   - diagnostics: Told about evictions and damaged entries. Called on the cache's executor,
    ///     so keep it short.
    public init(
        store: any FileStore,
        policy: CachePolicy = CachePolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: (@Sendable (CacheEvent) -> Void)? = nil
    ) {
        self.store = store
        self.policy = policy
        self.now = now
        self.diagnostics = diagnostics
    }

    public func get(_ key: String) async throws(CacheError) -> CacheLookup<Data> {
        await acquire()
        defer { release() }
        try await loadIndex()

        let stem = Self.stem(of: key)
        guard var entry = index[stem] else { return .miss }

        let blob: Data
        do {
            blob = try await store.read(entry.name)
        } catch .notFound {
            // Removed behind our back, for example by the system clearing caches.
            index[stem] = nil
            return .miss
        } catch {
            throw .file(error)
        }
        let value: Data
        switch Self.decode(blob, key: key) {
        case .success(let decoded): value = decoded
        case .failure(let problem):
            if problem == .otherKey { return .miss }

            return try await discardDamaged(stem, key: key, reason: problem.description)
        }
        tick += 1
        entry.lastUse = tick
        index[stem] = entry
        if let expiresAt = entry.expiresAt, expiresAt <= now() {
            return .stale(value, storedAt: entry.storedAt)
        }
        return .hit(value, storedAt: entry.storedAt)
    }

    public func set(_ data: Data, for key: String, timeToLive: TimeInterval?)
        async throws(CacheError)
    {
        await acquire()
        defer { release() }
        try await loadIndex()

        let blob = Self.encode(data, key: key)
        let size = Int64(blob.count)
        if let limit = policy.maxBytes, size > limit {
            throw .entryTooLarge(size: size, limit: limit)
        }
        let date = now()
        let expiresAt = (timeToLive ?? policy.timeToLive).map { date.addingTimeInterval($0) }
        let stem = Self.stem(of: key)
        let name = Self.fileName(stem: stem, version: policy.version, expiresAt: expiresAt)
        do {
            try await store.write(blob, to: name)
        } catch {
            throw .file(error)
        }
        // A different time to live is a different file name, so the old file is now garbage.
        if let previous = index[stem], previous.name != name {
            _ = try? await store.remove(previous.name)
        }
        tick += 1
        index[stem] = Entry(
            name: name,
            size: size,
            storedAt: date,
            expiresAt: expiresAt,
            lastUse: tick
        )
        try await evictIfNeeded(keeping: stem)
    }

    @discardableResult
    public func remove(_ key: String) async throws(CacheError) -> Bool {
        await acquire()
        defer { release() }
        try await loadIndex()

        guard let entry = index.removeValue(forKey: Self.stem(of: key)) else { return false }

        do {
            try await store.remove(entry.name)
        } catch {
            throw .file(error)
        }
        return true
    }

    public func removeAll() async throws(CacheError) {
        await acquire()
        defer { release() }

        do {
            for item in try await store.list(nil) { try await store.remove(item.path) }
        } catch {
            throw .file(error)
        }
        index = [:]
        isIndexed = true
    }

    @discardableResult
    public func removeExpired() async throws(CacheError) -> Int {
        await acquire()
        defer { release() }
        try await loadIndex()

        let date = now()
        let expired = index.filter { $0.value.expiresAt.map { $0 <= date } ?? false }
        for (stem, entry) in expired {
            do {
                try await store.remove(entry.name)
            } catch {
                throw .file(error)
            }
            index[stem] = nil
        }
        return expired.count
    }

    // MARK: Serialising operations

    /// Waits for the operations ahead and takes the turn. The turn is handed on directly, so no
    /// newcomer can slip in between two queued operations.
    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Index

    /// Reads what the store holds into the index, once. Entries of another version are deleted;
    /// names that are not ours are left alone and not counted.
    private func loadIndex() async throws(CacheError) {
        guard !isIndexed else { return }

        let items: [FileEntry]
        do {
            items = try await store.list(nil)
        } catch {
            throw .file(error)
        }
        // Oldest first, so the first eviction after a restart takes the oldest write.
        for item in items.sorted(by: {
            ($0.metadata.modificationDate ?? .distantPast)
                < ($1.metadata.modificationDate ?? .distantPast)
        }) where !item.metadata.isDirectory {
            guard let parsed = Self.parse(item.path.name) else { continue }

            if parsed.version != policy.version {
                _ = try? await store.remove(item.path)
                continue
            }
            tick += 1
            index[parsed.stem] = Entry(
                name: item.path,
                size: item.metadata.size,
                storedAt: item.metadata.modificationDate ?? .distantPast,
                expiresAt: parsed.expiresAt,
                lastUse: tick
            )
        }
        isIndexed = true
    }

    private func evictIfNeeded(keeping newest: String) async throws(CacheError) {
        guard let limit = policy.maxBytes else { return }

        var total = index.values.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }

        let date = now()
        var count = 0
        var bytes: Int64 = 0
        defer { if count > 0 { diagnostics?(.evicted(entries: count, bytes: bytes)) } }
        while total > limit {
            let candidates = index.filter { $0.key != newest }
            let victim =
                candidates.filter { $0.value.expiresAt.map { $0 <= date } ?? false }
                .min { $0.value.expiresAt! < $1.value.expiresAt! }
                ?? candidates.min { $0.value.lastUse < $1.value.lastUse }
            guard let victim else { return }

            do {
                try await store.remove(victim.value.name)
            } catch {
                throw .file(error)
            }
            index[victim.key] = nil
            total -= victim.value.size
            bytes += victim.value.size
            count += 1
        }
    }

    private func discardDamaged(_ stem: String, key: String, reason: String)
        async throws(CacheError)
        -> CacheLookup<Data>
    {
        if let entry = index.removeValue(forKey: stem) { _ = try? await store.remove(entry.name) }
        diagnostics?(.corrupted(key: key, reason: reason))
        switch policy.corruption {
        case .treatAsMiss: return .miss
        case .throwError: throw .corrupted(key: key, reason: reason)
        }
    }

    // MARK: File names and format

    /// 32 hex digits of the key's SHA-256: names that are safe, short and evenly spread.
    private static func stem(of key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `<stem>.<version>.<expiry in milliseconds since 1970, or n for never>`
    private static func fileName(stem: String, version: Int, expiresAt: Date?) -> FilePath {
        let expiry = expiresAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "n"
        return try! FilePath("\(stem).\(version).\(expiry)")
    }

    private static func parse(_ name: String) -> (stem: String, version: Int, expiresAt: Date?)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 32,
            parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            let version = Int(parts[1])
        else { return nil }

        if parts[2] == "n" { return (String(parts[0]), version, nil) }
        guard let milliseconds = Int64(parts[2]) else { return nil }

        return (String(parts[0]), version, Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// `ESCH`, the key's length in four bytes, the key, the value's SHA-256, the value.
    private static func encode(_ value: Data, key: String) -> Data {
        let keyBytes = Data(key.utf8)
        var blob = magic
        withUnsafeBytes(of: UInt32(keyBytes.count).bigEndian) { blob.append(contentsOf: $0) }
        blob.append(keyBytes)
        blob.append(contentsOf: SHA256.hash(data: value))
        blob.append(value)
        return blob
    }

    private enum Problem: Error, Equatable, CustomStringConvertible {
        case notOurs, truncated, checksum
        /// A different key hashed to the same name: not damage, only a collision.
        case otherKey

        var description: String {
            switch self {
            case .notOurs: "the file does not start with the cache header"
            case .truncated: "the file is shorter than its header says"
            case .checksum: "the value does not match its checksum"
            case .otherKey: "the file belongs to another key"
            }
        }
    }

    private static func decode(_ blob: Data, key: String) -> Result<Data, Problem> {
        guard blob.count >= headerOverhead else { return .failure(.truncated) }
        guard blob.prefix(4) == magic else { return .failure(.notOurs) }

        let keyLength = blob.subdata(in: 4..<8).reduce(0) { $0 << 8 | Int($1) }
        let valueStart = 8 + keyLength + 32
        guard blob.count >= valueStart else { return .failure(.truncated) }

        guard blob.subdata(in: 8..<(8 + keyLength)) == Data(key.utf8) else {
            return .failure(.otherKey)
        }
        let value = blob.subdata(in: valueStart..<blob.count)
        guard Data(SHA256.hash(data: value)) == blob.subdata(in: (8 + keyLength)..<valueStart)
        else { return .failure(.checksum) }

        return .success(value)
    }
}
