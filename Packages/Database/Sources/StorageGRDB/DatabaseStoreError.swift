/// Why a database could not be opened, closed, copied or restored.
///
/// Errors of the SQL a caller runs inside ``DatabaseStore/read(_:)`` and
/// ``DatabaseStore/write(_:)`` are not wrapped: they reach the caller as GRDB's `DatabaseError`,
/// or whatever the closure itself threw.
public enum DatabaseStoreError: Error, Sendable {
    /// The file could not be opened as a database, or the directory for it could not be made.
    /// The file is left exactly as it was; nothing is created in its place.
    case openFailed(underlying: any Error)
    /// Two migrations have the same name, so which one an applied name stands for is unknown.
    case duplicateMigration(name: String)
    /// A migration threw. It was rolled back whole; the migrations before it stay applied, and
    /// the database is not opened.
    case migrationFailed(name: String, underlying: any Error)
    /// The database has had migrations applied that this version of the app does not know, so it
    /// was written by a newer version. Opening it could damage data the old code does not
    /// understand; update the app instead.
    case newerThanApp(unknownMigrations: [String])
    /// The store was closed; reopen the database to use it again.
    case closed
    case closeFailed(underlying: any Error)
    /// An observed query failed; the stream ends with this.
    case observationFailed(underlying: any Error)
    case backupFailed(underlying: any Error)
    case restoreFailed(underlying: any Error)
}
