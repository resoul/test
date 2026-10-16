import Foundation
import NetworkCore
import NetworkFoundation
import NetworkStorage
import StorageCore

/// An item of the example API.
public struct Item: Codable, Sendable, Equatable {
    /// The item's id.
    public var id: Int
    /// The item's title.
    public var title: String

    /// An item.
    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

/// A transport that answers from memory: the client adds its policy — statuses, retries,
/// credentials — on top of any transport, so tests and previews need no server.
public struct CannedTransport: HTTPTransport {
    /// The body every answer carries.
    public let body: Data

    /// A transport whose every answer is `200` with `body`.
    public init(body: Data) {
        self.body = body
    }

    public func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: body,
            url: request.url
        )
    }
}

/// The client of the example API over `transport`; the app gives it `URLSessionTransport()`.
/// Idempotent requests are tried up to three times in all, with growing pauses between tries.
public func itemsClient(transport: any HTTPTransport = URLSessionTransport()) -> HTTPClient {
    HTTPClient(
        transport: transport,
        baseURL: URL(string: "https://api.example.com/v1/"),
        defaultHeaders: ["Accept": "application/json"],
        retry: RetryPolicy(maxAttempts: 3)
    )
}

/// Loads the items: the path joins the base URL, the answer must be `2xx`, and its body is
/// decoded as JSON.
///
/// - Throws: `HTTPError` — the status, the transport or the decoding, as the case may be.
public func loadItems(with client: HTTPClient) async throws(HTTPError) -> [Item] {
    let request = try client.request(
        .get,
        "items",
        query: [URLQueryItem(name: "limit", value: "20")]
    )
    return try await client.send(request, as: [Item].self)
}

/// Downloads the items' answer into a file store at `cache/items.json`, without keeping the
/// whole body in memory when the transport can avoid it.
///
/// - Returns: The number of bytes stored.
public func cacheItems(with client: HTTPClient, in store: some FileStore) async throws -> Int {
    let request = try client.request(.get, "items")
    let stored = try await client.download(request, into: store, at: FilePath("cache/items.json"))
    return stored.bytes
}
