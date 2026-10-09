import Foundation

/// The result of a download: the answer, and the file the body was written to.
public struct HTTPDownload: Sendable {
    /// The most bytes of an error body a download keeps in memory. An answer that is not a success
    /// is not written to a file; its body, cut at this size, comes back in the response so that the
    /// reason the server gave can be read.
    public static let errorBodyLimit = 64 * 1024

    /// The answer. Its body is empty when ``file`` holds the content, and holds the (cut) error
    /// body when it does not.
    public var response: HTTPResponse
    /// Where the body was written; `nil` when the answer was not a `2xx`, so that nothing was.
    public var file: URL?
    /// How many bytes were written to ``file``.
    public var bytes: Int

    public init(response: HTTPResponse, file: URL?, bytes: Int) {
        self.response = response
        self.file = file
        self.bytes = bytes
    }
}

/// A request body that is produced as it is sent, for a body that is not in memory or a file: one that
/// is generated, compressed or encrypted on the way out.
///
/// A body may have to be sent more than once: the client repeats a request that failed in a way
/// that is worth another try, and a redirect that keeps the body sends it again. Each time the
/// transport asks `make` for a **new** stream, so `make` must be able to start the same body over —
/// open the file again, run the generator again. A body that can be read only once is not
/// usable here; the request is then better made with a method that is not retried, and
/// with a `make` that fails the second time.
public struct HTTPBodyStream: Sendable {
    /// The size in bytes if it is known, which sends a `Content-Length`; `nil` sends the body in chunks
    /// of unknown total, which a server must be ready to take.
    public var length: Int64?
    /// Opens a new stream positioned at the start of the body. Throwing fails the request with
    /// ``HTTPError/fileSystem(underlying:)``.
    public var make: @Sendable () throws -> InputStream

    public init(length: Int64? = nil, make: @escaping @Sendable () throws -> InputStream) {
        self.length = length
        self.make = make
    }

    /// The bytes of `data`, as a body that can be started over.
    public static func data(_ data: Data) -> HTTPBodyStream {
        HTTPBodyStream(length: Int64(data.count)) { InputStream(data: data) }
    }

    /// The content of the file at `url`, read as it is sent.
    public static func file(at url: URL) -> HTTPBodyStream {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value
        return HTTPBodyStream(length: size) {
            guard let stream = InputStream(url: url) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url])
            }
            return stream
        }
    }

    /// The whole body, read from a new stream. For a transport that cannot send a stream.
    ///
    /// - Throws: Whatever `make` throws, and the stream's own error when reading fails.
    public func readAll() throws -> Data {
        let stream = try make()
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }

            if count == 0 { return data }

            data.append(contentsOf: buffer[0..<count])
        }
    }
}

extension HTTPTransport {
    /// Sends `request` and writes the body of a `2xx` answer to a new file, which is the caller's to
    /// move or delete.
    public func download(_ request: HTTPRequest, maxBytes: Int?) async throws(HTTPError)
        -> HTTPDownload
    {
        try await download(request, maxBytes: maxBytes, partial: nil)
    }

    /// The contract of ``HTTPTransport/download(_:maxBytes:partial:)`` over ``send(_:maxResponseBytes:)``.
    ///
    /// This default holds the whole body in memory before it writes it, so it is no better than
    /// ``send(_:maxResponseBytes:)``, and it cannot keep what an interrupted download had read; a
    /// transport that can stream to disk overrides it.
    public func download(_ request: HTTPRequest, maxBytes: Int?, partial: PartialDownload?)
        async throws(HTTPError) -> HTTPDownload
    {
        var response = try await send(request, maxResponseBytes: maxBytes)
        guard (200...299).contains(response.status), request.method != .head else {
            response.body = response.body.prefix(HTTPDownload.errorBodyLimit)
            return HTTPDownload(response: response, file: nil, bytes: 0)
        }

        let file: URL
        var total = response.body.count
        do {
            if let partial {
                file = partial.file
                partial.store(
                    HTTPValidators(
                        etag: response.headers["ETag"],
                        lastModified: response.headers["Last-Modified"]
                    )
                )
                let existing = partial.size
                if response.status == 206 {
                    guard PartialDownload.contentRange(of: response.headers)?.first == existing else {
                        throw HTTPError.status(response)
                    }

                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: response.body)
                    total = Int(existing) + response.body.count
                } else {
                    try response.body.write(to: file)
                }
            } else {
                file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("download-" + UUID().uuidString)
                try response.body.write(to: file)
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw .fileSystem(underlying: error)
        }
        response.body = Data()
        return HTTPDownload(response: response, file: file, bytes: total)
    }

    /// Sends `request` with the content of `file` as its body.
    ///
    /// The default reads the file into memory and sends it with ``send(_:maxResponseBytes:)``; a
    /// transport that can stream a file overrides it.
    public func upload(_ request: HTTPRequest, fromFile file: URL, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse
    {
        var outgoing = request
        do {
            outgoing.body = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch {
            throw .fileSystem(underlying: error)
        }
        return try await send(outgoing, maxResponseBytes: maxResponseBytes)
    }

    /// Sends `request` with the stream `body` as its body.
    ///
    /// The default reads the whole stream into memory and sends it with ``send(_:maxResponseBytes:)``;
    /// a transport that can send a stream as it is read overrides it.
    public func upload(_ request: HTTPRequest, from body: HTTPBodyStream, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse
    {
        var outgoing = request
        do {
            outgoing.body = try body.readAll()
        } catch {
            throw .fileSystem(underlying: error)
        }
        return try await send(outgoing, maxResponseBytes: maxResponseBytes)
    }
}

