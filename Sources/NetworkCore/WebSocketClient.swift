import Foundation

/// A WebSocket that stays up: it connects, reads, pings, and reconnects after a loss, and tells
/// its consumer what happened in order.
///
/// **Life.** ``connect()`` starts it; ``close(code:reason:)`` ends it. Between them the client keeps a
/// connection open on its own, making a new one when the old one is lost, as the
/// ``ReconnectPolicy`` allows. Closing is the only way to stop it — the client does not watch the
/// app's lifecycle, so an app that must not hold a socket in the background closes it when it
/// goes there and connects again when it returns. Hiding a screen does not close it: the
/// connection belongs to whoever created the client.
///
/// **Ownership.** The client holds a task while it is connected or waiting to reconnect, and that
/// task holds the client. Close the client when done with it; releasing it is not enough.
///
/// **Receiving.** Everything that happens arrives as a ``WebSocketEvent`` from ``nextEvent()``, in order:
/// messages, connections made, connections lost. There is one consumer; pulling the events one by one
/// gives the queue a real limit, which is what lets overflow be a decision (see ``OverflowPolicy``)
/// and not a loss. One task reads the connection, so messages arrive in the order they were sent.
///
/// **Sending.** ``send(_:)`` writes one message at a time, in the order the calls were made, and
/// throws ``WebSocketError/notConnected`` when there is no open connection. Messages are never
/// queued for a later connection: whether to send again after a reconnect is for the application to
/// decide, since it alone knows whether the message is still wanted.
///
/// **What it does not do.** After a reconnect, the messages sent while the connection was down are
/// gone, and the client cannot tell which. It does not replay, acknowledge or deduplicate: a cursor,
/// acknowledgements and a resynchronisation request belong to the application's protocol, and
/// ``WebSocketEvent/connected(isReconnect:)`` is where it starts them.
///
/// **Credentials.** If an authorizer is given, the handshake is signed by it, and a handshake
/// refused with `401` renews the credentials once and tries again.
public actor WebSocketClient {
    private enum SessionEnd {
        case lost(WebSocketError)
        case overflow
    }

    private enum Delivery {
        case delivered
        case overflow
        case stale
    }

    private let request: HTTPRequest
    private let transport: any WebSocketTransport
    private let configuration: WebSocketConfiguration
    private let authorizer: (any HTTPAuthorizer)?
    private let environment: NetworkEnvironment

    /// Which connect-and-reconnect run is current. Everything a run does after an `await` checks
    /// that it is still the current one, so a connection that outlived a close, or a callback that
    /// comes late, cannot change the client that replaced it.
    private var generation = 0
    private var runner: Task<Void, Never>?
    private var connection: (any WebSocketConnection)?
    private var hasConnectedBefore = false

    /// Where the client is.
    public private(set) var state: WebSocketState = .idle
    private var stateObservers: [UUID: AsyncStream<WebSocketState>.Continuation] = [:]

    private var queue: [WebSocketEvent] = []
    private var consumer: CheckedContinuation<WebSocketEvent?, Never>?
    private var readerWaitingForRoom: CheckedContinuation<Void, Never>?
    private var isFinished = false

    /// Why the current connection ended, the first reason that is set. Whoever finds the connection
    /// finished records the reason *before* closing it: closing makes the reader fail too, and its
    /// "cancelled" must not stand in for the real cause.
    private var sessionEnd: SessionEnd?

    private var isSending = false
    private var waitingToSend: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - request: The handshake request. Its URL is `ws` or `wss`; the headers are sent with the
    ///     upgrade.
    ///   - transport: Opens the connections.
    ///   - authorizer: Signs the handshake, if the server wants credentials.
    public init(
        request: HTTPRequest,
        transport: any WebSocketTransport,
        configuration: WebSocketConfiguration = WebSocketConfiguration(),
        authorizer: (any HTTPAuthorizer)? = nil,
        environment: NetworkEnvironment = NetworkEnvironment()
    ) {
        self.request = request
        self.transport = transport
        self.configuration = configuration
        self.authorizer = authorizer
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Starts connecting. Does nothing while the client is already connecting, connected or waiting
    /// to reconnect; after it was closed or gave up, starts again.
    public func connect() {
        switch state {
        case .connecting, .connected, .reconnecting: return
        case .idle, .closed, .failed: break
        }
        generation += 1
        isFinished = false
        hasConnectedBefore = false
        setState(.connecting)
        let current = generation
        runner = Task { await self.run(generation: current) }
    }

    /// Ends the client for good: the connection is closed with `code`, reconnecting and pinging
    /// stop, and the consumer gets what was already queued and then `nil`. A message that is being
    /// read at this moment may be lost.
    ///
    /// Closing a client that is not running only records the close.
    public func close(code: Int = 1000, reason: String? = nil) {
        generation += 1
        runner?.cancel()
        runner = nil
        let open = connection
        connection = nil
        open?.close(code: code, reason: reason)
        if open != nil {
            push(.disconnected(cause: nil, willReconnect: false))
        }
        finish(.closed(WebSocketClose(code: code, reason: reason ?? "", initiator: .client)))
    }

    /// The state now, then each change. Changes between two reads collapse into the latest.
    public func states() -> AsyncStream<WebSocketState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: WebSocketState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuation.yield(state)
        stateObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forgetObserver(id) }
        }
        return stream
    }

    private func forgetObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    private func setState(_ new: WebSocketState) {
        state = new
        for continuation in stateObservers.values { continuation.yield(new) }
    }

    // MARK: Sending

    /// Sends `message` on the open connection.
    ///
    /// - Throws: ``WebSocketError/notConnected`` without an open connection;
    ///   ``WebSocketError/messageTooLarge(limit:)``; the connection's error if the write fails, in
    ///   which case the connection is about to be reported lost and nothing says whether the message
    ///   arrived.
    public func send(_ message: WebSocketMessage) async throws(WebSocketError) {
        if message.byteCount > configuration.maxMessageBytes {
            throw .messageTooLarge(limit: configuration.maxMessageBytes)
        }
        guard connection != nil else { throw .notConnected }

        await acquireSendTurn()
        defer { releaseSendTurn() }
        // The wait for the turn may have outlasted the connection.
        guard let open = connection else { throw .notConnected }

        try await open.send(message)
    }

    private func acquireSendTurn() async {
        guard isSending else {
            isSending = true
            return
        }
        await withCheckedContinuation { waitingToSend.append($0) }
    }

    private func releaseSendTurn() {
        if waitingToSend.isEmpty {
            isSending = false
        } else {
            waitingToSend.removeFirst().resume()
        }
    }

    // MARK: Receiving

    /// The next event, waiting for one if none is queued. Returns `nil` when the client has been
    /// closed or has given up and everything it queued has been taken, and when the waiting task
    /// is cancelled. Use one consumer: events are not copied to several.
    public func nextEvent() async -> WebSocketEvent? {
        if !queue.isEmpty {
            let event = queue.removeFirst()
            readerWaitingForRoom?.resume()
            readerWaitingForRoom = nil
            return event
        }
        if isFinished { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                consumer?.resume(returning: nil)
                consumer = continuation
                // A task cancelled before it got here has already run its handler.
                if Task.isCancelled { dropConsumer() }
            }
        } onCancel: {
            Task { await self.dropConsumer() }
        }
    }

    /// The events as a sequence, for `for await`. Ends when ``nextEvent()`` returns `nil`.
    public nonisolated var events: Events { Events(client: self) }

    public struct Events: AsyncSequence, Sendable {
        public typealias Element = WebSocketEvent
        fileprivate let client: WebSocketClient

        public struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate let client: WebSocketClient

            public mutating func next() async -> WebSocketEvent? { await client.nextEvent() }
        }

        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(client: client) }
    }

    private func dropConsumer() {
        consumer?.resume(returning: nil)
        consumer = nil
    }

    /// Hands an event to the waiting consumer, or queues it. Used for events that are not messages,
    /// which are few and never wait for room.
    private func push(_ event: WebSocketEvent) {
        if let waiting = consumer {
            consumer = nil
            waiting.resume(returning: event)
        } else {
            queue.append(event)
        }
    }

    private func finish(_ final: WebSocketState) {
        setState(final)
        isFinished = true
        readerWaitingForRoom?.resume()
        readerWaitingForRoom = nil
        if queue.isEmpty { dropConsumer() }
    }

    // MARK: The run

    private func run(generation gen: Int) async {
        var failures = 0
        while gen == generation, !Task.isCancelled {
            let open: any WebSocketConnection
            do throws(WebSocketError) {
                open = try await openConnection()
            } catch {
                guard gen == generation else { return }
                if case .cancelled = error { return }

                failures += 1
                if shouldGiveUp(after: error, failures: failures) {
                    finish(.failed(error))
                    return
                }
                guard await backOff(failures: failures, cause: error, generation: gen) else {
                    return
                }
                continue
            }
            guard gen == generation else {
                open.close(code: 1000, reason: nil)
                return
            }

            connection = open
            let isReconnect = hasConnectedBefore
            hasConnectedBefore = true
            setState(.connected)
            push(.connected(isReconnect: isReconnect))
            let connectedAt = environment.now()

            let end = await runSession(open, generation: gen)
            guard gen == generation else { return }

            connection = nil
            let cause: WebSocketError
            switch end {
            case .overflow:
                cause = .transport(TransportFailure(kind: .other, underlying: Overflow()))
            case .lost(let error): cause = error
            }
            if environment.now().timeIntervalSince(connectedAt)
                >= configuration.reconnect.stableAfter
            {
                failures = 0
            }
            failures += 1
            let final = isFinal(cause)
            let giveUp = final || exceedsAttempts(failures)
            push(.disconnected(cause: cause, willReconnect: !giveUp))
            if giveUp {
                if case .closedByServer(let code, let reason) = cause, final {
                    finish(.closed(WebSocketClose(code: code, reason: reason, initiator: .server)))
                } else {
                    finish(.failed(cause))
                }
                return
            }
            guard await backOff(failures: failures, cause: cause, generation: gen) else { return }
        }
    }

    private struct Overflow: Error {}

    private func shouldGiveUp(after error: WebSocketError, failures: Int) -> Bool {
        isFinal(error) || exceedsAttempts(failures)
    }

    private func exceedsAttempts(_ failures: Int) -> Bool {
        guard let limit = configuration.reconnect.maxAttempts else { return false }

        return failures > limit
    }

    /// Whether repeating would only repeat the failure: refused credentials, a refusal that is not
    /// about load, a certificate that does not verify, a message that does not fit, and a close
    /// by which the server ended the session.
    private func isFinal(_ error: WebSocketError) -> Bool {
        switch error {
        case .invalidURL, .messageTooLarge, .authorizationFailed, .cancelled: true
        case .notConnected, .heartbeatTimeout: false
        case .handshakeRejected(let status): !(status == 408 || status == 429 || status >= 500)
        case .transport(let failure): failure.kind == .secureConnectionFailed
        case .closedByServer(let code, _): configuration.reconnect.finalCloseCodes.contains(code)
        }
    }

    private func backOff(failures: Int, cause: WebSocketError, generation gen: Int) async -> Bool {
        let delay = configuration.reconnect.delay(
            afterFailure: failures,
            random: environment.random()
        )
        setState(.reconnecting(attempt: failures, after: delay, cause: cause))
        do {
            try await environment.sleep(delay)
        } catch {
            return false
        }
        return gen == generation
    }

    // MARK: Opening

    private func openConnection() async throws(WebSocketError) -> any WebSocketConnection {
        var hasRenewed = false
        while true {
            var outgoing = request
            var stamp: Int?
            if let authorizer {
                // The authorizer knows `http` and `https` origins; a `ws` URL is the same server.
                let probe = HTTPRequest(
                    .get,
                    Self.httpEquivalent(of: request.url),
                    headers: request.headers
                )
                let authorized: AuthorizedRequest
                do throws(HTTPError) {
                    authorized = try await authorizer.authorize(probe)
                } catch {
                    throw .authorizationFailed(underlying: error)
                }
                outgoing.headers = authorized.request.headers
                stamp = authorized.stamp
            }
            do throws(WebSocketError) {
                return try await transport.connect(
                    outgoing,
                    maxMessageBytes: configuration.maxMessageBytes
                )
            } catch {
                if case .handshakeRejected(401) = error, let authorizer, let stamp, !hasRenewed {
                    let renewed: Bool
                    do throws(HTTPError) {
                        renewed = try await authorizer.handleUnauthorized(stamp: stamp)
                    } catch {
                        throw .authorizationFailed(underlying: error)
                    }
                    if renewed {
                        hasRenewed = true
                        continue
                    }
                }
                throw error
            }
        }
    }

    private static func httpEquivalent(of url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        switch parts.scheme?.lowercased() {
        case "ws": parts.scheme = "http"
        case "wss": parts.scheme = "https"
        default: break
        }
        return parts.url ?? url
    }

    // MARK: One connection

    /// Reads and pings until the connection ends, and says how. When either side finishes, the
    /// connection is closed so that the other one, which may be waiting on it, finishes too.
    private func runSession(_ open: any WebSocketConnection, generation gen: Int) async
        -> SessionEnd
    {
        sessionEnd = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.readLoop(open, generation: gen) }
            if let heartbeat = configuration.heartbeat {
                group.addTask { await self.heartbeatLoop(open, heartbeat) }
            }
            await group.next()
            open.close(code: 1000, reason: nil)
            group.cancelAll()
        }
        return sessionEnd ?? .lost(.cancelled)
    }

    private func noteEnd(_ end: SessionEnd) {
        if sessionEnd == nil { sessionEnd = end }
    }

    private func readLoop(_ open: any WebSocketConnection, generation gen: Int) async {
        while true {
            let message: WebSocketMessage
            do throws(WebSocketError) {
                message = try await open.receive()
            } catch {
                noteEnd(.lost(error))
                return
            }
            if message.byteCount > configuration.maxMessageBytes {
                noteEnd(.lost(.messageTooLarge(limit: configuration.maxMessageBytes)))
                return
            }
            switch await deliver(message, generation: gen) {
            case .delivered: continue
            case .overflow:
                noteEnd(.overflow)
                return
            case .stale:
                noteEnd(.lost(.cancelled))
                return
            }
        }
    }

    private func deliver(_ message: WebSocketMessage, generation gen: Int) async -> Delivery {
        while true {
            guard gen == generation else { return .stale }

            if let waiting = consumer {
                consumer = nil
                waiting.resume(returning: .message(message))
                return .delivered
            }
            if queue.count < configuration.inboundCapacity {
                queue.append(.message(message))
                return .delivered
            }
            switch configuration.overflow {
            case .resync:
                queue.append(.resyncRequired)
                return .overflow
            case .suspendReading:
                await withCheckedContinuation { readerWaitingForRoom = $0 }
            }
        }
    }

    private func heartbeatLoop(_ open: any WebSocketConnection, _ heartbeat: Heartbeat) async {
        while true {
            do {
                try await environment.sleep(heartbeat.interval)
            } catch {
                return
            }
            if let failure = await pingOnce(open, timeout: heartbeat.timeout) {
                noteEnd(.lost(failure))
                return
            }
        }
    }

    /// Pings and waits for the pong; returns the failure, or `nil` when the pong came.
    private func pingOnce(_ open: any WebSocketConnection, timeout: TimeInterval) async
        -> WebSocketError?
    {
        let environment = environment
        return await withTaskGroup(of: WebSocketError?.self) { group in
            group.addTask {
                do throws(WebSocketError) {
                    try await open.ping()
                    return nil
                } catch {
                    return error
                }
            }
            group.addTask {
                do {
                    try await environment.sleep(timeout)
                    return .heartbeatTimeout
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            if case .heartbeatTimeout? = first {
                // A ping that is never answered does not end by itself, and the group waits for
                // it. Say why first, then close the connection to end the ping.
                noteEnd(.lost(.heartbeatTimeout))
                open.close(code: 1001, reason: "heartbeat")
            }
            group.cancelAll()
            return first
        }
    }
}
