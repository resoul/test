import Foundation
import NetworkCore
import os

extension URLSessionTransport {
    /// Streams the body of a `2xx` answer to a new file in the download directory, chunk by chunk
    /// as it arrives, so the memory used does not depend on the size of the file.
    ///
    /// The limit is checked against the announced size before a byte is written and against the
    /// bytes written after that; either way the connection is dropped and the file removed. An
    /// answer that is not a `2xx` is not written: its body, cut at ``HTTPDownload/errorBodyLimit``,
    /// comes back in memory. A `HEAD` request has no body to download and is refused.
    public func download(_ request: HTTPRequest, maxBytes: Int?) async throws(HTTPError)
        -> HTTPDownload
    {
        guard request.method != .head else {
            throw .invalidRequest("a HEAD request has no body to download")
        }

        let urlRequest = try Self.makeURLRequest(request)
        let delegate = TransferDelegate(
            policy: redirects,
            limit: maxBytes,
            sink: .file(directory: downloadDirectory)
        )
        let task = session.dataTask(with: urlRequest)
        task.delegate = delegate
        let result = try await delegate.run(task)
        return HTTPDownload(
            response: Self.response(of: result, fallback: request.url),
            file: result.file,
            bytes: result.bytes
        )
    }

    /// Sends the content of `file` as the body, read by the system as it goes, and collects the
    /// answer in memory up to `maxResponseBytes`.
    public func upload(_ request: HTTPRequest, fromFile file: URL, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse
    {
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw .fileSystem(
                underlying: CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: file])
            )
        }

        let urlRequest = try Self.makeURLRequest(request, includingBody: false)
        let delegate = TransferDelegate(
            policy: redirects,
            limit: maxResponseBytes,
            sink: .memory
        )
        let task = session.uploadTask(with: urlRequest, fromFile: file)
        task.delegate = delegate
        let result = try await delegate.run(task)
        return Self.response(of: result, fallback: request.url)
    }

    private static func response(of result: TransferDelegate.Result, fallback: URL)
        -> HTTPResponse
    {
        var headers = HTTPHeaders()
        for (name, value) in result.http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers.add(value, for: name)
            }
        }
        return HTTPResponse(
            status: result.http.statusCode,
            headers: headers,
            body: result.body,
            url: result.http.url ?? fallback
        )
    }
}

/// Receives one transfer as it happens: writes the body to a file or collects it in memory,
/// enforces the size limit, and ends the awaiting call exactly once.
///
/// The delegate belongs to one task. The system calls it from its own queue, so everything that
/// changes lives behind a lock.
final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    enum Sink: Sendable {
        /// A `2xx` body goes to a new file in `directory`; other bodies are kept in memory, cut.
        case file(directory: URL)
        /// Every body is kept in memory, up to the limit.
        case memory
    }

    struct Result: Sendable {
        var http: HTTPURLResponse
        var body: Data
        var file: URL?
        var bytes: Int
    }

    private struct State: Sendable {
        var response: HTTPURLResponse?
        var file: URL?
        var handle: FileHandle?
        var bytes = 0
        var body = Data()
        /// Why the transfer was stopped from this side, if it was. It stands for the "cancelled"
        /// that stopping it makes the system report.
        var failure: HTTPError?
        /// The body was cut at the error-body limit and the rest of it not read.
        var truncated = false
        var continuation: CheckedContinuation<Result, any Error>?
    }

    private let policy: URLSessionTransport.RedirectPolicy
    private let limit: Int?
    private let sink: Sink
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(policy: URLSessionTransport.RedirectPolicy, limit: Int?, sink: Sink) {
        self.policy = policy
        self.limit = limit
        self.sink = sink
    }

    /// Runs `task` to its end. Cancelling the calling task cancels `task`; a task that never got
    /// to start is not started.
    func run(_ task: URLSessionTask) async throws(HTTPError) -> Result {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.withLock { $0.continuation = continuation }
                    if Task.isCancelled {
                        task.cancel()
                    }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw URLSessionTransport.map(error)
        }
    }

    // MARK: URLSession

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            stop(with: .notHTTPResponse)
            return .cancel
        }

        let announced = http.expectedContentLength
        let writesFile: Bool
        if case .file = sink, (200...299).contains(http.statusCode) {
            writesFile = true
        } else {
            writesFile = false
        }
        if let limit, announced > Int64(limit), writesFile || isMemory {
            stop(with: .responseTooLarge(limit: limit))
            return .cancel
        }

        state.withLock { $0.response = http }
        if writesFile, case .file(let directory) = sink {
            let file = directory.appendingPathComponent("download-" + UUID().uuidString)
            do {
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file])
                }
                let handle = try FileHandle(forWritingTo: file)
                state.withLock {
                    $0.file = file
                    $0.handle = handle
                }
            } catch {
                stop(with: .fileSystem(underlying: error))
                return .cancel
            }
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failure: HTTPError? = state.withLock { state in
            if let handle = state.handle {
                state.bytes += data.count
                if let limit, state.bytes > limit { return .responseTooLarge(limit: limit) }

                do {
                    try handle.write(contentsOf: data)
                } catch {
                    return .fileSystem(underlying: error)
                }
                return nil
            }

            // In memory: a body for the caller, or the cut error body of a download.
            let cap: Int
            switch sink {
            case .memory: cap = limit ?? Int.max
            case .file: cap = HTTPDownload.errorBodyLimit
            }
            let room = cap - state.body.count
            if data.count > room {
                guard case .file = sink else { return .responseTooLarge(limit: cap) }

                state.body.append(data.prefix(max(room, 0)))
                state.truncated = true
                return .responseTooLarge(limit: cap)
            }
            state.body.append(data)
            return nil
        }
        guard let failure else { return }

        // A cut error body is not a failure: the part that was wanted has been read.
        if state.withLock({ $0.truncated }) {
            dataTask.cancel()
        } else {
            stop(with: failure, task: dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let finished = state.withLock { state -> (State, CheckedContinuation<Result, any Error>?) in
            try? state.handle?.close()
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            return (state, continuation)
        }
        let (final, continuation) = finished
        guard let continuation else {
            Self.remove(final.file)
            return
        }

        if let failure = final.failure {
            Self.remove(final.file)
            continuation.resume(throwing: failure)
        } else if let error, !final.truncated {
            Self.remove(final.file)
            continuation.resume(throwing: error)
        } else if let http = final.response ?? (task.response as? HTTPURLResponse) {
            continuation.resume(
                returning: Result(http: http, body: final.body, file: final.file, bytes: final.bytes)
            )
        } else {
            Self.remove(final.file)
            continuation.resume(throwing: HTTPError.notHTTPResponse)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectRules.decide(policy: policy, task: task, response: response, newRequest: request)
    }

    // MARK: Stopping

    private var isMemory: Bool {
        if case .memory = sink { return true }
        return false
    }

    /// Records why the transfer is being stopped, unless an earlier reason is already recorded, and
    /// cancels the task; the system then reports it cancelled, and the reason stands for that.
    private func stop(with failure: HTTPError, task: URLSessionTask? = nil) {
        state.withLock { if $0.failure == nil { $0.failure = failure } }
        task?.cancel()
    }

    private static func remove(_ file: URL?) {
        guard let file else { return }

        try? FileManager.default.removeItem(at: file)
    }
}
