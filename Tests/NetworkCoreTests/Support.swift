import Foundation
import NetworkCore
import os

let testURL = URL(string: "https://api.example.com/items?token=secret#frag")!

func reply(
    _ status: Int,
    _ body: String = "",
    headers: HTTPHeaders = [:],
    url: URL = testURL
) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: Data(body.utf8), url: url)
}

/// A transport that answers from a closure and remembers what it was asked.
actor FakeTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest, Int) async throws(HTTPError) -> HTTPResponse

    private let handler: Handler
    private(set) var requests: [HTTPRequest] = []
    private(set) var limits: [Int?] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// A transport that gives each answer of `script` in turn, and repeats the last one.
    init(script: [Result<HTTPResponse, HTTPError>]) {
        let position = OSAllocatedUnfairLock(initialState: 0)
        self.init { _, _ throws(HTTPError) in
            let index = position.withLock { value -> Int in
                defer { value += 1 }
                return min(value, script.count - 1)
            }
            return try script[index].get()
        }
    }

    func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        requests.append(request)
        limits.append(maxResponseBytes)
        return try await handler(request, requests.count)
    }
}

/// Everything the client waited for, without waiting.
final class Waits: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [TimeInterval]())

    var delays: [TimeInterval] { stored.withLock { $0 } }

    func record(_ delay: TimeInterval) { stored.withLock { $0.append(delay) } }
}

final class Events: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [HTTPEvent]())

    var all: [HTTPEvent] { stored.withLock { $0 } }

    func record(_ event: HTTPEvent) { stored.withLock { $0.append(event) } }
}

/// A client that never sleeps for real and has no randomness: jitter factor is exactly one.
func makeClient(
    _ transport: some HTTPTransport,
    retry: RetryPolicy = .none,
    authorizer: (any HTTPAuthorizer)? = nil,
    waits: Waits = Waits(),
    events: Events? = nil,
    now: Date = Date(timeIntervalSince1970: 1_000_000)
) -> HTTPClient {
    var client = HTTPClient(
        transport: transport,
        retry: retry,
        authorizer: authorizer,
        environment: HTTPClient.Environment(
            now: { now },
            sleep: { waits.record($0) },
            random: { 0.5 }
        )
    )
    if let events {
        client.diagnostics = { event in events.record(event) }
    }
    return client
}

struct Item: Codable, Sendable, Equatable {
    var id: Int
    var name: String
}
