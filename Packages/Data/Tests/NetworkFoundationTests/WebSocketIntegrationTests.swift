import Foundation
import NetworkCore
import Testing
import os

@testable import NetworkFoundation

private func makeClient(
    _ url: URL,
    configuration: WebSocketConfiguration = WebSocketConfiguration(
        reconnect: ReconnectPolicy(
            maxAttempts: 3,
            initialDelay: 0.05,
            maxDelay: 0.2,
            jitter: 0,
            stableAfter: 5
        )
    ),
    authorizer: (any HTTPAuthorizer)? = nil
) -> WebSocketClient {
    WebSocketClient(
        request: HTTPRequest(.get, url),
        transport: URLSessionWebSocketTransport(session: URLSession(configuration: .ephemeral)),
        configuration: configuration,
        authorizer: authorizer
    )
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(4))
    }
    return false
}

private func take(_ count: Int, from client: WebSocketClient) async -> [WebSocketEvent] {
    var events: [WebSocketEvent] = []
    while events.count < count, let event = await client.nextEvent() { events.append(event) }
    return events
}

private func isMessage(_ event: WebSocketEvent?, _ text: String) -> Bool {
    if case .message(.text(let received))? = event { return received == text }
    return false
}

private func isConnected(_ event: WebSocketEvent?, reconnect: Bool) -> Bool {
    if case .connected(let isReconnect)? = event { return isReconnect == reconnect }
    return false
}

private func isDisconnected(_ event: WebSocketEvent?, willReconnect: Bool) -> Bool {
    if case .disconnected(_, let will)? = event { return will == willReconnect }
    return false
}

@Test(.timeLimit(.minutes(1)))
func messagesGoBothWaysThroughARealSocketInOrder() async throws {
    let server = try await LocalWebSocketServer.start(onMessage: { message, server in
        // Echo, so that what the client sent comes back.
        server.broadcast(message)
    })
    defer { server.stop() }
    let client = makeClient(server.url("/echo"))

    await client.connect()
    #expect(isConnected(await client.nextEvent(), reconnect: false))
    for number in 1...30 { try await client.send(.text("t\(number)")) }
    try await client.send(.binary(Data([9, 8, 7])))

    for number in 1...30 { #expect(isMessage(await client.nextEvent(), "t\(number)")) }
    guard case .message(.binary(let data))? = await client.nextEvent() else {
        Issue.record("The binary echo did not come back as binary")
        return
    }
    #expect(data == Data([9, 8, 7]))
    #expect(server.received.count == 31)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aServerPushReachesTheConsumer() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    let client = makeClient(server.url())
    await client.connect()
    _ = await client.nextEvent()

    server.broadcast(text: "pushed")

    #expect(isMessage(await client.nextEvent(), "pushed"))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func theHandshakeCarriesTheRequestsHeadersAndTheTokenOfItsOwnServer() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    let origin = try #require(HTTPOrigin(URL(string: "http://127.0.0.1:\(server.port)")!))
    let authorizer = TokenAuthorizer(origin: origin, token: { "tok" }, refresh: {})
    let client = makeClient(server.url("/live"), authorizer: authorizer)

    await client.connect()
    _ = await client.nextEvent()

    let handshake = try #require(server.handshakes.first)
    #expect(handshake.headers["authorization"] == "Bearer tok")
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func anUpgradeRefusedWithAStatusIsAHandshakeRejectionAndIsNotRetried() async throws {
    // A plain HTTP server answering the upgrade request with 401, as a server that wants credentials.
    let server = try await LocalServer.start { _ in ServerReply(401, "no") }
    defer { server.stop() }
    let url = URL(string: "ws://127.0.0.1:\(server.port)/live")!
    let client = makeClient(url)

    await client.connect()

    #expect(await waitUntil { if case .failed = await client.state { true } else { false } })
    guard case .failed(.handshakeRejected(let status)) = await client.state else {
        Issue.record("The refusal was not reported as a handshake rejection")
        return
    }
    #expect(status == 401)
    #expect(server.requests.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aDroppedConnectionIsRemadeAndTheConsumerIsToldInOrder() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    let client = makeClient(server.url())
    await client.connect()
    _ = await client.nextEvent()
    #expect(await waitUntil { server.openConnections == 1 })

    server.dropAll()

    #expect(isDisconnected(await client.nextEvent(), willReconnect: true))
    #expect(isConnected(await client.nextEvent(), reconnect: true))
    #expect(await waitUntil { server.totalConnections == 2 })
    server.broadcast(text: "after")
    #expect(isMessage(await client.nextEvent(), "after"))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aCloseFrameWithTheNormalCodeEndsTheSessionAndOneThatGoesAwayDoesNot() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    let client = makeClient(server.url())
    await client.connect()
    _ = await client.nextEvent()
    #expect(await waitUntil { server.openConnections == 1 })

    // 1001 going away: come back.
    server.closeAll(code: 1001)
    #expect(isDisconnected(await client.nextEvent(), willReconnect: true))
    #expect(isConnected(await client.nextEvent(), reconnect: true))
    #expect(await waitUntil { server.openConnections == 1 })

    // 1000 normal closure: the session is over.
    server.closeAll(code: 1000)
    #expect(isDisconnected(await client.nextEvent(), willReconnect: false))
    #expect(await client.nextEvent() == nil)
    guard case .closed(let close) = await client.state else {
        Issue.record("The state was not closed")
        return
    }
    #expect(close.code == 1000)
    #expect(close.initiator == .server)
}

@Test(.timeLimit(.minutes(1)))
func closingTheClientClosesTheSocketWithItsCodeAndStopsReconnecting() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    let client = makeClient(server.url())
    await client.connect()
    _ = await client.nextEvent()
    #expect(await waitUntil { server.openConnections == 1 })

    await client.close(code: 1000, reason: "done")

    #expect(await waitUntil { server.openConnections == 0 })
    #expect(server.closeCodes.contains(1000))
    try await Task.sleep(for: .milliseconds(200))
    #expect(server.totalConnections == 1, "A closed client reconnected")
}

@Test(.timeLimit(.minutes(1)))
func aServerThatGoesQuietIsDeclaredDeadByItsPingsAndTheClientReconnects() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    let configuration = WebSocketConfiguration(
        heartbeat: Heartbeat(interval: 0.15, timeout: 0.3),
        reconnect: ReconnectPolicy(maxAttempts: 5, initialDelay: 0.05, jitter: 0, stableAfter: 60)
    )
    let client = makeClient(server.url(), configuration: configuration)
    await client.connect()
    #expect(isConnected(await client.nextEvent(), reconnect: false))
    // The connection is up and the pings are answered: it stays up.
    try await Task.sleep(for: .milliseconds(500))
    #expect(await client.state.isConnected)

    // The server stops answering, though the connection is still open.
    server.setAnswersPings(false)

    guard case .disconnected(let cause, true)? = await client.nextEvent() else {
        Issue.record("The silent server was not reported lost")
        return
    }
    guard case .heartbeatTimeout? = cause else {
        Issue.record("The cause was not a heartbeat timeout")
        return
    }
    // It comes back; the new connection is only made once the server answers again.
    server.setAnswersPings(true)
    #expect(isConnected(await client.nextEvent(), reconnect: true))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aMessageOverTheLimitEndsTheClientWithoutReconnecting() async throws {
    let server = try await LocalWebSocketServer.start()
    defer { server.stop() }
    var configuration = WebSocketConfiguration(
        maxMessageBytes: 10_000,
        reconnect: ReconnectPolicy(maxAttempts: 3, initialDelay: 0.05, jitter: 0, stableAfter: 5)
    )
    configuration.inboundCapacity = 16
    let client = makeClient(server.url(), configuration: configuration)
    await client.connect()
    _ = await client.nextEvent()
    #expect(await waitUntil { server.openConnections == 1 })

    server.broadcast(text: String(repeating: "x", count: 200_000))

    #expect(await waitUntil { if case .failed = await client.state { true } else { false } })
    guard case .failed(.messageTooLarge(let limit)) = await client.state else {
        Issue.record("The state was not a size failure: \(await client.state)")
        return
    }
    #expect(limit == 10_000)
    #expect(server.totalConnections == 1)
}

