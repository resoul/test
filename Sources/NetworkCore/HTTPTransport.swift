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
}
