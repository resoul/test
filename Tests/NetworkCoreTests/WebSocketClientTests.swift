import Foundation
import NetworkCore
import Testing
import os

private func connected(_ event: WebSocketEvent?, reconnect: Bool) -> Bool {
    if case .connected(let isReconnect)? = event { return isReconnect == reconnect }
    return false
}

private func disconnected(_ event: WebSocketEvent?, willReconnect: Bool) -> Bool {
    if case .disconnected(_, let will)? = event { return will == willReconnect }
    return false
}

private let lost = WebSocketError.transport(
    TransportFailure(kind: .connectionLost, underlying: URLError(.networkConnectionLost))
)

@Test(.timeLimit(.minutes(1)))
func aClientConnectsAndDeliversMessagesInTheOrderTheyCame() async throws {
    let connection = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(connection)]))

    await client.connect()
    #expect(connected(await client.nextEvent(), reconnect: false))
    #expect(await client.state.isConnected)
    for number in 1...50 { connection.push(text: "m\(number)") }

    for number in 1...50 {
        let event = await client.nextEvent()
        #expect(isMessage(event, "m\(number)"), "message \(number)")
    }
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func binaryAndTextMessagesBothArrive() async throws {
    let connection = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(connection)]))
    await client.connect()
    _ = await client.nextEvent()

    connection.push(.binary(Data([1, 2, 3])))
    connection.push(.text("héllo"))

    guard case .message(.binary(let data))? = await client.nextEvent() else {
        Issue.record("The binary message did not arrive as binary")
        return
    }
    #expect(data == Data([1, 2, 3]))
    #expect(isMessage(await client.nextEvent(), "héllo"))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func sendsReachTheConnectionOneAtATimeInTheOrderOfTheCalls() async throws {
    let connection = FakeConnection()
    connection.setSendDelay(.milliseconds(5))
    let client = makeClient(FakeSocketTransport([.connection(connection)]))
    await client.connect()
    _ = await client.nextEvent()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for number in 0..<10 { group.addTask { try await client.send(.text("s\(number)")) } }
        try await group.waitForAll()
    }

    #expect(connection.sent.count == 10)
    // The connection never had two writes going at once.
    #expect(connection.maxActiveSends == 1)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aSendWithoutAnOpenConnectionIsRefusedAndNothingIsKept() async throws {
    let first = FakeConnection()
    let second = FakeConnection()
    // The second handshake is held, so that the time between the loss and the new connection is
    // as long as the test needs.
    let gate = FakeSocketTransport.Gate()
    let transport = FakeSocketTransport([.connection(first), .slow(second, gate)])
    let client = makeClient(transport)

    // Before connecting.
    await #expect {
        try await client.send(.text("early"))
    } throws: { error in
        if case WebSocketError.notConnected = error { return true }
        return false
    }

    await client.connect()
    _ = await client.nextEvent()
    first.fail(lost)
    // Between the loss and the new connection.
    #expect(await waitUntil { await !client.state.isConnected })
    await #expect {
        try await client.send(.text("while down"))
    } throws: { error in
        if case WebSocketError.notConnected = error { return true }
        return false
    }

    // Once reconnected, what was refused is not sent late.
    gate.open()
    #expect(await waitUntil { await client.state.isConnected })
    #expect(second.sent.isEmpty)
    #expect(first.sent.isEmpty)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aMessageOverTheLimitIsNotSent() async throws {
    let connection = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.maxMessageBytes = 8
    let client = makeClient(
        FakeSocketTransport([.connection(connection)]),
        configuration: configuration
    )
    await client.connect()
    _ = await client.nextEvent()

    await #expect {
        try await client.send(.text("123456789"))
    } throws: { error in
        guard case WebSocketError.messageTooLarge(let limit) = error else { return false }
        return limit == 8
    }
    try await client.send(.text("12345678"))

    #expect(connection.sent == [.text("12345678")])
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aMessageTooLargeFromTheServerEndsTheClientWithoutRetrying() async throws {
    let connection = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.maxMessageBytes = 4
    let transport = FakeSocketTransport([.connection(connection)])
    let client = makeClient(transport, configuration: configuration)
    await client.connect()
    _ = await client.nextEvent()

    connection.push(text: "much too long")

    #expect(await waitUntil { if case .failed = await client.state { true } else { false } })
    #expect(transport.connectCount == 1)
    guard case .failed(.messageTooLarge(let limit)) = await client.state else {
        Issue.record("The state was not a size failure")
        return
    }
    #expect(limit == 4)
}

