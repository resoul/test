import Foundation
import Network
import NetworkCore
import os

/// A WebSocket server on the loopback interface, built on the system's own WebSocket protocol, for
/// tests that need a real connection. It remembers what it was sent and can push, close and drop.
final class LocalWebSocketServer: Sendable {
    enum Decision: Sendable {
        case accept
        /// The system's server can refuse an upgrade but not choose the status; to answer an
        /// upgrade with a particular status, use ``LocalServer``.
        case reject
    }

    struct Handshake: Sendable {
        var headers: [String: String]
    }

    typealias Handler = @Sendable (WebSocketMessage, LocalWebSocketServer) -> Void

    let port: UInt16
    private let listener: NWListener
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let handshakeLog: OSAllocatedUnfairLock<[Handshake]>

    private struct State {
        var connections: [UUID: NWConnection] = [:]
        var received: [WebSocketMessage] = []
        var closeCodes: [UInt16] = []
        var totalConnections = 0
        var answersPings = true
    }

    var received: [WebSocketMessage] { state.withLock { $0.received } }
    var handshakes: [Handshake] { handshakeLog.withLock { $0 } }
    var openConnections: Int { state.withLock { $0.connections.count } }
    var totalConnections: Int { state.withLock { $0.totalConnections } }
    /// The close codes clients sent.
    var closeCodes: [UInt16] { state.withLock { $0.closeCodes } }

    /// Whether the server answers pings. Off, the connection stays open but looks dead to a client
    /// that pings.
    func setAnswersPings(_ answers: Bool) { state.withLock { $0.answersPings = answers } }

    func url(_ path: String = "/") -> URL { URL(string: "ws://127.0.0.1:\(port)\(path)")! }

    static func start(
        decision: @escaping @Sendable (Handshake) -> Decision = { _ in .accept },
        onMessage: @escaping Handler = { _, _ in }
    ) async throws -> LocalWebSocketServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let handshakeLog = OSAllocatedUnfairLock(initialState: [Handshake]())
        let options = NWProtocolWebSocket.Options()
        // Pings are answered by hand, so that a test can make the server go quiet.
        options.autoReplyPing = false
        options.setClientRequestHandler(.global()) { _, headers in
            var map: [String: String] = [:]
            for (name, value) in headers { map[name.lowercased()] = value }
            let handshake = Handshake(headers: map)
            handshakeLog.withLock { $0.append(handshake) }
            switch decision(handshake) {
            case .accept:
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            case .reject:
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { newState in
                let first = resumed.withLock { done -> Bool in
                    defer { if case .ready = newState { done = true } }
                    return !done
                }
                switch newState {
                case .ready:
                    if first, let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if first { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .global())
        }
        let server = LocalWebSocketServer(
            listener: listener,
            port: port,
            handshakeLog: handshakeLog
        )
        listener.newConnectionHandler = { [weak server] connection in
            server?.accept(connection, handshakeDecision: decision, onMessage: onMessage)
        }
        return server
    }

    private init(
        listener: NWListener,
        port: UInt16,
        handshakeLog: OSAllocatedUnfairLock<[Handshake]>
    ) {
        self.listener = listener
        self.port = port
        self.handshakeLog = handshakeLog
    }

    func stop() {
        listener.cancel()
        dropAll()
    }

    // MARK: Connections

    private func accept(
        _ connection: NWConnection,
        handshakeDecision: @escaping @Sendable (Handshake) -> Decision,
        onMessage: @escaping Handler
    ) {
        let id = UUID()
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.state.withLock {
                    $0.connections[id] = connection
                    $0.totalConnections += 1
                }
                self?.read(connection, id: id, onMessage: onMessage)
            case .failed, .cancelled:
                self?.state.withLock { $0.connections[id] = nil }
            default: break
            }
        }
        connection.start(queue: .global())
    }

    private func read(_ connection: NWConnection, id: UUID, onMessage: @escaping Handler) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }

            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                let message = WebSocketMessage.text(String(decoding: data ?? Data(), as: UTF8.self))
                state.withLock { $0.received.append(message) }
                onMessage(message, self)
            case .binary:
                let message = WebSocketMessage.binary(data ?? Data())
                state.withLock { $0.received.append(message) }
                onMessage(message, self)
            case .ping:
                if state.withLock({ $0.answersPings }) {
                    // The pong carries the ping's own payload.
                    let pong = NWProtocolWebSocket.Metadata(opcode: .pong)
                    let context = NWConnection.ContentContext(identifier: "pong", metadata: [pong])
                    connection.send(
                        content: data ?? Data(),
                        contentContext: context,
                        isComplete: true,
                        completion: .idempotent
                    )
                }
            case .close:
                state.withLock {
                    $0.closeCodes.append(metadata.map { Self.value(of: $0.closeCode) } ?? 0)
                }
                return
            default:
                break
            }
            self.read(connection, id: id, onMessage: onMessage)
        }
    }

    // MARK: What a test does to the clients

    /// Sends to every connected client.
    func broadcast(_ message: WebSocketMessage) {
        let metadata: NWProtocolWebSocket.Metadata
        let data: Data
        switch message {
        case .text(let text):
            metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            data = Data(text.utf8)
        case .binary(let bytes):
            metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            data = bytes
        }
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        for connection in state.withLock({ Array($0.connections.values) }) {
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .idempotent
            )
        }
    }

    func broadcast(text: String) { broadcast(.text(text)) }

    /// Closes every connection with a close frame carrying `code`.
    func closeAll(code: UInt16) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = Self.closeCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        for connection in state.withLock({ Array($0.connections.values) }) {
            connection.send(
                content: nil,
                contentContext: context,
                isComplete: true,
                completion: .idempotent
            )
        }
    }

    /// Breaks every connection without a close frame, as a lost network does.
    func dropAll() {
        for connection in state.withLock({ Array($0.connections.values) }) { connection.cancel() }
    }
}

extension LocalWebSocketServer {
    fileprivate static func value(of code: NWProtocolWebSocket.CloseCode) -> UInt16 {
        switch code {
        case .protocolCode(let defined): defined.rawValue
        case .applicationCode(let value): value
        case .privateCode(let value): value
        @unknown default: 0
        }
    }

    fileprivate static func closeCode(_ value: UInt16) -> NWProtocolWebSocket.CloseCode {
        if let defined = NWProtocolWebSocket.CloseCode.Defined(rawValue: value) {
            return .protocolCode(defined)
        }
        return .applicationCode(value)
    }
}
