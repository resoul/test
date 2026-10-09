import Foundation
import NetworkCore
import Testing

private func isDisconnect(_ event: WebSocketEvent?, willReconnect: Bool) -> Bool {
    if case .disconnected(let cause, let will)? = event { return cause == nil && will == willReconnect }
    return false
}

private func isConnect(_ event: WebSocketEvent?, reconnect: Bool) -> Bool {
    if case .connected(let isReconnect)? = event { return isReconnect == reconnect }
    return false
}

private func isSuspended(_ state: WebSocketState) -> Bool {
    if case .suspended = state { return true }
    return false
}

private func isIdle(_ state: WebSocketState) -> Bool {
    if case .idle = state { return true }
    return false
}

@Test(.timeLimit(.minutes(1)))
func suspendingDropsTheConnectionButNotTheEventStream() async throws {
    let first = FakeConnection()
    let transport = FakeSocketTransport([.connection(first), .connection(FakeConnection())])
    let client = makeClient(transport)
    await client.connect()
    #expect(isConnect(await client.nextEvent(), reconnect: false))
    first.push(text: "before")
    #expect(isMessage(await client.nextEvent(), "before"))

    await client.suspend()

    #expect(isSuspended(await client.state))
    #expect(first.closes == [1001])
    #expect(isDisconnect(await client.nextEvent(), willReconnect: false))
    // Nothing was finished: the consumer would wait for the next event, not get `nil`. Resuming
    // gives it one.
    let next = Task { await client.nextEvent() }
    await client.resume()
    #expect(isConnect(await next.value, reconnect: true))
    #expect(await client.state.isConnected)
    #expect(transport.connectCount == 2)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aSuspendedClientRefusesSendsAndDoesNotReconnectOnItsOwn() async throws {
    let transport = FakeSocketTransport([.connection(FakeConnection())])
    let sleeps = Sleeps()
    let client = makeClient(transport, sleeps: sleeps)
    await client.connect()
    _ = await client.nextEvent()
    await client.suspend()

    await #expect(throws: WebSocketError.self) { try await client.send(.text("x")) }
    // Time passes, and the client stays where it is.
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.connectCount == 1)
    #expect(isSuspended(await client.state))
    #expect(sleeps.delays.isEmpty, "no reconnect wait was started")
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func messagesQueuedBeforeASuspendAreStillDelivered() async throws {
    let connection = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(connection)]))
    await client.connect()
    _ = await client.nextEvent()
    for number in 1...3 { connection.push(text: "q\(number)") }
    // Let the reader take them into the queue. A message the reader has only just taken from the
    // connection may still be lost to a suspend (the client says so), so the test also gives it time
    // to put them down.
    #expect(await waitUntil { connection.unread == 0 })
    try await Task.sleep(for: .milliseconds(150))

    await client.suspend()

    for number in 1...3 {
        #expect(isMessage(await client.nextEvent(), "q\(number)"))
    }
    #expect(isDisconnect(await client.nextEvent(), willReconnect: false))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func suspendingWhileReconnectingStopsTheWaitAndResumeConnects() async throws {
    let lost = WebSocketError.transport(
        TransportFailure(kind: .connectionLost, underlying: URLError(.networkConnectionLost))
    )
    let first = FakeConnection()
    let transport = FakeSocketTransport([.connection(first), .connection(FakeConnection())])
    // The wait before the next attempt lasts until it is cancelled, so the client stays in it.
    let client = WebSocketClient(
        request: HTTPRequest(.get, socketURL),
        transport: transport,
        environment: NetworkEnvironment(
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            random: { 0.5 }
        )
    )
    await client.connect()
    _ = await client.nextEvent()
    first.fail(lost)
    #expect(await waitUntil { if case .reconnecting = await client.state { true } else { false } })

    await client.suspend()
    let attempts = transport.connectCount
    try await Task.sleep(for: .milliseconds(30))

    #expect(isSuspended(await client.state))
    #expect(transport.connectCount == attempts, "no attempt was made while suspended")
    await client.resume()
    #expect(await waitUntil { await client.state.isConnected })
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func suspendingDuringTheFirstHandshakeDropsTheConnectionWhenItArrives() async throws {
    let connection = FakeConnection()
    let gate = FakeSocketTransport.Gate()
    let transport = FakeSocketTransport([.slow(connection, gate)])
    let client = makeClient(transport)
    await client.connect()
    #expect(await waitUntil { transport.connectCount == 1 })

    await client.suspend()
    gate.open()

    // The connection that arrives for a run that no longer counts is closed, not used.
    #expect(await waitUntil { connection.isClosed })
    #expect(isSuspended(await client.state))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func suspendingAClientThatIsNotRunningChangesNothing() async throws {
    let transport = FakeSocketTransport([.connection(FakeConnection())])
    let idle = makeClient(transport)
    await idle.suspend()
    await idle.resume()
    #expect(isIdle(await idle.state))
    #expect(transport.connectCount == 0)

    // A client closed on purpose is not brought back by the app coming to the front.
    let closed = makeClient(FakeSocketTransport([.connection(FakeConnection())]))
    await closed.connect()
    _ = await closed.nextEvent()
    await closed.close()
    await closed.suspend()
    await closed.resume()
    guard case .closed = await closed.state else {
        Issue.record("a closed client changed state")
        return
    }
}

