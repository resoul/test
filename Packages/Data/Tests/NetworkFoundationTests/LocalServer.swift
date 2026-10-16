import Foundation
import Network
import os

struct ServerRequest: Sendable {
    var method: String
    var path: String
    /// Lower-cased names.
    var headers: [String: String]
    var body: Data
}

struct ServerReply: Sendable {
    var status = 200
    var headers: [(String, String)] = []
    var body = Data()
    /// The `Content-Length` to announce: the body's length when `nil`; `.some(nil)` is not used —
    /// a reply that must not announce a length sets `announcesLength` to false.
    var announcedLength: Int?
    var announcesLength = true
    /// How long to wait before answering.
    var delay: Duration = .zero
    /// How long to keep the connection open after the answer is sent, as a server that announces a
    /// long body and then goes quiet does.
    var keepOpen: Duration = .zero

    init(
        _ status: Int = 200,
        _ text: String = "",
        headers: [(String, String)] = [],
        delay: Duration = .zero
    ) {
        self.status = status
        self.body = Data(text.utf8)
        self.headers = headers
        self.delay = delay
    }
}

/// A small HTTP/1.1 server on the loopback interface, for tests that need a real socket. It answers
/// each connection once and closes it, and remembers what it was asked.
final class LocalServer: Sendable {
    typealias Handler = @Sendable (ServerRequest) async -> ServerReply

    let port: UInt16
    private let listener: NWListener
    private let log = OSAllocatedUnfairLock(initialState: Log())

    private struct Log {
        var requests: [ServerRequest] = []
        var abandoned = 0
    }

    var requests: [ServerRequest] { log.withLock { $0.requests } }

    /// How many requests the client gave up on before the server had answered.
    var abandoned: Int { log.withLock { $0.abandoned } }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    static func start(_ handler: @escaping Handler) async throws -> LocalServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let first = resumed.withLock { done -> Bool in
                    defer { if case .ready = state { done = true } }
                    return !done
                }
                switch state {
                case .ready:
                    if first, let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if first { continuation.resume(throwing: error) }
                default: break
                }
            }
            // The connections are handled below, once the server object exists; until then
            // nothing connects, because the port is not known to anyone.
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .global())
        }
        let server = LocalServer(listener: listener, port: port)
        listener.newConnectionHandler = { [log = server.log] connection in
            Self.serve(connection, log: log, handler: handler)
        }
        return server
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func stop() { listener.cancel() }

    private static func serve(
        _ connection: NWConnection,
        log: OSAllocatedUnfairLock<Log>,
        handler: @escaping Handler
    ) {
        connection.start(queue: .global())
        Task {
            guard let request = await readRequest(connection) else {
                connection.cancel()
                return
            }
            log.withLock { $0.requests.append(request) }
            // While the handler works, a read that completes means the client has gone.
            let gone = Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
                        _,
                        _,
                        isComplete,
                        error in
                        if isComplete || error != nil { continuation.resume() }
                    }
                }
                log.withLock { $0.abandoned += 1 }
            }
            let reply = await handler(request)
            if reply.delay > .zero { try? await Task.sleep(for: reply.delay) }
            gone.cancel()
            await write(
                reply,
                to: connection,
                head: request.method == "HEAD",
                keepOpen: reply.keepOpen
            )
        }
    }

    private static func readRequest(_ connection: NWConnection) async -> ServerRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: separator) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let parts = lines.removeFirst().split(separator: " ")
                guard parts.count >= 2 else { return nil }

                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }

                    headers[line[..<colon].lowercased()] =
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                var body = Data(buffer[range.upperBound...])
                if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                    guard let decoded = await readChunks(connection, starting: body) else {
                        return nil
                    }

                    return ServerRequest(
                        method: String(parts[0]),
                        path: String(parts[1]),
                        headers: headers,
                        body: decoded
                    )
                }
                let length = Int(headers["content-length"] ?? "") ?? 0
                while body.count < length {
                    guard let more = await receive(connection) else { return nil }
                    body.append(more)
                }
                return ServerRequest(
                    method: String(parts[0]),
                    path: String(parts[1]),
                    headers: headers,
                    body: body.prefix(length)
                )
            }
            guard let more = await receive(connection) else { return nil }
            buffer.append(more)
        }
    }

    /// The body of a chunked request: each chunk is its size in hexadecimal, a line break, that many
    /// bytes and a line break, ending with a chunk of size zero.
    private static func readChunks(_ connection: NWConnection, starting: Data) async -> Data? {
        var buffer = starting
        var body = Data()
        let lineEnd = Data("\r\n".utf8)
        while true {
            guard let end = buffer.range(of: lineEnd) else {
                guard let more = await receive(connection) else { return nil }
                buffer.append(more)
                continue
            }

            let sizeText = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }

            let start = end.upperBound
            while buffer.count < start + size + 2 {
                guard let more = await receive(connection) else { return nil }
                buffer.append(more)
            }
            if size == 0 { return body }

            body.append(buffer[start..<(start + size)])
            buffer = Data(buffer[(start + size + 2)...])
        }
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data,
                _,
                _,
                error in
                continuation.resume(returning: error == nil ? data : nil)
            }
        }
    }

    private static func write(
        _ reply: ServerReply,
        to connection: NWConnection,
        head: Bool,
        keepOpen: Duration
    ) async {
        var text = "HTTP/1.1 \(reply.status) Reply\r\nConnection: close\r\n"
        if reply.announcesLength {
            text += "Content-Length: \(reply.announcedLength ?? reply.body.count)\r\n"
        }
        for (name, value) in reply.headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if !head { data.append(reply.body) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: data,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
        if keepOpen > .zero { try? await Task.sleep(for: keepOpen) }
        connection.cancel()
    }
}
