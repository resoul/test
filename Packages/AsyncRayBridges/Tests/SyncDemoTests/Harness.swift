import Foundation
import NetworkCore
import StateCore
import StorageCore
import StorageGRDB
import GRDB
import Testing

@testable import SyncDemo

let itemsURL = URL(string: "https://demo.example/items")!
let liveURL = URL(string: "wss://demo.example/live")!

/// Everything a screen needs, wired to a server in memory: the database, the files, the
/// preferences, the two clients and the repository.
struct Harness {
    let server: DemoServer
    let database: DatabaseStore
    let files: MemoryFileStore
    let preferences: MemoryPreferences
    let repository: ItemsRepository
    let socket: WebSocketClient

    /// Waits of a reconnect are short and real, so that a test does not wait for the minute a real
    /// backoff would take, and does not spin either.
    static let environment = NetworkEnvironment(sleep: { _ in
        try await Task.sleep(for: .milliseconds(5))
    })

    static func make(
        items: [Item] = [],
        retention: Int = 100,
        retry: RetryPolicy = .none,
        migrations: [DatabaseMigration] = ItemsRepository.migrations
    ) async throws -> Harness {
        let server = DemoServer(items: items, retention: retention)
        let database = try await DatabaseStore.open(.inMemory, migrations: migrations)
        let files = MemoryFileStore()
        let socket = WebSocketClient(
            request: HTTPRequest(.get, liveURL),
            transport: server,
            configuration: WebSocketConfiguration(
                reconnect: ReconnectPolicy(
                    maxAttempts: 20,
                    initialDelay: 1,
                    jitter: 0,
                    stableAfter: 0
                )
            ),
            environment: environment
        )
        let http = HTTPClient(transport: server, retry: retry, environment: environment)
        let repository = ItemsRepository(
            database: database,
            http: http,
            socket: socket,
            files: files,
            itemsURL: itemsURL
        )
        return Harness(
            server: server,
            database: database,
            files: files,
            preferences: MemoryPreferences(),
            repository: repository,
            socket: socket
        )
    }

    @MainActor
    func model() -> ItemsModel { ItemsModel(repository: repository, preferences: preferences) }

    /// The cursor and epoch the database holds.
    func state() async throws -> (cursor: Int, epoch: Int, synced: Bool) {
        try await repository.currentState()
    }

    func count(_ table: String) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }
}

/// Polls on the main actor until `condition` holds or five seconds pass.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<2500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

func titles(_ model: ItemsModel) async -> [String] {
    await MainActor.run { model.rows.value.map(\.title) }
}

let threeItems = [
    Item(id: "item-1", title: "Banana", revision: 1),
    Item(id: "item-2", title: "apple", revision: 2),
    Item(id: "item-3", title: "Cherry", revision: 3),
]
