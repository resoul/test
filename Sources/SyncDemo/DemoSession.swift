import Foundation
import NetworkCore
import StorageCore
import StorageGRDB

/// Everything the demo needs, wired together over a server in memory: a database that lives as long
/// as the session, files in memory, preferences in memory, the two clients, and the repository.
///
/// It stands for what an app assembles once at its start. Models are made from it, one per window.
public struct DemoSession: Sendable {
    public let server: DemoServer
    public let repository: ItemsRepository
    public let preferences: MemoryPreferences

    /// The items the server starts with.
    public static let seed = [
        Item(id: "item-1", title: "Banana", revision: 1),
        Item(id: "item-2", title: "apple", revision: 2),
        Item(id: "item-3", title: "Cherry", revision: 3),
    ]

    /// Opens the database and connects the pieces. The socket is not connected until a model
    /// starts the repository.
    public static func make(items: [Item] = seed) async throws -> DemoSession {
        let server = DemoServer(items: items)
        let database = try await DatabaseStore.open(
            .inMemory,
            migrations: ItemsRepository.migrations
        )
        // Waits between reconnects are short, so that a demo does not make a person wait out the
        // minute a real backoff would take.
        let environment = NetworkEnvironment(sleep: { _ in try await Task.sleep(for: .milliseconds(300)) })
        let socket = WebSocketClient(
            request: HTTPRequest(.get, URL(string: "wss://demo.example/live")!),
            transport: server,
            configuration: WebSocketConfiguration(
                reconnect: ReconnectPolicy(maxAttempts: 50, initialDelay: 1, jitter: 0, stableAfter: 0)
            ),
            environment: environment
        )
        let http = HTTPClient(
            transport: server,
            retry: RetryPolicy(maxAttempts: 3, initialDelay: 0.2),
            environment: environment
        )
        let repository = ItemsRepository(
            database: database,
            http: http,
            socket: socket,
            files: MemoryFileStore(),
            itemsURL: URL(string: "https://demo.example/items")!
        )
        return DemoSession(server: server, repository: repository, preferences: MemoryPreferences())
    }

    /// A model for one window.
    @MainActor
    public func makeModel() -> ItemsModel {
        ItemsModel(repository: repository, preferences: preferences)
    }
}
