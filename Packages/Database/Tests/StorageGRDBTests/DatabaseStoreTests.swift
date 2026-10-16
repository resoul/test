import Foundation
import GRDB
import Testing
import os

@testable import StorageGRDB

/// A directory that lives for one test and is removed after it.
private struct Sandbox: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DatabaseStoreTests." + UUID().uuidString, isDirectory: true)

    var database: URL { url.appendingPathComponent("db/app.sqlite") }

    var backup: URL { url.appendingPathComponent("backups/app.sqlite") }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private struct Boom: Error {}

private let createItems = DatabaseMigration("createItems") { db in
    try db.create(table: "item") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("title", .text).notNull()
    }
}

private let addDone = DatabaseMigration("addDone") { db in
    try db.alter(table: "item") { table in
        table.add(column: "done", .boolean).notNull().defaults(to: false)
    }
}

private let createOther = DatabaseMigration("createOther") { db in
    try db.create(table: "other") { table in table.column("note", .text) }
}

private func insert(_ title: String) -> @Sendable (Database) throws -> Void {
    { db in try db.execute(sql: "INSERT INTO item (title) VALUES (?)", arguments: [title]) }
}

private func titles(_ store: DatabaseStore) async throws -> [String] {
    try await store.read { db in
        try String.fetchAll(db, sql: "SELECT title FROM item ORDER BY id")
    }
}

private func count(_ store: DatabaseStore) async throws -> Int {
    try await store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? -1 }
}

@Test
func anOpenedStoreHasItsSchemaAndStoresWhatIsWritten() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])

    try await store.write(insert("first"))
    try await store.write(insert("second"))

    #expect(try await titles(store) == ["first", "second"])
}

@Test
func parametersAreBoundNotSpliced() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let hostile = "x'); DROP TABLE item; --"

    try await store.write(insert(hostile))

    #expect(try await titles(store) == [hostile])
}

@Test
func aFileDatabaseKeepsItsDataAndAnOldSchemaIsMigratedForward() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let first = try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    try await first.write(insert("kept"))
    try await first.close()

    let second = try await DatabaseStore.open(
        .file(sandbox.database),
        migrations: [createItems, addDone]
    )

    #expect(try await titles(second) == ["kept"])
    // The row written before the migration has the new column's default.
    #expect(
        try await second.read { db in try Bool.fetchOne(db, sql: "SELECT done FROM item") } == false
    )
    #expect(FileManager.default.fileExists(atPath: sandbox.database.path))
}

@Test
func aFailingMigrationIsRolledBackNamedAndLeavesTheEarlierOnesApplied() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let first = try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    try await first.write(insert("kept"))
    try await first.close()
    let broken = DatabaseMigration("broken") { db in
        try db.create(table: "half") { table in table.column("x", .text) }
        throw Boom()
    }

    await #expect {
        try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems, broken])
    } throws: { error in
        guard case DatabaseStoreError.migrationFailed(let name, let underlying) = error else {
            return false
        }
        return name == "broken" && underlying is Boom
    }

    // The failed step left nothing behind, and the data is as it was.
    let again = try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    #expect(try await titles(again) == ["kept"])
    let tables = try await again.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name = 'half'")
    }
    #expect(tables.isEmpty)
}

@Test
func aDatabaseFromANewerAppIsNotOpenedOrChanged() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let newer = try await DatabaseStore.open(
        .file(sandbox.database),
        migrations: [createItems, addDone, createOther]
    )
    try await newer.write(insert("from the future"))
    try await newer.close()

    await #expect {
        try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    } throws: { error in
        guard case DatabaseStoreError.newerThanApp(let unknown) = error else { return false }
        return unknown == ["addDone", "createOther"]
    }

    // Still intact for the version that knows its schema.
    let back = try await DatabaseStore.open(
        .file(sandbox.database),
        migrations: [createItems, addDone, createOther]
    )
    #expect(try await titles(back) == ["from the future"])
}