@Test(.timeLimit(.minutes(1)))
func aLostConnectionIsRemadeAndTheConsumerIsToldInOrder() async throws {
    let first = FakeConnection()
    let second = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(first), .connection(second)]))
    await client.connect()
    _ = await client.nextEvent()
    first.push(text: "before")
    first.fail(lost)

    let events = await take(3, from: client)

    #expect(isMessage(events[0], "before"))
    #expect(disconnected(events[1], willReconnect: true))
    #expect(connected(events[2], reconnect: true))
    second.push(text: "after")
    #expect(isMessage(await client.nextEvent(), "after"))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func backoffGrowsWithEachFailureAndStartsOverAfterALongConnection() async throws {
    let clock = TestClock()
    let sleeps = Sleeps()
    let connections = (0..<3).map { _ in FakeConnection() }
    let transport = FakeSocketTransport([
        .failure(lost), .failure(lost), .failure(lost),
        .connection(connections[0]),
        .connection(connections[1]),
        .connection(connections[2]),
    ])
    let client = makeClient(transport, sleeps: sleeps, clock: clock)

    await client.connect()
    _ = await client.nextEvent()
    // Three failures: 1, 2, 4 seconds (jitter is zero at the middle of its range).
    #expect(sleeps.delays == [1, 2, 4])

    // A connection that lasted long counts as a success: the next failure waits one second again.
    clock.advance(60)
    connections[0].fail(lost)
    _ = await take(2, from: client)
    #expect(sleeps.delays == [1, 2, 4, 1])

    // One that is dropped at once does not.
    connections[1].fail(lost)
    _ = await take(2, from: client)
    #expect(sleeps.delays == [1, 2, 4, 1, 2])
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func theClientGivesUpWhenTheAttemptsRunOutAndConnectStartsAgain() async throws {
    var configuration = WebSocketConfiguration()
    configuration.reconnect = ReconnectPolicy(maxAttempts: 2)
    let connection = FakeConnection()
    let transport = FakeSocketTransport([
        .failure(lost), .failure(lost), .failure(lost), .connection(connection),
    ])
    let client = makeClient(transport, configuration: configuration)

    await client.connect()

    #expect(await waitUntil { if case .failed = await client.state { true } else { false } })
    #expect(transport.connectCount == 3)
    #expect(await client.nextEvent() == nil)

    await client.connect()
    #expect(connected(await client.nextEvent(), reconnect: false))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aRefusedHandshakeIsRetriedOnlyWhenItIsTemporary() async throws {
    for (status, retried) in [
        (401, false), (403, false), (404, false), (503, true), (429, true), (408, true),
    ] {
        let connection = FakeConnection()
        let transport = FakeSocketTransport([
            .failure(.handshakeRejected(status: status)), .connection(connection),
        ])
        let client = makeClient(transport)

        await client.connect()

        if retried {
            #expect(
                connected(await client.nextEvent(), reconnect: false),
                "\(status) should be retried"
            )
            #expect(transport.connectCount == 2)
        } else {
            #expect(
                await waitUntil { if case .failed = await client.state { true } else { false } }
            )
            #expect(transport.connectCount == 1, "\(status) must not be retried")
        }
        await client.close()
    }
}

