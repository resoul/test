import Foundation

/// Names one background transfer, from the moment it is scheduled to the moment its outcome is
/// acknowledged.
///
/// The app may choose the name: a transfer scheduled again under a name that is still running, or
/// whose outcome has not been acknowledged yet, is not started a second time. That is what lets an app
/// say "make sure this file is downloaded" at every launch without downloading it at every launch.
public struct BackgroundTransferID: RawRepresentable, Hashable, Sendable,
    ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// A name no other transfer has.
    public static func unique() -> BackgroundTransferID {
        BackgroundTransferID(UUID().uuidString)
    }

    public var description: String { rawValue }
}

public enum BackgroundTransferKind: String, Hashable, Sendable {
    case download
    case upload
}

/// How a background transfer ended: the answer the server gave, or why there is none.
public struct BackgroundTransferOutcome: Sendable, Equatable {
    /// Why a transfer did not give an answer, or did not leave its file.
    public struct Failure: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// The app (or the user, from Settings) stopped it.
            case cancelled
            /// The device had no network for as long as the system was willing to wait.
            case notConnected
            case connectionLost
            case timedOut
            case cannotConnect
            case secureConnectionFailed
            /// The downloaded file could not be put at its destination.
            case fileSystem
            /// A reply passed the limit the transfers were made with.
            case responseTooLarge
            case other
        }

        public var kind: Kind
        /// The system's description, for a log. Not for the user, and not a stable text.
        public var message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public var id: BackgroundTransferID
    public var kind: BackgroundTransferKind
    /// The status of the answer; `nil` when there was none.
    public var status: Int?
    public var headers: HTTPHeaders
    /// An upload's reply, or the (cut) body of a download whose answer was not a success. Empty for
    /// a download that succeeded: its content is in ``file``.
    public var body: Data
    /// Where a download was put; `nil` for an upload and for a download that did not succeed.
    public var file: URL?
    /// Why there is no usable answer; `nil` when the server answered, whatever it said.
    public var failure: Failure?

    public init(
        id: BackgroundTransferID,
        kind: BackgroundTransferKind,
        status: Int? = nil,
        headers: HTTPHeaders = [:],
        body: Data = Data(),
        file: URL? = nil,
        failure: Failure? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.headers = headers
        self.body = body
        self.file = file
        self.failure = failure
    }

    /// The server answered with a `2xx`, and for a download the file is in place.
    public var isSuccess: Bool {
        guard failure == nil, let status else { return false }

        return (200...299).contains(status)
    }
}

/// How far a transfer has got.
public struct BackgroundTransferProgress: Sendable, Equatable {
    public var id: BackgroundTransferID
    public var completed: Int64
    /// The size, when it is known.
    public var total: Int64?

    public init(id: BackgroundTransferID, completed: Int64, total: Int64?) {
        self.id = id
        self.completed = completed
        self.total = total
    }
}

/// A transfer the system has, as ``BackgroundTransfers/transfers()`` sees it.
public struct BackgroundTransferInfo: Sendable, Equatable {
    public enum State: Sendable {
        case running
        /// Held back, by the system or on purpose.
        case suspended
        /// Done or stopped; the outcome is on its way.
        case finishing
    }

    public var id: BackgroundTransferID
    public var kind: BackgroundTransferKind
    public var state: State
    public var progress: BackgroundTransferProgress

    public init(
        id: BackgroundTransferID,
        kind: BackgroundTransferKind,
        state: State,
        progress: BackgroundTransferProgress
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = progress
    }
}

/// Transfers that go on while the app is not running, and whose results are waiting when it runs
/// again.
///
/// Scheduling a transfer hands it to the system, which carries it out on its own terms — when the
/// network is there, when the battery allows, after the app was ended — and starts the app again to
/// report. This differs from ``HTTPClient``'s transfers in what the app gives up:
///
/// - **No retries and no renewal of credentials.** The request is signed when it is scheduled
///   (``HTTPClient/download(_:inBackground:to:id:)``); the system may send it hours later, and
///   nothing of the app runs between. A token that has expired by then comes back as a `401` in the
///   outcome, which the app answers by scheduling the transfer again.
/// - **A download is always a new file.** It cannot continue a ``PartialDownload``.
/// - **An upload is a file.** There is no body in memory and no stream: what is sent is what the file
///   holds when the system gets to it.
///
/// **Outcomes are kept until acknowledged.** The result of each transfer is written down the moment
/// it arrives, whether or not the app listens, and ``outcomes()`` gives every one that has not been
/// acknowledged, then each new one. Delivery is at least once: an app that ends before
/// ``acknowledge(_:)`` sees the outcome again at its next launch, so what it does with an outcome must
/// be safe to do twice.
public protocol BackgroundTransfers: Sendable {
    /// Where downloaded files are put: the folder that a download's `path` is relative to.
    var directory: URL { get }