@Test
func twoMigrationsWithOneNameAreRefused() async throws {
    await #expect {
        try await DatabaseStore.open(.inMemory, migrations: [createItems, createItems])
    } throws: { error in
        guard case DatabaseStoreError.duplicateMigration(let name) = error else { return false }
        return name == "createItems"
    }
}

@Test
func aFileThatIsNotADatabaseIsNotReplacedByAnEmptyOne() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    try FileManager.default.createDirectory(
        at: sandbox.database.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let garbage = Data("this is not an sqlite database, it is just text, padded out".utf8)
    try garbage.write(to: sandbox.database)

    await #expect {
        try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    } throws: { error in
        if case DatabaseStoreError.openFailed = error { return true }
        return false
    }

    #expect(try Data(contentsOf: sandbox.database) == garbage)
}

@Test
func aWriteThatThrowsStoresNothingAndTheErrorReachesTheCaller() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    try await store.write(insert("before"))

    await #expect(throws: Boom.self) {
        try await store.write { db in
            try db.execute(sql: "INSERT INTO item (title) VALUES ('half')")
            try db.execute(sql: "INSERT INTO item (title) VALUES ('other half')")
            throw Boom()
        }
    }

    #expect(try await titles(store) == ["before"])
}

@Test
func aTaskCancelledBeforeAWriteStartsWritesNothing() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])

    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        try await store.write(insert("never"))
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await count(store) == 0)
}

@Test(.timeLimit(.minutes(1)))
func cancellingDuringAWriteRollsItBackBeforeTheCommit() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    let task = Task {
        try await store.write { db in
            try db.execute(sql: "INSERT INTO item (title) VALUES ('rolled back')")
            started.signal()
            proceed.wait()
        }
    }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            started.wait()
            continuation.resume()
        }
    }
    task.cancel()
    proceed.signal()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await count(store) == 0)
}

@Test(.timeLimit(.minutes(1)))
func cancellingAfterTheCommitKeepsTheWriteAndReturnsNormally() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let handle = OSAllocatedUnfairLock<Task<String, any Error>?>(initialState: nil)
    let didCancel = OSAllocatedUnfairLock(initialState: false)
    let ready = DispatchSemaphore(value: 0)

    let task = Task<String, any Error> {
        try await store.write { db in
            // Wait until the test has the task's handle, so that the cancellation below happens.
            ready.wait()
            try db.execute(sql: "INSERT INTO item (title) VALUES ('committed')")
            // Runs right after the commit, inside the connection's own call: the latest moment at
            // which the task can still be cancelled while the write is going on.
            db.afterNextTransaction(onCommit: { _ in
                let cancelled = handle.withLock { held -> Bool in
                    held?.cancel()
                    return held != nil
                }
                didCancel.withLock { $0 = cancelled }
            })
            return "done"
        }
    }
    handle.withLock { $0 = task }
    ready.signal()

    // The write returns its result: the cancellation came after the commit.
    let outcome = await task.result
    #expect(didCancel.withLock { $0 })
    #expect((try? outcome.get()) == "done")
    #expect(try await titles(store) == ["committed"])
}

@Test(.timeLimit(.minutes(1)))
func observationGivesTheCurrentSnapshotThenOneAfterEachChangingCommit() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems, createOther])
    let stream = await store.observe { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next()?.get() == 0)
    // A commit that touches only another table changes nothing this query read.
    try await store.write { db in try db.execute(sql: "INSERT INTO other (note) VALUES ('x')") }
    try await store.write(insert("a"))
    #expect(try await iterator.next()?.get() == 1)
    try await store.write(insert("b"))
    #expect(try await iterator.next()?.get() == 2)
}

@Test(.timeLimit(.minutes(1)))
func aSnapshotIsNeverHalfOfATransaction() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let stream = await store.observe { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    let seen = Task { () -> [Int] in
        var counts: [Int] = []
        for await result in stream {
            guard case .success(let value) = result else { break }
            counts.append(value)
            if value == 50 { break }
        }
        return counts
    }

    for _ in 0..<5 {
        try await store.write { db in
            for number in 0..<10 {
                try db.execute(sql: "INSERT INTO item (title) VALUES (?)", arguments: ["\(number)"])
            }
        }
    }

    let counts = await seen.value
    #expect(counts.allSatisfy { $0 % 10 == 0 })
    #expect(counts.last == 50)
}

