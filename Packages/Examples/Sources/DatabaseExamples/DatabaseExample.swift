import Foundation
import GRDB
import StorageGRDB

/// The schema, as migrations applied in order; a store remembers which have run.
public let todoMigrations = [
    DatabaseMigration("createTodo") { db in
        try db.create(table: "todo") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("title", .text).notNull()
            table.column("done", .boolean).notNull().defaults(to: false)
        }
    }
]

/// Opens a database, writes in a transaction, reads, and follows a query: the stream gives
/// the query's result now and again after every commit that changed what it read.
///
/// - Parameter location: `.inMemory` for tests, `.file(url)` in the app.
/// - Returns: The titles left to do, as the observation saw them after each change, and the
///   number of rows read at the end.
public func runTodos(at location: DatabaseLocation = .inMemory) async throws -> (
    seen: [[String]], total: Int
) {
    let store = try await DatabaseStore.open(location, migrations: todoMigrations)
    let openTitles: @Sendable (Database) throws -> [String] = { db in
        try String.fetchAll(db, sql: "SELECT title FROM todo WHERE done = 0 ORDER BY id")
    }

    var seen: [[String]] = []
    var updates = await store.observe(openTitles).makeAsyncIterator()
    seen.append(try await updates.next()?.get() ?? [])

    try await store.write { db in
        try db.execute(
            sql: "INSERT INTO todo (title) VALUES (?), (?)",
            arguments: ["Milk", "Bread"]
        )
    }
    seen.append(try await updates.next()?.get() ?? [])

    try await store.write { db in
        try db.execute(sql: "UPDATE todo SET done = 1 WHERE title = ?", arguments: ["Milk"])
    }
    seen.append(try await updates.next()?.get() ?? [])

    let total = try await store.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todo") ?? 0
    }
    try await store.close()
    return (seen, total)
}