@Test(.timeLimit(.minutes(1)))
func suspendingTwiceAndResumingTwiceIsHarmless() async throws {
    let transport = FakeSocketTransport([.connection(FakeConnection()), .connection(FakeConnection())])
    let client = makeClient(transport)
    await client.connect()
    _ = await client.nextEvent()

    await client.suspend()
    await client.suspend()
    await client.resume()
    await client.resume()

    #expect(await waitUntil { await client.state.isConnected })
    #expect(transport.connectCount == 2)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aReaderWaitingForRoomIsReleasedByASuspendSoItsRunEnds() async throws {
    let connection = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.inboundCapacity = 1
    configuration.overflow = .suspendReading
    let transport = FakeSocketTransport([.connection(connection), .connection(FakeConnection())])
    let client = makeClient(transport, configuration: configuration)
    await client.connect()
    _ = await client.nextEvent()
    // Two messages with room for one: the reader waits for the consumer to take the first.
    connection.push(text: "one")
    connection.push(text: "two")
    #expect(await waitUntil { connection.unread == 0 })

    await client.suspend()

    // The run that owned the connection ends only once its reader is released; it then closes the
    // connection a second time, with the normal code.
    #expect(await waitUntil { connection.closes == [1001, 1000] })
    await client.resume()
    #expect(await waitUntil { await client.state.isConnected })
    #expect(transport.connectCount == 2)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func followingTheAppSuspendsInTheBackgroundAndResumesInFront() async throws {
    let transport = FakeSocketTransport([.connection(FakeConnection()), .connection(FakeConnection())])
    let client = makeClient(transport)
    await client.connect()
    _ = await client.nextEvent()
    let (activity, input) = AsyncStream.makeStream(of: Bool.self)
    let following = Task { await client.follow(activity) }

    input.yield(false)
    #expect(await waitUntil { isSuspended(await client.state) })
    input.yield(true)
    #expect(await waitUntil { await client.state.isConnected })
    #expect(transport.connectCount == 2)

    // When the sequence ends, following ends and the client keeps its state.
    input.finish()
    await following.value
    #expect(await client.state.isConnected)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func followingEndsWhenItsTaskIsCancelled() async throws {
    let client = makeClient(FakeSocketTransport([.connection(FakeConnection())]))
    let (activity, input) = AsyncStream.makeStream(of: Bool.self)
    _ = input
    let following = Task { await client.follow(activity) }

    following.cancel()
    await following.value
    await client.close()
}