@Test(.timeLimit(.minutes(1)))
func aServerThatIsNotListeningIsRetriedAndThenGivenUpOn() async throws {
    let server = try await LocalWebSocketServer.start()
    let url = server.url()
    server.stop()
    try await Task.sleep(for: .milliseconds(100))
    let client = makeClient(url)

    await client.connect()

    #expect(await waitUntil { if case .failed = await client.state { true } else { false } })
    guard case .failed(.transport(let failure)) = await client.state else {
        Issue.record("The state was not a transport failure")
        return
    }
    #expect(failure.kind == .cannotConnect)
}

@Test
func aURLThatIsNotASocketAddressIsRefusedAtOnce() async throws {
    let transport = URLSessionWebSocketTransport(session: URLSession(configuration: .ephemeral))
    for text in ["ftp://example.com/a", "file:///tmp/x", "mailto:a@b.c"] {
        await #expect {
            try await transport.connect(HTTPRequest(.get, URL(string: text)!), maxMessageBytes: 100)
        } throws: { error in
            if case WebSocketError.invalidURL = error { return true }
            return false
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func aSuspendedSocketIsClosedForTheServerAndResumedAsANewConnection() async throws {
    let server = try await LocalWebSocketServer.start(onMessage: { message, server in
        server.broadcast(message)
    })
    defer { server.stop() }
    let client = makeClient(server.url("/echo"))
    await client.connect()
    #expect(isConnected(await client.nextEvent(), reconnect: false))
    #expect(await waitUntil { server.openConnections == 1 })

    await client.suspend()

    // The server sees the connection go, with "going away".
    #expect(await waitUntil { server.openConnections == 0 })
    #expect(isDisconnected(await client.nextEvent(), willReconnect: false))
    try await Task.sleep(for: .milliseconds(300))
    #expect(server.totalConnections == 1, "a suspended client does not reconnect on its own")

    await client.resume()
    #expect(isConnected(await client.nextEvent(), reconnect: true))
    try await client.send(.text("after"))
    #expect(isMessage(await client.nextEvent(), "after"))
    #expect(server.totalConnections == 2)
    await client.close()
}