@Test(.timeLimit(.minutes(1)))
func aServerThatEndsTheSessionIsFinalAndOneThatGoesAwayIsNot() async throws {
    // 1000: the session is over.
    let first = FakeConnection()
    let finalTransport = FakeSocketTransport([.connection(first)])
    let ended = makeClient(finalTransport)
    await ended.connect()
    _ = await ended.nextEvent()
    first.fail(.closedByServer(code: 1000, reason: "done"))

    #expect(disconnected(await ended.nextEvent(), willReconnect: false))
    #expect(await ended.nextEvent() == nil)
    guard case .closed(let close) = await ended.state else {
        Issue.record("The state was not closed")
        return
    }
    #expect(close == WebSocketClose(code: 1000, reason: "done", initiator: .server))
    #expect(finalTransport.connectCount == 1)

    // 1001: the server is going away; come back.
    let goingAway = FakeConnection()
    let transport = FakeSocketTransport([.connection(goingAway), .connection(FakeConnection())])
    let client = makeClient(transport)
    await client.connect()
    _ = await client.nextEvent()
    goingAway.fail(.closedByServer(code: 1001, reason: ""))
    #expect(disconnected(await client.nextEvent(), willReconnect: true))
    #expect(connected(await client.nextEvent(), reconnect: true))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func closingEndsTheClientForGoodAndTheConsumerDrainsWhatIsQueued() async throws {
    let connection = FakeConnection()
    let transport = FakeSocketTransport([.connection(connection), .connection(FakeConnection())])
    let client = makeClient(transport)
    await client.connect()
    _ = await client.nextEvent()
    connection.push(text: "queued")
    #expect(await waitUntil { connection.unread == 0 })

    await client.close(code: 1000, reason: "bye")

    #expect(isMessage(await client.nextEvent(), "queued"))
    #expect(disconnected(await client.nextEvent(), willReconnect: false))
    #expect(await client.nextEvent() == nil)
    #expect(connection.closes.first == 1000)
    guard case .closed(let close) = await client.state else {
        Issue.record("The state was not closed")
        return
    }
    #expect(close == WebSocketClose(code: 1000, reason: "bye", initiator: .client))
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.connectCount == 1, "A closed client reconnected")
}

@Test(.timeLimit(.minutes(1)))
func closingDuringTheWaitBeforeAReconnectStopsIt() async throws {
    let connection = FakeConnection()
    let transport = FakeSocketTransport([.connection(connection), .failure(lost)])
    // A real wait, long enough that only the close can end it.
    let environment = NetworkEnvironment(random: { 0.5 })
    var configuration = WebSocketConfiguration()
    configuration.reconnect = ReconnectPolicy(initialDelay: 600)
    let client = WebSocketClient(
        request: HTTPRequest(.get, socketURL),
        transport: transport,
        configuration: configuration,
        environment: environment
    )
    await client.connect()
    _ = await client.nextEvent()
    connection.fail(lost)
    #expect(await waitUntil { if case .reconnecting = await client.state { true } else { false } })

    await client.close()

    #expect(transport.connectCount == 1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.connectCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func aConnectionThatArrivesAfterTheClientWasClosedIsClosedAndNeverUsed() async throws {
    let late = FakeConnection()
    let gate = FakeSocketTransport.Gate()
    let transport = FakeSocketTransport([.slow(late, gate)])
    let client = makeClient(transport)
    await client.connect()
    #expect(await waitUntil { transport.connectCount == 1 })

    await client.close()
    gate.open()

    #expect(await waitUntil { late.isClosed })
    #expect(await client.state.isConnected == false)
    late.push(text: "ignored")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await client.nextEvent() == nil)
}

