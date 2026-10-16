import Foundation

/// A message of a WebSocket: text or bytes.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)

    /// The size on the wire, in bytes.
    public var byteCount: Int {
        switch self {
        case .text(let text): text.utf8.count
        case .binary(let data): data.count
        }
    }
}

/// Why a WebSocket operation failed, or why a connection ended.
public enum WebSocketError: Error, Sendable {
    /// The URL is not a `ws`, `wss`, `http` or `https` URL with a host. Nothing was sent.
    case invalidURL(String)
    /// The server refused the upgrade with an HTTP status. `401` and `403` mean the credentials
    /// were refused.
    case handshakeRejected(status: Int)
    /// The connection could not be made, or broke.
    case transport(TransportFailure)
    /// The server closed the connection with a close frame.
    case closedByServer(code: Int, reason: String)
    /// A message is bigger than the configured limit.
    case messageTooLarge(limit: Int)
    /// The server did not answer a ping in time, so the connection is taken to be dead.
    case heartbeatTimeout
    /// The client has no open connection. Nothing was sent, and nothing is kept to send later.
    case notConnected
    /// Credentials could not be obtained or renewed for the handshake.
    case authorizationFailed(underlying: any Error)
    case cancelled
}

/// How a connection was closed, for good.
public struct WebSocketClose: Sendable, Equatable {
    public enum Initiator: Sendable, Equatable {
        case client
        case server
    }

    public var code: Int
    public var reason: String
    public var initiator: Initiator

    public init(code: Int, reason: String = "", initiator: Initiator) {
        self.code = code
        self.reason = reason
        self.initiator = initiator
    }
}

/// Where a ``WebSocketClient`` is in its life.
public enum WebSocketState: Sendable {
    /// Never connected, or nothing asked for yet.
    case idle
    /// Making the first connection.
    case connecting
    case connected
    /// The connection was lost or could not be made, and a new one is attempted after `after`
    /// seconds. `attempt` counts the failures in a row.
    case reconnecting(attempt: Int, after: TimeInterval, cause: WebSocketError)
    /// Ended for good by the client or by the server, as the close says. No reconnection follows.
    case closed(WebSocketClose)
    /// Gave up: the failure is not worth repeating, or the attempts ran out. Calling
    /// ``WebSocketClient/connect()`` starts again.
    case failed(WebSocketError)
    /// Paused by ``WebSocketClient/suspend()``: no connection and none being made, but the client
    /// is not over — its events go on, and ``WebSocketClient/resume()`` connects again.
    case suspended

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// What a ``WebSocketClient`` tells its consumer, in the order it happened.
public enum WebSocketEvent: Sendable {
    case message(WebSocketMessage)
    /// A connection was made. After the first one `isReconnect` is true: messages may have been
    /// missed meanwhile, so this is the moment to ask the server for them, from the application's
    /// own cursor — the client does not replay or deduplicate anything.
    case connected(isReconnect: Bool)
    /// The connection ended. `cause` is `nil` when the client closed or suspended it.
    /// `willReconnect` says whether a new connection will be attempted without being asked; a
    /// suspended client waits for ``WebSocketClient/resume()``.
    case disconnected(cause: WebSocketError?, willReconnect: Bool)
    /// Messages were lost because the consumer did not keep up, under
    /// ``OverflowPolicy/resync``. The connection is dropped and re-made; resynchronise from the
    /// application's cursor when the next ``connected(isReconnect:)`` comes.
    case resyncRequired
}

/// What to do when messages arrive faster than the consumer takes them.
public enum OverflowPolicy: Sendable {
    /// Stop reading from the connection until there is room. Nothing is lost; the sender is held
    /// back by the connection's own flow control. A consumer that never reads stalls the
    /// connection, which the server may then close.
    case suspendReading
    /// Drop the message that does not fit, tell the consumer with
    /// ``WebSocketEvent/resyncRequired``, and reconnect, so that the consumer can ask for what it
    /// missed. Nothing is lost silently.
    case resync
}

/// Pings the server to find a dead connection that no close ever announced.
public struct Heartbeat: Sendable {
    /// Seconds between pings.
    public var interval: TimeInterval
    /// Seconds to wait for the answer before the connection is taken to be dead.
    public var timeout: TimeInterval

