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

    /// Sends `request` and writes the body of a `2xx` answer to a new file, without holding the
    /// whole body in memory when the transport can avoid it; see ``HTTPDownload``.
    ///
    /// - Parameter maxBytes: The most body bytes to accept, or `nil` for no limit.
    /// - Throws: As ``send(_:maxResponseBytes:)``, plus ``HTTPError/fileSystem(underlying:)`` when
    ///   the file cannot be written. A failed or cancelled download leaves no file behind.
    func download(_ request: HTTPRequest, maxBytes: Int?) async throws(HTTPError) -> HTTPDownload

    /// Sends `request` with the content of `file` as its body, without reading the whole file into
    /// memory when the transport can avoid it. The request's own `body` is ignored.
    ///
    /// - Throws: As ``send(_:maxResponseBytes:)``, plus ``HTTPError/fileSystem(underlying:)`` when
    ///   the file cannot be read.
    func upload(_ request: HTTPRequest, fromFile file: URL, maxResponseBytes: Int?)
        async throws(HTTPError) -> HTTPResponse
}