@Test(.timeLimit(.minutes(1)))
func aLateFailureOfAnOldConnectionDoesNotDisturbTheNewOne() async throws {
    let old = FakeConnection()
    let new = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(old), .connection(new)]))
    await client.connect()
    _ = await client.nextEvent()
    old.fail(lost)
    _ = await take(2, from: client)

    // The old connection speaks again after it was replaced.
    old.fail(lost)
    old.push(text: "ghost")
    new.push(text: "real")

    #expect(isMessage(await client.nextEvent(), "real"))
    #expect(await client.state.isConnected)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aSlowConsumerHoldsTheConnectionBackWithoutLosingAnything() async throws {
    let connection = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.inboundCapacity = 3
    configuration.overflow = .suspendReading
    let client = makeClient(
        FakeSocketTransport([.connection(connection)]),
        configuration: configuration
    )
    await client.connect()
    _ = await client.nextEvent()
    for number in 1...10 { connection.push(text: "m\(number)") }

    // Reading stops while the queue is full: most of the messages are still waiting in the
    // connection.
    #expect(await waitUntil { connection.unread <= 7 })
    try await Task.sleep(for: .milliseconds(30))
    #expect(connection.unread >= 6)

    for number in 1...10 {
        #expect(isMessage(await client.nextEvent(), "m\(number)"), "message \(number)")
    }
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func underResyncAnOverflowIsReportedAndTheConnectionIsRemade() async throws {
    let first = FakeConnection()
    let second = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.inboundCapacity = 2
    configuration.overflow = .resync
    let client = makeClient(
        FakeSocketTransport([.connection(first), .connection(second)]),
        configuration: configuration
    )
    await client.connect()
    _ = await client.nextEvent()
    for number in 1...5 { first.push(text: "m\(number)") }

    // The consumer was not reading; now it reads everything there is.
    #expect(await waitUntil { first.isClosed })
    let events = await take(5, from: client)

    #expect(isMessage(events[0], "m1"))
    #expect(isMessage(events[1], "m2"))
    guard case .resyncRequired = events[2] else {
        Issue.record("The overflow was not reported")
        return
    }
    #expect(disconnected(events[3], willReconnect: true))
    #expect(connected(events[4], reconnect: true))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aPingThatIsNeverAnsweredDeclaresTheConnectionDeadAndItIsRemade() async throws {
    let silent = FakeConnection()
    silent.setPingBehavior(.neverAnswer)
    let healthy = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.heartbeat = Heartbeat(interval: 0.03, timeout: 0.05)
    let client = makeClient(
        FakeSocketTransport([.connection(silent), .connection(healthy)]),
        configuration: configuration
    )
    await client.connect()
    _ = await client.nextEvent()

    guard case .disconnected(let cause, true)? = await client.nextEvent() else {
        Issue.record("The silent connection was not reported lost")
        return
    }
    guard case .heartbeatTimeout? = cause else {
        Issue.record("The cause was not a heartbeat timeout")
        return
    }
    #expect(connected(await client.nextEvent(), reconnect: true))
    #expect(silent.isClosed)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aHealthyConnectionKeepsBeingPingedAndStaysUp() async throws {
    let connection = FakeConnection()
    var configuration = WebSocketConfiguration()
    configuration.heartbeat = Heartbeat(interval: 0.02, timeout: 0.5)
    let client = makeClient(
        FakeSocketTransport([.connection(connection)]),
        configuration: configuration
    )
    await client.connect()
    _ = await client.nextEvent()

    #expect(await waitUntil { connection.pings >= 3 })

    #expect(await client.state.isConnected)
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aFailedPingIsALostConnection() async throws {
    let broken = FakeConnection()
    broken.setPingBehavior(.fail(lost))
    var configuration = WebSocketConfiguration()
    configuration.heartbeat = Heartbeat(interval: 0.02, timeout: 0.5)
    let client = makeClient(
        FakeSocketTransport([.connection(broken), .connection(FakeConnection())]),
        configuration: configuration
    )
    await client.connect()
    _ = await client.nextEvent()

    #expect(disconnected(await client.nextEvent(), willReconnect: true))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func stateChangesAreObservableStartingWithTheCurrentOne() async throws {
    let connection = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(connection)]))
    let states = await client.states()
    var iterator = states.makeAsyncIterator()

    guard case .idle? = await iterator.next() else {
        Issue.record("The first state was not idle")
        return
    }
    await client.connect()
    #expect(await waitUntil { await client.state.isConnected })
    await client.close()

    var seen: [String] = []
    while let state = await iterator.next() {
        switch state {
        case .connecting: seen.append("connecting")
        case .connected: seen.append("connected")
        case .closed: seen.append("closed")
        default: seen.append("other")
        }
        if case .closed = state { break }
    }
    // Changes may collapse into the latest, but the end is always seen.
    #expect(seen.last == "closed")
}

@Test(.timeLimit(.minutes(1)))
func aCancelledConsumerStopsWaitingAndLosesNothing() async throws {
    let connection = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(connection)]))
    await client.connect()
    _ = await client.nextEvent()

    let waiting = Task { await client.nextEvent() }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    #expect(await waiting.value == nil)

    // An event that comes after is still there for the next reader.
    connection.push(text: "kept")
    #expect(isMessage(await client.nextEvent(), "kept"))
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func theEventsSequenceEndsWhenTheClientCloses() async throws {
    let connection = FakeConnection()
    let client = makeClient(FakeSocketTransport([.connection(connection)]))
    let reader = Task { () -> [String] in
        var seen: [String] = []
        for await event in client.events {
            switch event {
            case .message(.text(let text)): seen.append(text)
            case .connected: seen.append("connected")
            case .disconnected: seen.append("disconnected")
            default: seen.append("other")
            }
        }
        return seen
    }
    await client.connect()
    #expect(await waitUntil { await client.state.isConnected })
    connection.push(text: "one")
    #expect(await waitUntil { connection.unread == 0 })
    try await Task.sleep(for: .milliseconds(20))

    await client.close()

    #expect(await reader.value == ["connected", "one", "disconnected"])
}