    public init(interval: TimeInterval = 30, timeout: TimeInterval = 10) {
        self.interval = interval
        self.timeout = timeout
    }
}

/// When and how long to wait before connecting again.
public struct ReconnectPolicy: Sendable {
    /// The most failures in a row before the client gives up; `nil` for never.
    public var maxAttempts: Int?
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// How far a wait may stray from its nominal length, as a fraction.
    public var jitter: Double
    /// How long a connection must last to count as a success, which resets the failures in a
    /// row. One that is dropped sooner does not, so a server that accepts and drops at once is not
    /// hammered.
    public var stableAfter: TimeInterval
    /// Close codes after which the client does not reconnect: the server ended the session, or the
    /// client did something that reconnecting would repeat. Any other code, a lost connection, and
    /// a server error are temporary.
    public var finalCloseCodes: Set<Int>

    public init(
        maxAttempts: Int? = 10,
        initialDelay: TimeInterval = 1,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 30,
        jitter: Double = 0.2,
        stableAfter: TimeInterval = 10,
        finalCloseCodes: Set<Int> = [1000, 1002, 1003, 1007, 1008, 1009, 1010]
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.stableAfter = stableAfter
        self.finalCloseCodes = finalCloseCodes
    }

    /// Never reconnects.
    public static let never = ReconnectPolicy(maxAttempts: 0)

    func delay(afterFailure failures: Int, random: Double) -> TimeInterval {
        let nominal = min(maxDelay, initialDelay * pow(multiplier, Double(failures - 1)))
        return max(0, nominal * (1 + jitter * (random * 2 - 1)))
    }
}

/// Limits and rules for one ``WebSocketClient``.
public struct WebSocketConfiguration: Sendable {
    /// The largest message, in bytes, sent or received. A larger one received ends the connection
    /// with ``WebSocketError/messageTooLarge(limit:)``, which is not retried.
    public var maxMessageBytes: Int
    /// How many received events wait for the consumer before ``overflow`` applies.
    public var inboundCapacity: Int
    public var overflow: OverflowPolicy
    /// `nil` sends no pings.
    public var heartbeat: Heartbeat?
    public var reconnect: ReconnectPolicy

    public init(
        maxMessageBytes: Int = 1 << 20,
        inboundCapacity: Int = 256,
        overflow: OverflowPolicy = .suspendReading,
        heartbeat: Heartbeat? = nil,
        reconnect: ReconnectPolicy = ReconnectPolicy()
    ) {
        self.maxMessageBytes = maxMessageBytes
        self.inboundCapacity = inboundCapacity
        self.overflow = overflow
        self.heartbeat = heartbeat
        self.reconnect = reconnect
    }
}

/// An open WebSocket connection, as a transport gives it.
///
/// A connection is used by one client at a time: one task reads, and sends come one at a time. It
/// is not reused after it fails.
public protocol WebSocketConnection: Sendable {
    func send(_ message: WebSocketMessage) async throws(WebSocketError)

    /// The next message. Throws when the connection ends — ``WebSocketError/closedByServer(code:reason:)``
    /// for a close frame, ``WebSocketError/transport(_:)`` for a broken connection — and when
    /// ``close(code:reason:)`` is called meanwhile.
    func receive() async throws(WebSocketError) -> WebSocketMessage

    /// Sends a ping and returns when the pong has come.
    func ping() async throws(WebSocketError)

    /// Closes the connection and makes every pending call throw. Safe to call more than once.
    func close(code: Int, reason: String?)
}

/// Opens WebSocket connections: the one place that touches the network.
public protocol WebSocketTransport: Sendable {
    /// Makes the connection and finishes the upgrade handshake.
    ///
    /// - Parameters:
    ///   - request: The handshake request; its URL has a `ws` or `wss` scheme (or `http` /
    ///     `https`, which mean the same) and its headers carry any credentials.
    ///   - maxMessageBytes: The largest message the connection accepts.
    /// - Throws: ``WebSocketError/handshakeRejected(status:)`` when the server refuses the upgrade,
    ///   ``WebSocketError/transport(_:)``, ``WebSocketError/invalidURL(_:)`` or
    ///   ``WebSocketError/cancelled``. Cancelling the task cancels the attempt.
    func connect(_ request: HTTPRequest, maxMessageBytes: Int) async throws(WebSocketError)
        -> any WebSocketConnection
}
