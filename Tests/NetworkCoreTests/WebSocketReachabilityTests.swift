import Foundation
import NetworkCore
import Testing

/// A client whose wait before the next attempt lasts until it is ended, so that it is the network
/// coming back, and nothing else, that brings the attempt forward.
private func waitingClient(
    _ transport: FakeSocketTransport,
    sleeps: Sleeps? = nil
) -> WebSocketClient {
    WebSocketClient(
        request: HTTPRequest(.get, socketURL),
        transport: transport,
        environment: NetworkEnvironment(
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            random: { 0.5 }
        )
    )
}

private let lostLink = WebSocketError.transport(
    TransportFailure(kind: .connectionLost, underlying: URLError(.networkConnectionLost))
)

private func isReconnecting(_ state: WebSocketState) -> Bool {
    if case .reconnecting = state { return true }
    return false
}

@Test(.timeLimit(.minutes(1)))
func reconnectingNowEndsTheWaitAndConnectsAtOnce() async throws {
    let first = FakeConnection()
    let transport = FakeSocketTransport([.connection(first), .connection(FakeConnection())])
    let client = waitingClient(transport)
    await client.connect()
    _ = await client.nextEvent()
    first.fail(lostLink)
    #expect(await waitUntil { isReconnecting(await client.state) })
    #expect(transport.connectCount == 1, "the pause has begun and nothing is tried yet")

    await client.reconnectNow()

    #expect(await waitUntil { await client.state.isConnected })
    #expect(transport.connectCount == 2)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func reconnectingNowDoesNothingWhenThereIsNoWait() async throws {
    let transport = FakeSocketTransport([.connection(FakeConnection())])
    let client = waitingClient(transport)

    await client.reconnectNow()
    #expect(transport.connectCount == 0, "not started")

    await client.connect()
    _ = await client.nextEvent()
    await client.reconnectNow()
    #expect(await client.state.isConnected)
    #expect(transport.connectCount == 1, "connected")

    await client.suspend()
    await client.reconnectNow()
    try await Task.sleep(for: .milliseconds(30))
    #expect(transport.connectCount == 1, "suspended")
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func closingStillEndsTheWaitAndIsNotTakenForAWakeUp() async throws {
    let first = FakeConnection()
    let transport = FakeSocketTransport([.connection(first), .connection(FakeConnection())])
    let client = waitingClient(transport)
    await client.connect()
    _ = await client.nextEvent()
    first.fail(lostLink)
    #expect(await waitUntil { isReconnecting(await client.state) })

    await client.close()
    try await Task.sleep(for: .milliseconds(50))

    #expect(transport.connectCount == 1, "a closed client does not connect again")
    guard case .closed = await client.state else {
        Issue.record("expected closed, got \(await client.state)")
        return
    }
}

@Test(.timeLimit(.minutes(1)))
func aReachablePathBringsTheAttemptForwardAndAnUnreachableOneDoesNot() async throws {
    let first = FakeConnection()
    let transport = FakeSocketTransport([.connection(first), .connection(FakeConnection())])
    let client = waitingClient(transport)
    await client.connect()
    _ = await client.nextEvent()
    first.fail(lostLink)
    #expect(await waitUntil { isReconnecting(await client.state) })
    let (paths, input) = AsyncStream.makeStream(of: NetworkPath.self)
    let following = Task { await client.reconnectWhenReachable(paths) }

    input.yield(NetworkPath(status: .unsatisfied))
    input.yield(NetworkPath(status: .requiresConnection))
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.connectCount == 1, "no route, no attempt")

    input.yield(NetworkPath(status: .satisfied, isExpensive: true))
    #expect(await waitUntil { await client.state.isConnected })
    #expect(transport.connectCount == 2)

    input.finish()
    await following.value
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func followingThePathsEndsWhenItsTaskIsCancelled() async {
    let client = waitingClient(FakeSocketTransport([.connection(FakeConnection())]))
    let (paths, input) = AsyncStream.makeStream(of: NetworkPath.self)
    _ = input
    let following = Task { await client.reconnectWhenReachable(paths) }

    following.cancel()
    await following.value
}

@Test
func aPathIsReachableOnlyWhenTheSystemHasARoute() {
    #expect(NetworkPath(status: .satisfied).isReachable)
    #expect(!NetworkPath(status: .unsatisfied).isReachable)
    #expect(!NetworkPath(status: .requiresConnection).isReachable)
}
