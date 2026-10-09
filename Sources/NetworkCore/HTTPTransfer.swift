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

extension HTTPTransport {
    /// Sends `request` and writes the body of a `2xx` answer to a new file.
    ///
    /// The file is the caller's to move or delete. Any other answer is returned with its body in
    /// memory, cut at ``HTTPDownload/errorBodyLimit``, and no file. Redirects, limits and
    /// cancellation are as for ``send(_:maxResponseBytes:)``; a body that passes `maxBytes` throws
    /// ``HTTPError/responseTooLarge(limit:)`` and leaves no file behind.
    ///
    /// This default holds the whole body in memory before it writes it, so it is no better than
    /// ``send(_:maxResponseBytes:)``; a transport that can stream to disk overrides it.
    public func download(_ request: HTTPRequest, maxBytes: Int?) async throws(HTTPError)
        -> HTTPDownload
    {
        var response = try await send(request, maxResponseBytes: maxBytes)
        guard (200...299).contains(response.status), request.method != .head else {
            response.body = response.body.prefix(HTTPDownload.errorBodyLimit)
            return HTTPDownload(response: response, file: nil, bytes: 0)
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-" + UUID().uuidString)
        do {
            try response.body.write(to: file)
        } catch {
            throw .fileSystem(underlying: error)
        }
        let bytes = response.body.count
        response.body = Data()
        return HTTPDownload(response: response, file: file, bytes: bytes)
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
}
