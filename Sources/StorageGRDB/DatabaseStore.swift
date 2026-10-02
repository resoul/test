import Foundation
import GRDB

/// Where a database lives.
public enum DatabaseLocation: Sendable {
    /// A database that exists only as long as the store, for tests and previews.
    case inMemory
    /// A database in a file. Missing directories above it are created; the file itself is created
    /// by SQLite when it does not exist yet.
    case file(URL)
}

/// An SQLite database, opened and migrated, with transactions and observation.
///
/// SQL and records are GRDB's own: a closure given to ``read(_:)``, ``write(_:)`` or
/// ``observe(_:)`` receives a GRDB `Database` and uses it directly. What leaves the closure must be
/// `Sendable` — a value or a struct of values, not a `Row`, a cursor or the connection. Do not
/// keep the `Database` beyond the closure.
///
/// All access to one store goes through one connection, one closure at a time, so a write never
/// overlaps another access. Do not wait for the network, hop to the main actor, or suspend inside
/// a closure: the connection is held until it returns.
///
/// The actor owns the connection and the observation tasks it started. ``close()`` ends both;
/// releasing the last reference to the store does the same.
public actor DatabaseStore {
    private let queue: DatabaseQueue
    private var isClosed = false
    private var observers: [UUID: Task<Void, Never>] = [:]

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    // MARK: Opening

    /// Opens the database and runs the migrations it has not run yet. The store is returned only
    /// when the schema is complete.
    ///
    /// A failure leaves the database as it was: a file that is not a database is not replaced by
    /// an empty one, a failed migration is rolled back, and nothing is ever erased to make the
    /// schema fit.
    ///
    /// - Parameters:
    ///   - location: Where the database lives.
    ///   - migrations: The whole history, oldest first. Add to the end; never edit or remove one
    ///     that has shipped.
    /// - Throws: ``DatabaseStoreError`` — see its cases for what each failure leaves behind.
    public static func open(_ location: DatabaseLocation, migrations: [DatabaseMigration])
        async throws(DatabaseStoreError) -> DatabaseStore
    {
        var seen: Set<String> = []
        for migration in migrations where !seen.insert(migration.name).inserted {
            throw .duplicateMigration(name: migration.name)
        }

        let queue: DatabaseQueue
        do {
            switch location {
            case .inMemory:
                queue = try DatabaseQueue()
            case .file(let url):
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                queue = try DatabaseQueue(path: url.path)
            }
        } catch {
            throw .openFailed(underlying: error)
        }

        let migrator = makeMigrator(migrations)
        let known = seen
        do {
            // Reading the applied names also proves that the file is a database at all.
            let unknown = try await queue.read { db in
                try migrator.appliedIdentifiers(db).filter { !known.contains($0) }
            }
            if !unknown.isEmpty {
                try? queue.close()
                throw DatabaseStoreError.newerThanApp(unknownMigrations: unknown.sorted())
            }
            // Migrating waits for the connection and runs SQL, so it is kept off the cooperative
            // pool.
            try await Blocking.run { try migrator.migrate(queue) }
        } catch let failure as FailedMigration {
            try? queue.close()
            throw .migrationFailed(name: failure.name, underlying: failure.underlying)
        } catch let error as DatabaseStoreError {
            throw error
        } catch {
            try? queue.close()
            throw .openFailed(underlying: error)
        }
        return DatabaseStore(queue: queue)
    }

    // MARK: Reading and writing

    /// Runs `body` with a read-only view of the database and returns what it returns.
    ///
    /// - Throws: ``DatabaseStoreError/closed``; `CancellationError` when the task is cancelled
    ///   before the read finishes; otherwise whatever `body` or SQLite threw.
    public func read<Result: Sendable>(_ body: @escaping @Sendable (Database) throws -> Result)
        async throws -> Result
    {
        guard !isClosed else { throw DatabaseStoreError.closed }

        return try await queue.read(body)
    }

    /// Runs `body` in one transaction and returns what it returns. Either all of what `body`
    /// wrote is stored, or none of it is.
    ///
    /// **Cancellation.** Cancelling the task makes GRDB cancel the database access. If the
    /// transaction has not committed yet — the call is still waiting for the connection, or `body`
    /// is running — the next statement, the `COMMIT` included, throws `CancellationError`: the
    /// transaction is rolled back, nothing is written, and the call throws. `body` itself is not
    /// interrupted between statements, so it runs on until it runs one. Once the transaction has
    /// committed, the write stays and the call returns normally, even if the task is cancelled at
    /// that moment: a stored write is never reported as if it had not happened. This is GRDB's
    /// behaviour, pinned by the exact version in the package manifest and by this package's tests.
    ///
    /// - Throws: ``DatabaseStoreError/closed``; `CancellationError` as above; otherwise whatever
    ///   `body` or SQLite threw, in which case the transaction is rolled back.
    public func write<Result: Sendable>(_ body: @escaping @Sendable (Database) throws -> Result)
        async throws -> Result
    {
        guard !isClosed else { throw DatabaseStoreError.closed }

        return try await queue.write(body)
    }

    // MARK: Observation

    /// The value `query` gives now, then the value it gives after each commit that changed
    /// something it read.
    ///
    /// Each value is a consistent snapshot of one committed state, never half of a transaction.
    /// A commit that does not change what the query read produces nothing. A consumer that is
    /// slower than the writes gets the latest snapshot only, which is right for a screen and wrong
    /// for a log of events.
    ///
    /// A query that throws arrives as a `.failure(.observationFailed)` element and ends the stream;
    /// so does a store that is closed, with `.failure(.closed)`. Cancelling the consumer, or
    /// ending its iteration, stops the observation and releases its resources.
    ///
    /// The query runs on the database's connection, one run per change, so keep it short.
    public func observe<Value: Sendable>(
        _ query: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncStream<Result<Value, DatabaseStoreError>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Result<Value, DatabaseStoreError>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        guard !isClosed else {
            continuation.yield(.failure(.closed))
            continuation.finish()
            return stream
        }

        let id = UUID()
        let observation = ValueObservation.tracking { db in try query(db) }
        let queue = queue
        let task = Task {
            do {
                for try await value in observation.values(in: queue) {
                    continuation.yield(.success(value))
                }
            } catch is CancellationError {
                // The consumer went away.
            } catch {
                continuation.yield(.failure(.observationFailed(underlying: error)))
            }
            continuation.finish()
        }
        observers[id] = task
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            Task { await self?.forgetObserver(id) }
        }
        return stream
    }

    private func forgetObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Closing

    /// Stops every observation of this store and closes the connection. Later calls throw
    /// ``DatabaseStoreError/closed``. Closing a store that is already closed does nothing.
    ///
    /// Close before restoring a backup over the database's file, or before another store opens
    /// it.
    public func close() async throws(DatabaseStoreError) {
        guard !isClosed else { return }

        isClosed = true
        let running = observers.values
        observers.removeAll()
        for task in running { task.cancel() }
        // An observation that was cancelled can still be reading; wait for it to let go.
        for task in running { await task.value }
        do {
            try queue.close()
        } catch {
            throw .closeFailed(underlying: error)
        }
    }

    // MARK: Backup and restore

    /// Writes a consistent copy of the database to `destination`, using SQLite's own backup, so
    /// it is correct while the database is in use and whatever its journal mode.
    ///
    /// The copy is made beside the destination and moved into place, so a failed backup leaves
    /// an existing file there untouched. Writes to the database wait while the copy is made,
    /// and the copy cannot be cancelled once it has begun; a task cancelled before it starts
    /// throws `CancellationError`.
    ///
    /// - Throws: ``DatabaseStoreError/closed`` or ``DatabaseStoreError/backupFailed(underlying:)``.
    public func backup(to destination: URL) async throws {
        guard !isClosed else { throw DatabaseStoreError.closed }

        try Task.checkCancellation()
        let queue = queue
        do {
            try await Blocking.run {
                let manager = FileManager.default
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let partial = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).partial")
                do {
                    let target = try DatabaseQueue(path: partial.path)
                    try queue.backup(to: target)
                    try target.close()
                    try Self.moveIntoPlace(partial, at: destination)
                } catch {
                    try? manager.removeItem(at: partial)
                    throw error
                }
            }
        } catch {
            throw DatabaseStoreError.backupFailed(underlying: error)
        }
    }

    /// Replaces the database file at `location` with a backup made by ``backup(to:)``.
    ///
    /// The backup is checked first — it must open as a database and pass SQLite's integrity
    /// check — and a backup that does not leaves the current database untouched. Nothing may have
    /// the current file open: close every store on it, which also ends its observations, and
    /// reopen it afterwards so that the migrations of this version run on what was restored.
    /// Leftover journal files of the old database are removed, because applying them to the
    /// restored file would corrupt it.
    ///
    /// - Throws: ``DatabaseStoreError/restoreFailed(underlying:)``.
    public static func restore(from backup: URL, to location: URL) async throws {
        try Task.checkCancellation()
        do {
            try await Blocking.run {
                var readOnly = Configuration()
                readOnly.readonly = true
                let check = try DatabaseQueue(path: backup.path, configuration: readOnly)
                let verdict = try check.read { db in
                    try String.fetchAll(db, sql: "PRAGMA integrity_check")
                }
                try check.close()
                guard verdict == ["ok"] else {
                    throw RestoreRefused(reason: verdict.joined(separator: "; "))
                }

                let manager = FileManager.default
                try manager.createDirectory(
                    at: location.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let partial = location.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).partial")
                do {
                    try manager.copyItem(at: backup, to: partial)
                    for suffix in ["-wal", "-shm", "-journal"] {
                        try? manager.removeItem(atPath: location.path + suffix)
                    }
                    try Self.moveIntoPlace(partial, at: location)
                } catch {
                    try? manager.removeItem(at: partial)
                    throw error
                }
            }
        } catch {
            throw DatabaseStoreError.restoreFailed(underlying: error)
        }
    }

    private static func moveIntoPlace(_ partial: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try manager.moveItem(at: partial, to: destination)
        }
    }
}

private func makeMigrator(_ migrations: [DatabaseMigration]) -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    for migration in migrations {
        migrator.registerMigration(migration.name) { db in
            do {
                try migration.migrate(db)
            } catch {
                throw FailedMigration(name: migration.name, underlying: error)
            }
        }
    }
    return migrator
}

/// Why a backup was not restored.
private struct RestoreRefused: Error, CustomStringConvertible {
    let reason: String

    var description: String { "the backup failed SQLite's integrity check: \(reason)" }
}

/// A migration's own error, carried through GRDB with the migration's name so that the open can
/// say which step failed.
private struct FailedMigration: Error {
    let name: String
    let underlying: any Error
}

/// Runs blocking work on a utility queue instead of a thread of the cooperative pool.
private enum Blocking {
    static func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