    /// Schedules a download.
    ///
    /// - Parameters:
    ///   - request: A request without a body. Its headers, credentials included, are sent as they are.
    ///   - path: Where the file goes once it is complete, relative to ``directory``; a file that is
    ///     already there is replaced, and folders on the way are made. It may not leave the
    ///     directory.
    ///   - id: The name of the transfer; one is made when `nil`. See ``BackgroundTransferID``.
    /// - Returns: The name of the transfer.
    /// - Throws: ``HTTPError/invalidRequest(_:)`` for a request with a body, a URL that is not `http` or
    ///   `https`, or a `path` that leaves the directory.
    func download(_ request: HTTPRequest, to path: String, id: BackgroundTransferID?)
        async throws(HTTPError) -> BackgroundTransferID

    /// Schedules an upload of the content of `file`, whose reply is kept in the outcome.
    ///
    /// The file must stay where it is, unchanged, until the outcome arrives: the system reads it when it
    /// sends. The request's own `body` is ignored.
    ///
    /// - Throws: ``HTTPError/invalidRequest(_:)`` for a URL that is not `http` or `https`, and
    ///   ``HTTPError/fileSystem(underlying:)`` for a file that cannot be read.
    func upload(_ request: HTTPRequest, fromFile file: URL, id: BackgroundTransferID?)
        async throws(HTTPError) -> BackgroundTransferID

    /// The transfers that are not done, by the system's account.
    func transfers() async -> [BackgroundTransferInfo]

    /// Stops a transfer. Its outcome says it was cancelled, unless it had finished by then.
    func cancel(_ id: BackgroundTransferID) async

    /// Every outcome that has not been acknowledged, and then each one as it arrives.
    ///
    /// The sequence does not end by itself; stop iterating to stop listening. Several sequences may
    /// listen at once, and each is given every outcome.
    func outcomes() -> AsyncStream<BackgroundTransferOutcome>

    /// How far running transfers have got, as the system reports it while the app runs. A consumer
    /// slower than the system gets the latest values and misses the ones in between.
    func progress() -> AsyncStream<BackgroundTransferProgress>

    /// Forgets the outcome of `id`, which the app has dealt with. That frees the name to be scheduled
    /// again.
    func acknowledge(_ id: BackgroundTransferID) async
}

extension BackgroundTransfers {
    /// Schedules a download under a name of the transfers' own making.
    @discardableResult
    public func download(_ request: HTTPRequest, to path: String) async throws(HTTPError)
        -> BackgroundTransferID
    {
        try await download(request, to: path, id: nil)
    }

    /// Schedules an upload under a name of the transfers' own making.
    @discardableResult
    public func upload(_ request: HTTPRequest, fromFile file: URL) async throws(HTTPError)
        -> BackgroundTransferID
    {
        try await upload(request, fromFile: file, id: nil)
    }
}

extension HTTPClient {
    /// Schedules a download in the background with the client's base headers and credentials on the
    /// request.
    ///
    /// The retry policy, the status check and the renewal of credentials are not applied: the system
    /// carries the request out later, with the client gone. See ``BackgroundTransfers``.
    public func download(
        _ request: HTTPRequest,
        inBackground transfers: any BackgroundTransfers,
        to path: String,
        id: BackgroundTransferID? = nil
    ) async throws(HTTPError) -> BackgroundTransferID {
        try await transfers.download(try await prepared(request), to: path, id: id)
    }

    /// Schedules an upload of `file` in the background; see
    /// ``download(_:inBackground:to:id:)`` and ``BackgroundTransfers/upload(_:fromFile:id:)``.
    public func upload(
        _ request: HTTPRequest,
        fromFile file: URL,
        inBackground transfers: any BackgroundTransfers,
        id: BackgroundTransferID? = nil
    ) async throws(HTTPError) -> BackgroundTransferID {
        try await transfers.upload(try await prepared(request), fromFile: file, id: id)
    }

    /// `request` with the default headers and the credentials, as the first attempt of a request
    /// would send it.
    private func prepared(_ request: HTTPRequest) async throws(HTTPError) -> HTTPRequest {
        var prepared = request
        for (name, value) in defaultHeaders.all where prepared.headers[name] == nil {
            prepared.headers[name] = value
        }
        guard let authorizer else { return prepared }

        return try await authorizer.authorize(prepared).request
    }
}
