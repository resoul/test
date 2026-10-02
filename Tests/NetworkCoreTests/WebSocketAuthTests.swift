import Foundation
import NetworkCore
import Testing
import os

private let api = HTTPOrigin(URL(string: "https://api.example.com")!)!

private final class Token: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (value: "old", refreshes: 0))

    var refreshes: Int { state.withLock { $0.refreshes } }

    func read() -> String { state.withLock { $0.value } }

    func refresh() {
        state.withLock {
            $0.value = "new"
            $0.refreshes += 1
        }
    }
}

private func authorizer(_ token: Token) -> TokenAuthorizer {
    TokenAuthorizer(origin: api, token: { token.read() }, refresh: { token.refresh() })
}

@Test(.timeLimit(.minutes(1)))
func theHandshakeCarriesTheTokenOfTheSameServerUnderItsWebSocketAddress() async throws {
    let transport = FakeSocketTransport([.connection(FakeConnection())])
    let client = makeClient(transport, authorizer: authorizer(Token()))

    await client.connect()
    _ = await client.nextEvent()

    #expect(transport.requests[0].headers["Authorization"] == "Bearer old")
    #expect(transport.requests[0].url == socketURL)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aRefusedHandshakeRenewsTheTokenOnceAndTriesAgainAtOnce() async throws {
    let token = Token()
    let transport = FakeSocketTransport([
        .failure(.handshakeRejected(status: 401)), .connection(FakeConnection()),
    ])
    let sleeps = Sleeps()
    let client = makeClient(transport, authorizer: authorizer(token), sleeps: sleeps)

    await client.connect()
    _ = await client.nextEvent()

    #expect(token.refreshes == 1)
    #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new"])
    // The retry was immediate, not a backoff.
    #expect(sleeps.delays.isEmpty)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aSecondRefusalAfterRenewalEndsTheClientWithoutRepeating() async throws {
    let token = Token()
    let transport = FakeSocketTransport([.failure(.handshakeRejected(status: 401))])
    let client = makeClient(transport, authorizer: authorizer(token))

    await client.connect()

    #expect(await waitUntil { if case .failed = await client.state { true } else { false } })
    #expect(token.refreshes == 1)
    #expect(transport.connectCount == 2)
    guard case .failed(.handshakeRejected(let status)) = await client.state else {
        Issue.record("The state was not a refused handshake")
        return
    }
    #expect(status == 401)
}