@Test(.timeLimit(.minutes(1)))
func aQueryThatFailsEndsTheStreamWithTheError() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let stream = await store.observe { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM no_such_table") ?? 0
    }
    var iterator = stream.makeAsyncIterator()

    guard case .failure(.observationFailed)? = await iterator.next() else {
        Issue.record("A failing query was not reported as a failure")
        return
    }
    #expect(await iterator.next() == nil)
}

@Test(.timeLimit(.minutes(1)))
func severalObserversEachSeeTheChangeAndOneLeavingDoesNotDisturbTheOther() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let query: @Sendable (Database) throws -> Int = { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    let leaving = Task {
        for await _ in await store.observe(query) { break }
    }
    let staying = await store.observe(query)
    var iterator = staying.makeAsyncIterator()
    #expect(try await iterator.next()?.get() == 0)
    _ = await leaving.value

    try await store.write(insert("a"))

    #expect(try await iterator.next()?.get() == 1)
}

@Test(.timeLimit(.minutes(1)))
func closingEndsObservationsAndLaterCallsThrowClosed() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createItems])
    let stream = await store.observe { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    try await store.close()
    try await store.close()  // closing twice is harmless

    #expect(await iterator.next() == nil)
    await #expect(throws: DatabaseStoreError.self) { try await store.read { _ in 1 } }
    await #expect(throws: DatabaseStoreError.self) { try await store.write(insert("x")) }
    guard case .failure(.closed)? = await store.observe({ _ in 1 }).first(where: { _ in true })
    else {
        Issue.record("Observing a closed store did not report it")
        return
    }
}

@Test
func aBackupIsAWholeDatabaseAndRestoringBringsItsContentBack() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = try await DatabaseStore.open(
        .file(sandbox.database),
        migrations: [createItems, addDone]
    )
    try await store.write(insert("one"))
    try await store.write(insert("two"))

    try await store.backup(to: sandbox.backup)

    // The copy opens on its own and has everything.
    let copy = try await DatabaseStore.open(
        .file(sandbox.backup),
        migrations: [createItems, addDone]
    )
    #expect(try await titles(copy) == ["one", "two"])
    try await copy.close()

    // Damage the live database, then restore it from the backup.
    try await store.write { db in try db.execute(sql: "DELETE FROM item") }
    try await store.close()
    try await DatabaseStore.restore(from: sandbox.backup, to: sandbox.database)

    let restored = try await DatabaseStore.open(
        .file(sandbox.database),
        migrations: [createItems, addDone]
    )
    #expect(try await titles(restored) == ["one", "two"])
    let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: sandbox.url.appendingPathComponent("backups").path
    )
    #expect(leftovers == ["app.sqlite"])
}

@Test
func aBackupReplacesAnExistingFileWholeNotInPart() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    try await store.write(insert("old"))
    try await store.backup(to: sandbox.backup)
    try await store.write(insert("new"))

    try await store.backup(to: sandbox.backup)

    let copy = try await DatabaseStore.open(.file(sandbox.backup), migrations: [createItems])
    #expect(try await titles(copy) == ["old", "new"])
}

@Test
func aBackupThatIsNotADatabaseIsRefusedAndTheCurrentOneIsUntouched() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    try await store.write(insert("precious"))
    try await store.close()
    try FileManager.default.createDirectory(
        at: sandbox.backup.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("garbage that is no database at all, only some bytes".utf8).write(to: sandbox.backup)

    await #expect {
        try await DatabaseStore.restore(from: sandbox.backup, to: sandbox.database)
    } throws: { error in
        if case DatabaseStoreError.restoreFailed = error { return true }
        return false
    }

    let still = try await DatabaseStore.open(.file(sandbox.database), migrations: [createItems])
    #expect(try await titles(still) == ["precious"])
}
