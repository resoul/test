import Foundation
import NetworkCore

/// A ``WebSocketTransport`` over `URLSessionWebSocketTask`.
///
/// The connection is reported open once the server has answered a ping, which is after the upgrade
/// handshake: a refused upgrade is thrown as ``WebSocketError/handshakeRejected(status:)`` with the
/// server's HTTP status, so that refused credentials can be told from a network failure. That costs
/// one round trip, and needs a server that answers pings, which every WebSocket server must.
///
/// The message limit is given to the task, which closes the connection when a larger message
/// arrives. Cancelling the task that is connecting cancels the attempt.
public struct URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession

    /// - Parameter session: The session to use; it is held, not owned, so the app decides when to
    ///   invalidate it.
    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func connect(_ request: HTTPRequest, maxMessageBytes: Int) async throws(WebSocketError)
        -> any WebSocketConnection
    {
        guard let scheme = request.url.scheme?.lowercased(),
            ["ws", "wss", "http", "https"].contains(scheme), request.url.host != nil
        else { throw .invalidURL("\(request.url) is not a ws, wss, http or https URL") }

        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers.all {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpShouldHandleCookies = false
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }

        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = maxMessageBytes
        task.resume()
        let connection = Connection(task: task, maxMessageBytes: maxMessageBytes)
        do {
            try await withTaskCancellationHandler {
                try await connection.pingUntilAnswered()
            } onCancel: {
                task.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { throw .cancelled }
            if let status, status != 101 { throw .handshakeRejected(status: status) }

            throw Self.map(error, task: task, maxMessageBytes: maxMessageBytes)
        }
        return connection
    }

    fileprivate static func map(
        _ error: any Error,
        task: URLSessionWebSocketTask,
        maxMessageBytes: Int
    )
        -> WebSocketError
    {
        if error is CancellationError { return .cancelled }

        // A close frame from the server shows as a failed read, with the code on the task.
        let code = task.closeCode
        if code != .invalid {
            if code == .messageTooBig { return .messageTooLarge(limit: maxMessageBytes) }

            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .closedByServer(code: code.rawValue, reason: reason)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EMSGSIZE) {
            return .messageTooLarge(limit: maxMessageBytes)
        }
        switch URLSessionTransport.map(error) {
        case .cancelled: return .cancelled
        case .transport(let failure): return .transport(failure)
        case .invalidRequest(let message): return .invalidURL(message)
        default: return .transport(TransportFailure(kind: .other, underlying: error))
        }
    }

    private final class Connection: WebSocketConnection, Sendable {
        let task: URLSessionWebSocketTask
        let maxMessageBytes: Int

        init(task: URLSessionWebSocketTask, maxMessageBytes: Int) {
            self.task = task
            self.maxMessageBytes = maxMessageBytes
        }

        func pingUntilAnswered() async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        func send(_ message: WebSocketMessage) async throws(WebSocketError) {
            do {
                switch message {
                case .text(let text): try await task.send(.string(text))
                case .binary(let data): try await task.send(.data(data))
                }
            } catch {
                throw URLSessionWebSocketTransport.map(
                    error,
                    task: task,
                    maxMessageBytes: maxMessageBytes
                )
            }
        }

        func receive() async throws(WebSocketError) -> WebSocketMessage {
            do {
                switch try await task.receive() {
                case .string(let text): return .text(text)
                case .data(let data): return .binary(data)
                @unknown default:
                    throw WebSocketError.transport(
                        TransportFailure(kind: .other, underlying: URLError(.cannotParseResponse))
                    )
                }
            } catch let error as WebSocketError {
                throw error
            } catch {
                throw URLSessionWebSocketTransport.map(
                    error,
                    task: task,
                    maxMessageBytes: maxMessageBytes
                )
            }
        }

        func ping() async throws(WebSocketError) {
            do {
                try await pingUntilAnswered()
            } catch {
                throw URLSessionWebSocketTransport.map(
                    error,
                    task: task,
                    maxMessageBytes: maxMessageBytes
                )
            }
        }

        func close(code: Int, reason: String?) {
            task.cancel(
                with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
                reason: reason.map { Data($0.utf8) }
            )
        }
    }
}
