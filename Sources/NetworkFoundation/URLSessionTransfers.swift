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
    public func download(_ request: HTTPRequest, maxBytes: Int?, partial: PartialDownload?)
        async throws(HTTPError) -> HTTPDownload
    {
        guard request.method != .head else {
            throw .invalidRequest("a HEAD request has no body to download")
        }

        let urlRequest = try Self.makeURLRequest(request)
        let delegate = TransferDelegate(
            policy: redirects,
            limit: maxBytes,
            sink: partial.map { .partial($0) } ?? .file(directory: downloadDirectory)
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

    /// Sends `body` as it is read: the system asks for a new stream at the start and again for each
    /// repeat of the body it has to make (a redirect that keeps it), and each time `body` makes one.
    /// With a known length the request carries `Content-Length`; without one it is sent in chunks.
    public func upload(_ request: HTTPRequest, from body: HTTPBodyStream, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse
    {
        var urlRequest = try Self.makeURLRequest(request, includingBody: false)
        if let length = body.length, urlRequest.value(forHTTPHeaderField: "Content-Length") == nil {
            urlRequest.setValue("\(length)", forHTTPHeaderField: "Content-Length")
        }
        let delegate = TransferDelegate(
            policy: redirects,
            limit: maxResponseBytes,
            sink: .memory,
            bodyStream: body
        )
        let task = session.uploadTask(withStreamedRequest: urlRequest)
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
        /// A `2xx` body goes to the file of a partial download, added to it for a `206` that carries
        /// what comes next and replacing it otherwise; the file stays if the transfer breaks off.
        case partial(PartialDownload)
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
    private let bodyStream: HTTPBodyStream?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        policy: URLSessionTransport.RedirectPolicy,
        limit: Int?,
        sink: Sink,
        bodyStream: HTTPBodyStream? = nil
    ) {
        self.policy = policy
        self.limit = limit
        self.sink = sink
        self.bodyStream = bodyStream
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
        switch sink {
        case .file, .partial: writesFile = (200...299).contains(http.statusCode)
        case .memory: writesFile = false
        }
        var existing: Int64 = 0
        var appends = false
        if writesFile, case .partial(let partial) = sink {
            if http.statusCode == 206 {
                existing = partial.size
                let first = PartialDownload.contentRange(of: Self.head(of: http).headers)?.first
                guard first == existing else {
                    // A part that does not follow the file would corrupt it; the answer is reported.
                    stop(with: .status(Self.head(of: http)))
                    return .cancel
                }

                appends = true
            }
        }
        if let limit, announced > Int64(limit) - existing, writesFile || isMemory {
            stop(with: .responseTooLarge(limit: limit))
            return .cancel
        }

        state.withLock { $0.response = http }
        if writesFile {
            let alreadyWritten = Int(existing)
            do {
                let (file, handle) = try openFile(appending: appends, existing: existing, for: http)
                state.withLock {
                    $0.file = file
                    $0.handle = handle
                    $0.bytes = alreadyWritten
                }
            } catch {
                stop(with: .fileSystem(underlying: error))
                return .cancel
            }
        }
        return .allow
    }

    /// The file a body is written to, open for writing: a new one in the download directory, or the
    /// partial download's own, which a `206` is added to and anything else empties. For a partial
    /// download the record of validators is written first, so that a break-off later can be continued.
    private func openFile(appending: Bool, existing: Int64, for http: HTTPURLResponse) throws
        -> (URL, FileHandle)
    {
        switch sink {
        case .partial(let partial):
            if !appending {
                guard FileManager.default.createFile(atPath: partial.file.path, contents: nil)
                else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: partial.file])
                }
            }
            partial.store(
                HTTPValidators(
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified")
                )
            )
            let handle = try FileHandle(forWritingTo: partial.file)
            if appending { try handle.seekToEnd() }
            return (partial.file, handle)
        case .file(let directory):
            let file = directory.appendingPathComponent("download-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file])
            }
            return (file, try FileHandle(forWritingTo: file))
        case .memory:
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The answer's head, for an error that names it.
    private static func head(of http: HTTPURLResponse) -> HTTPResponse {
        var headers = HTTPHeaders()
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers.add(value, for: name)
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, url: http.url ?? URL(fileURLWithPath: "/"))
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
            case .file, .partial: cap = HTTPDownload.errorBodyLimit
            }
            let room = cap - state.body.count
            if data.count > room {
                if case .memory = sink { return .responseTooLarge(limit: cap) }

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
        // A partial download's file is the app's, and what it holds is what the next try goes on from.
        let discards: (URL?) -> Void = { [keeps = keepsFile] file in
            if !keeps { Self.remove(file) }
        }
        guard let continuation else {
            discards(final.file)
            return
        }

        if let failure = final.failure {
            discards(final.file)
            continuation.resume(throwing: failure)
        } else if let error, !final.truncated {
            discards(final.file)
            continuation.resume(throwing: error)
        } else if let http = final.response ?? (task.response as? HTTPURLResponse) {
            continuation.resume(
                returning: Result(http: http, body: final.body, file: final.file, bytes: final.bytes)
            )
        } else {
            discards(final.file)
            continuation.resume(throwing: HTTPError.notHTTPResponse)
        }
    }

    /// A body that is a stream: a new one for the first send and for every repeat. A stream that
    /// cannot be made ends the transfer with the reason.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        guard let bodyStream else {
            completionHandler(nil)
            return
        }

        do {
            completionHandler(try bodyStream.make())
        } catch {
            stop(with: .fileSystem(underlying: error), task: task)
            completionHandler(nil)
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

    /// Whether the file is to stay when the transfer fails: a partial download's does.
    private var keepsFile: Bool {
        if case .partial = sink { return true }
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
