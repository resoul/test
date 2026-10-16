import Foundation
import NetworkCore
import Testing
import os

private let api = HTTPOrigin(URL(string: "https://api.example.com")!)!

/// The app's side of the credentials: a token it keeps, and a refresh it can run.
private final class Credentials: Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (token: String?, refreshes: Int, tokenReads: Int)("old", 0, 0)
    )
    let refreshDelay: Duration
    let refreshFails: Bool

    init(refreshDelay: Duration = .zero, refreshFails: Bool = false) {
        self.refreshDelay = refreshDelay
        self.refreshFails = refreshFails
    }

    var refreshes: Int { state.withLock { $0.refreshes } }
    var tokenReads: Int { state.withLock { $0.tokenReads } }

    func read() -> String? {
        state.withLock {
            $0.tokenReads += 1
            return $0.token
        }
    }

    func setToken(_ token: String?) { state.withLock { $0.token = token } }

    func refresh() async throws {
        state.withLock { $0.refreshes += 1 }
        try await Task.sleep(for: refreshDelay)
        if refreshFails { throw RefreshRefused() }
        state.withLock { $0.token = "new" }
    }
}

private struct RefreshRefused: Error {}

private func authorizer(_ credentials: Credentials) -> TokenAuthorizer {
    TokenAuthorizer(
        origin: api,
        token: { credentials.read() },
        refresh: { try await credentials.refresh() }
    )
}

private let apiURL = URL(string: "https://api.example.com/items")!

/// A server that accepts only the token `new`.
private func strictServer() -> FakeTransport {
    FakeTransport { request, _ throws(HTTPError) in
        request.headers["Authorization"] == "Bearer new"
            ? reply(200, url: apiURL) : reply(401, url: apiURL)
    }
}

@Test
func aRequestToTheTokensServerIsSignedAndOneToAnotherIsNot() async throws {
    let credentials = Credentials()
    let transport = FakeTransport(script: [.success(reply(200))])
    let client = makeClient(transport, authorizer: authorizer(credentials))

    _ = try await client.send(HTTPRequest(.get, apiURL))
    _ = try await client.send(HTTPRequest(.get, URL(string: "https://elsewhere.example.org/x")!))

    let sent = await transport.requests
    #expect(sent[0].headers["Authorization"] == "Bearer old")
    #expect(sent[1].headers["Authorization"] == nil)
    // The token was not even read for the foreign server.
    #expect(credentials.tokenReads == 1)
}

@Test
func aRequestThatAlreadyHasAuthorizationIsLeftAlone() async throws {
    let transport = FakeTransport(script: [.success(reply(200))])
    let client = makeClient(transport, authorizer: authorizer(Credentials()))

    _ = try await client.send(HTTPRequest(.get, apiURL, headers: ["Authorization": "Basic abc"]))

    #expect(await transport.requests[0].headers["Authorization"] == "Basic abc")
}

@Test
func withoutATokenTheRequestGoesUnsigned() async throws {
    let credentials = Credentials()
    credentials.setToken(nil)
    let transport = FakeTransport(script: [.success(reply(200))])
    let client = makeClient(transport, authorizer: authorizer(credentials))

    _ = try await client.send(HTTPRequest(.get, apiURL))

    #expect(await transport.requests[0].headers["Authorization"] == nil)
}

@Test
func aRefusedTokenIsRenewedOnceAndTheRequestIsSentAgainWithTheNewOne() async throws {
    let credentials = Credentials()
    let transport = strictServer()
    let client = makeClient(transport, authorizer: authorizer(credentials))

    let response = try await client.send(HTTPRequest(.get, apiURL))

    #expect(response.status == 200)
    #expect(credentials.refreshes == 1)
    let sent = await transport.requests
    #expect(sent.map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new"])
}

@Test
func aPostIsSentAgainAfterRenewalBecauseARefusedRequestWasNotActedOn() async throws {
    let transport = strictServer()
    let client = makeClient(transport, authorizer: authorizer(Credentials()))

    let response = try await client.send(HTTPRequest(.post, apiURL, body: Data("x".utf8)))

    #expect(response.status == 200)
    #expect(await transport.requests.count == 2)
}

@Test
func aSecondRefusalAfterRenewalIsAnErrorNotAnotherRefresh() async throws {
    let credentials = Credentials()
    let transport = FakeTransport(script: [.success(reply(401, url: apiURL))])
    let client = makeClient(transport, authorizer: authorizer(credentials))

    await #expect {
        try await client.send(HTTPRequest(.get, apiURL))
    } throws: { error in
        guard case HTTPError.status(let response) = error else { return false }
        return response.status == 401
    }
    #expect(credentials.refreshes == 1)
    #expect(await transport.requests.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func manyRequestsRefusedAtOnceShareOneRefresh() async throws {
    let credentials = Credentials(refreshDelay: .milliseconds(80))
    let arrived = OSAllocatedUnfairLock(initialState: 0)
    let transport = FakeTransport { request, _ throws(HTTPError) in
        if request.headers["Authorization"] == "Bearer new" { return reply(200, url: apiURL) }

        // Every request is in flight with the old token before any of them is refused.
        arrived.withLock { $0 += 1 }
        while arrived.withLock({ $0 }) < 5 { try? await Task.sleep(for: .milliseconds(2)) }
        return reply(401, url: apiURL)
    }
    let client = makeClient(transport, authorizer: authorizer(credentials))

    let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<5 { group.addTask { try await client.send(HTTPRequest(.get, apiURL)).status } }
        return try await group.reduce(into: []) { $0.append($1) }
    }

    #expect(statuses == [200, 200, 200, 200, 200])
    #expect(credentials.refreshes == 1)
}

@Test
func aFailedRefreshIsAnAuthorizationErrorAndIsNotRememberedAsSuccess() async throws {
    let credentials = Credentials(refreshFails: true)
    let transport = strictServer()
    let client = makeClient(transport, authorizer: authorizer(credentials))

    for expected in 1...2 {
        await #expect {
            try await client.send(HTTPRequest(.get, apiURL))
        } throws: { error in
            guard case HTTPError.authorizationFailed(let cause) = error else { return false }
            return cause is RefreshRefused
        }
        #expect(credentials.refreshes == expected)
    }
}

@Test
func aTokenSourceThatFailsStopsTheRequestBeforeItIsSent() async throws {
    struct NoKeychain: Error {}
    let transport = FakeTransport(script: [.success(reply(200))])
    let failing = TokenAuthorizer(
        origin: api,
        token: { throw NoKeychain() },
        refresh: {}
    )
    let client = makeClient(transport, authorizer: failing)

    await #expect {
        try await client.send(HTTPRequest(.get, apiURL))
    } throws: { error in
        guard case HTTPError.authorizationFailed(let cause) = error else { return false }
        return cause is NoKeychain
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func aRefusalFromAnotherServerDoesNotRenewOurToken() async throws {
    let credentials = Credentials()
    let transport = FakeTransport(script: [.success(reply(401))])
    let client = makeClient(transport, authorizer: authorizer(credentials))

    await #expect(throws: HTTPError.self) {
        try await client.send(HTTPRequest(.get, URL(string: "https://elsewhere.example.org/x")!))
    }

    #expect(credentials.refreshes == 0)
    #expect(await transport.requests.count == 1)
}

@Test
func aRefusalWithoutAnAuthorizerIsJustAStatus() async throws {
    let client = makeClient(FakeTransport(script: [.success(reply(401))]))

    await #expect {
        try await client.send(HTTPRequest(.get, apiURL))
    } throws: { error in
        guard case HTTPError.status(let response) = error else { return false }
        return response.status == 401
    }
}
