import Foundation

/// Carries a request to a server and brings the answer back: the one place that touches the
/// network. ``HTTPClient`` adds policy — statuses, retries, credentials — on top of any transport,
/// so tests give it a fake one.
public protocol HTTPTransport: Sendable {
    /// Sends `request` once.
    ///
    /// Any answer is returned, whatever its status. Redirects are followed by the transport; the
    /// response carries the final URL. Cancelling the calling task cancels the request and throws
    /// ``HTTPError/cancelled``.
    ///
    /// - Parameter maxResponseBytes: The most body bytes to accept, or `nil` for no limit. A
    ///   transport stops reading as soon as the limit is passed, or earlier when the answer
    ///   announces a larger size, and throws ``HTTPError/responseTooLarge(limit:)``.
    /// - Throws: ``HTTPError/transport(_:)``, ``HTTPError/responseTooLarge(limit:)``,
    ///   ``HTTPError/invalidRequest(_:)``, ``HTTPError/notHTTPResponse`` or ``HTTPError/cancelled``.
    func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse

    /// Sends `request` and writes the body of a `2xx` answer to a file, without holding the whole body
    /// in memory when the transport can avoid it; see ``HTTPDownload``.
    ///
    /// Without `partial` the file is a new one in a place of the transport's choosing, which the caller
    /// moves or deletes, and a failed or cancelled download leaves nothing behind.
    ///
    /// With `partial` the bytes go to its file, and the transport keeps what it wrote when the
    /// download is interrupted, so that the next try can ask for the rest. The caller has already put
    /// `Range` and `If-Range` on `request` if it is a continuation (``PartialDownload/resumeHeaders()``).
    /// For a `206` answer whose first byte is the file's size, the body is added to the file; for any
    /// other `2xx` — the server ignored the range or the thing changed — the file starts over. A `206` that
    /// starts anywhere else is thrown as ``HTTPError/status(_:)``. On a `2xx` the transport also
    /// writes the answer's validators to the record (``PartialDownload/store(_:)``) before the first
    /// byte of the body, which is what makes a later continuation possible. An answer that is not a
    /// `2xx` touches neither the file nor the record.
    ///
    /// - Parameters:
    ///   - maxBytes: The most bytes to accept, or `nil` for no limit; with `partial` it is the size the
    ///     whole file may come to.
    /// - Throws: As ``send(_:maxResponseBytes:)``, plus ``HTTPError/fileSystem(underlying:)`` when
    ///   the file cannot be written.
    func download(_ request: HTTPRequest, maxBytes: Int?, partial: PartialDownload?)
        async throws(HTTPError) -> HTTPDownload

    /// Sends `request` with the content of `file` as its body, without reading the whole file into
    /// memory when the transport can avoid it. The request's own `body` is ignored.
    ///
    /// - Throws: As ``send(_:maxResponseBytes:)``, plus ``HTTPError/fileSystem(underlying:)`` when
    ///   the file cannot be read.
    func upload(_ request: HTTPRequest, fromFile file: URL, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse

    /// Sends `request` with the stream `body` as its body, taking a new stream from `body` for every
    /// attempt the transport makes, a redirect that sends the body again included. The request's
    /// own `body` is ignored.
    ///
    /// - Throws: As ``send(_:maxResponseBytes:)``, plus ``HTTPError/fileSystem(underlying:)`` when
    ///   the stream cannot be made or read.
    func upload(_ request: HTTPRequest, from body: HTTPBodyStream, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse
}

