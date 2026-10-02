/// Why a request did not give a usable answer. The cases keep apart what went wrong, because
/// what to do about it differs: a failed connection may be retried, a refused status may be
/// shown, a cancellation is not an error to show at all.
public enum HTTPError: Error, Sendable {
    /// The request cannot be sent: not an `http` or `https` URL, for example. Nothing was sent.
    case invalidRequest(String)
    /// The body could not be encoded. Nothing was sent.
    case encoding(underlying: any Error)
    /// The request did not complete: no connection, a timeout, a dropped connection. The server
    /// may or may not have acted on it.
    case transport(TransportFailure)
    /// The server answered, but not with HTTP.
    case notHTTPResponse
    /// The answer is bigger than the limit. The rest of it was not read.
    case responseTooLarge(limit: Int)
    /// The server answered with a status the caller did not expect. The whole response is here,
    /// since an error body often says what was wrong.
    case status(HTTPResponse)
    /// A body was needed but the answer has none, as with `204`.
    case emptyResponse
    /// The body did not decode as the expected type.
    case decoding(underlying: any Error)
    /// Credentials could not be obtained or refreshed.
    case authorizationFailed(underlying: any Error)
    /// The task was cancelled. Not a failure of the network, and not worth showing as one.
    case cancelled
}

/// A request that failed to complete, with what kind of failure it was.
public struct TransportFailure: Error, Sendable {
    public enum Kind: Hashable, Sendable {
        case timedOut
        /// The connection broke after it was made.
        case connectionLost
        /// No connection could be made to the server.
        case cannotConnect
        /// The device has no network.
        case notConnected
        /// TLS failed: a bad certificate, for example. Never worth repeating.
        case secureConnectionFailed
        case other
    }

    public var kind: Kind
    public var underlying: any Error

    public init(kind: Kind, underlying: any Error) {
        self.kind = kind
        self.underlying = underlying
    }
}
