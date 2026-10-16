import GRDB

/// One step in the history of a database's schema.
///
/// A database remembers the names of the migrations it has run, and on opening runs only the
/// ones it has not, in the order they are listed. So a migration is never edited once it has
/// shipped: a change is a new migration after it. The app owns the schema; the store never
/// erases a database to make the schema fit.
public struct DatabaseMigration: Sendable {
    /// Unique among the migrations. Name by what the step does, such as `createItems`; the name is
    /// stored in the database.
    public let name: String
    /// Runs inside a transaction of its own. If it throws, the transaction is rolled back and the
    /// open fails with ``DatabaseStoreError/migrationFailed(name:underlying:)``.
    public let migrate: @Sendable (Database) throws -> Void

    public init(_ name: String, migrate: @escaping @Sendable (Database) throws -> Void) {
        self.name = name
        self.migrate = migrate
    }
}
