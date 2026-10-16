import Foundation
import NetworkCore
import Testing
import os

@testable import NetworkFoundation

private struct Item: Codable, Sendable, Equatable {
    var id: Int
    var name: String
}

/// A client over a real URLSession whose waits cost nothing.
private func makeClient(
    retry: RetryPolicy = .none,
    authorizer: (any HTTPAuthorizer)? = nil
) -> HTTPClient {
    HTTPClient(
        transport: URLSessionTransport(session: URLSession(configuration: .ephemeral)),
        retry: retry,
        authorizer: authorizer,
        environment: HTTPClient.Environment(sleep: { _ in })
    )
}

@Test(.timeLimit(.minutes(1)))
func aJSONRoundTripThroughARealServer() async throws {
    let server = try await LocalServer.start { request in
        let item =
            (try? JSONDecoder().decode(Item.self, from: request.body)) ?? Item(id: 0, name: "?")
        return ServerReply(
            200,
            String(
                decoding: (try? JSONEncoder().encode(
                    Item(id: item.id + 1, name: item.name.uppercased())
                )) ?? Data(),
                as: UTF8.self
            ),
            headers: [("Content-Type", "application/json")]
        )
    }
    defer { server.stop() }
    let request = try HTTPRequest.json(.post, server.url("/items"), body: Item(id: 1, name: "ann"))

    let item = try await makeClient().send(request, as: Item.self)

    #expect(item == Item(id: 2, name: "ANN"))
}

@Test(.timeLimit(.minutes(1)))
func anErrorStatusKeepsTheServersExplanation() async throws {
    let server = try await LocalServer.start { _ in
        ServerReply(422, #"{"error":"name is required"}"#)
    }
    defer { server.stop() }

    await #expect {
        try await makeClient().send(HTTPRequest(.get, server.url("/")))
    } throws: { error in
        guard case HTTPError.status(let response) = error else { return false }
        return response.status == 422
            && String(decoding: response.body, as: UTF8.self).contains("required")
    }
}

@Test(.timeLimit(.minutes(1)))
func aGetIsSentAgainAfterAServerErrorAndTheServerSeesBothRequests() async throws {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let server = try await LocalServer.start { _ in
        let call = calls.withLock { value -> Int in
            value += 1
            return value
        }
        return call == 1
            ? ServerReply(503, "busy", headers: [("Retry-After", "1")]) : ServerReply(200, "fine")
    }
    defer { server.stop() }
    let client = makeClient(retry: RetryPolicy(maxAttempts: 3, initialDelay: 0.01))

    let response = try await client.send(HTTPRequest(.get, server.url("/")))

    #expect(String(decoding: response.body, as: UTF8.self) == "fine")
    #expect(server.requests.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func aPostIsNotRepeatedAfterAServerErrorEvenWithRetryOn() async throws {
    let server = try await LocalServer.start { _ in ServerReply(503) }
    defer { server.stop() }
    let client = makeClient(retry: RetryPolicy(maxAttempts: 3, initialDelay: 0.01))

    await #expect(throws: HTTPError.self) {
        try await client.send(HTTPRequest(.post, server.url("/"), body: Data("x".utf8)))
    }

    #expect(server.requests.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aTokenIsRenewedAfterARefusalAgainstARealServer() async throws {
    let token = OSAllocatedUnfairLock(initialState: "old")
    let refreshes = OSAllocatedUnfairLock(initialState: 0)
    let server = try await LocalServer.start { request in
        request.headers["authorization"] == "Bearer new"
            ? ServerReply(200, "welcome") : ServerReply(401)
    }
    defer { server.stop() }
    let authorizer = TokenAuthorizer(
        origin: HTTPOrigin(server.url("/"))!,
        token: { token.withLock { $0 } },
        refresh: {
            refreshes.withLock { $0 += 1 }
            token.withLock { $0 = "new" }
        }
    )

    let response = try await makeClient(authorizer: authorizer).send(
        HTTPRequest(.get, server.url("/me"))
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "welcome")
    #expect(refreshes.withLock { $0 } == 1)
    #expect(
        server.requests.compactMap { $0.headers["authorization"] } == ["Bearer old", "Bearer new"]
    )
}
