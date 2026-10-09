import Foundation

/// An event the client reports about a request; see ``HTTPClient/diagnostics``.
///
/// An event carries the method, the URL without its query or fragment — which often hold tokens
/// or personal data — and the status or a short description. Never headers and never bodies.
public enum HTTPEvent: Sendable, Equatable {
    case sending(method: String, url: String, attempt: Int)
    case received(method: String, url: String, status: Int, attempt: Int)
    /// The request failed with `reason` and will be sent again after `delay` seconds.
    case retrying(method: String, url: String, attempt: Int, delay: TimeInterval, reason: String)
    /// The server refused the credentials and they were renewed; the request is sent again.
    case reauthorizing(method: String, url: String)
}

/// Statuses a caller accepts as the answer it wanted.
public struct HTTPStatuses: Sendable {
    private let accepts: @Sendable (Int) -> Bool

    public init(_ accepts: @escaping @Sendable (Int) -> Bool) {
        self.accepts = accepts
    }

    public func contains(_ status: Int) -> Bool { accepts(status) }

    /// Any `2xx`, `204` included.
    public static let success = HTTPStatuses { (200...299).contains($0) }

    /// Exactly the listed statuses; use it when a missing resource, say, is an answer.
    public static func only(_ statuses: Int...) -> HTTPStatuses {
        let set = Set(statuses)
        return HTTPStatuses { set.contains($0) }
    }

    /// A `2xx` or one of the listed statuses.
    public static func success(or extra: Int...) -> HTTPStatuses {
        let set = Set(extra)
        return HTTPStatuses { (200...299).contains($0) || set.contains($0) }
    }
}

/// Sends requests through a transport and judges the answers: which statuses are acceptable,
/// when to try again, how to authorize, how to decode.
///
/// A client is a value and `Sendable`; copies share the transport and the authorizer, and any
/// number of requests may run on one at once. It keeps no state of its own, so the only things to
/// cancel are the requests themselves: cancelling a task cancels its request and, if it is waiting
/// between attempts, ends the wait; the error is ``HTTPError/cancelled``.
///
/// The client does not use the network itself. Pass a ``HTTPTransport`` — a URLSession-based one,
/// or a fake in tests.
public struct HTTPClient: Sendable {
    /// What the client needs from the outside world, so that a test can replace each part.
    public typealias Environment = NetworkEnvironment

    private let transport: any HTTPTransport
    /// The server that ``url(for:query:)`` and ``request(_:_:query:headers:body:timeout:)`` build
    /// addresses on; `nil` when the client is only given complete URLs.
    public var baseURL: URL?
    /// Headers added to every request that does not set them itself.
    public var defaultHeaders: HTTPHeaders
    public var retry: RetryPolicy
    public var authorizer: (any HTTPAuthorizer)?
    /// The most body bytes accepted in an answer; `nil` for no limit. Ten mebibytes by default.
    public var maxResponseBytes: Int?
    public var environment: Environment
    /// Told about each attempt. Called on whatever thread the request runs on, so keep it short.
    public var diagnostics: (@Sendable (HTTPEvent) -> Void)?
    /// Makes the decoder for ``send(_:as:)``; a decoder is not `Sendable`, so each use gets its own.
    public var makeDecoder: @Sendable () -> JSONDecoder

    public init(
        transport: any HTTPTransport,
        baseURL: URL? = nil,
        defaultHeaders: HTTPHeaders = [:],
        retry: RetryPolicy = .none,
        authorizer: (any HTTPAuthorizer)? = nil,
        maxResponseBytes: Int? = 10 * 1024 * 1024,
        environment: Environment = Environment(),
        diagnostics: (@Sendable (HTTPEvent) -> Void)? = nil,
        makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.retry = retry
        self.authorizer = authorizer
        self.maxResponseBytes = maxResponseBytes
        self.environment = environment
        self.diagnostics = diagnostics
        self.makeDecoder = makeDecoder
    }

    /// Sends `request` and returns the answer if its status is one of `expecting`.
    ///
    /// The body of the answer may be empty — a `204` has none — so check it before using it.
    ///
    /// Any other status is thrown as ``HTTPError/status(_:)`` with the whole response, unless it is
    /// worth another try by the retry policy, in which case the request is sent again, up to the
    /// policy's limit; the last answer is thrown if none of them was acceptable. A `401` for a
    /// request that was signed by the authorizer renews the credentials once and sends the request
    /// again, whatever the method: a refused request was not acted on.
    ///
    /// - Throws: ``HTTPError``; ``HTTPError/cancelled`` when the task is cancelled, including during
    ///   a wait between attempts.
    public func send(_ request: HTTPRequest, expecting statuses: HTTPStatuses = .success)
        async throws(HTTPError) -> HTTPResponse
    {
        try await perform(
            request,
            expecting: statuses,
            response: { $0 },
            discard: { _ in },
            transmit: { (outgoing: HTTPRequest) async throws(HTTPError) -> HTTPResponse in
                try await transport.send(outgoing, maxResponseBytes: maxResponseBytes)
            }
        )
    }

    /// Sends `request` and writes the body of the answer to the file at `destination`, without
    /// holding it in memory when the transport can avoid it.
    ///
    /// Statuses, retries and credentials work as for ``send(_:expecting:)``, and each attempt starts
    /// a file of its own. The file is put at `destination` only once an answer is accepted: until
    /// then, and after any failure or cancellation, `destination` is untouched and nothing is left
    /// behind. An existing file there is replaced, missing directories above it are created. An
    /// accepted answer that is not a `2xx` (a `404` taken as an answer, say) has no file; its body
    /// comes back in the response and `destination` stays as it was.
    ///
    /// **Continuing.** Given `partial`, the bytes are collected in its file, which **stays** when the
    /// download breaks off — by a failure or by cancellation — together with a record of what
    /// the server said the bytes belong to. The next call with the same `partial` asks the server for the
    /// rest only, on condition that the thing is unchanged (see ``PartialDownload``); a retry inside
    /// one call does the same, so a connection lost halfway costs only what was not yet received. If the
    /// thing changed, or cannot be continued, the file starts over. When the answer is complete
    /// the file is moved to `destination` and the record removed. An answer that says the range is
    /// beyond the end is taken to mean that the file was already whole if its size is the thing's
    /// size — the answer returned is then that `416`, and the `file` of the result is
    /// `destination` — and otherwise the partial file is discarded and the download is made again
    /// whole.
    ///
    /// - Parameters:
    ///   - maxBytes: The most body bytes to accept; `nil` for no limit, which is the default
    ///     because a download exists for what does not fit ``maxResponseBytes``. The disk is the limit
    ///     then. With `partial` it limits the size of the whole file.
    ///   - partial: Where the unfinished download is kept, to be continued; `nil` for a download
    ///     that is started over each time.
    /// - Returns: The answer with an empty body and the file at `destination`.
    /// - Throws: As ``send(_:expecting:)``, ``HTTPError/responseTooLarge(limit:)`` when the body
    ///   passes `maxBytes` (a partial file is then discarded: nothing is gained by continuing what is
    ///   too big), and ``HTTPError/fileSystem(underlying:)`` when the file cannot be written or put in
    ///   place. After cancellation, ``HTTPError/cancelled``.
    public func download(
        _ request: HTTPRequest,
        to destination: URL,
        expecting statuses: HTTPStatuses = .success,
        maxBytes: Int? = nil,
        continuing partial: PartialDownload? = nil
    ) async throws(HTTPError) -> HTTPDownload {
        var result: HTTPDownload
        do {
            result = try await perform(
                request,
                expecting: statuses,
                response: { $0.response },
                // A partial file belongs to its download, whatever one attempt came to.
                discard: { if partial == nil { Self.removeQuietly($0.file) } },
                transmit: { (outgoing: HTTPRequest) async throws(HTTPError) -> HTTPDownload in
                    var attempt = outgoing
                    if let headers = partial?.resumeHeaders() {
                        for (name, value) in headers.all { attempt.headers[name] = value }
                    }
                    return try await transport.download(
                        attempt,
                        maxBytes: maxBytes,
                        partial: partial
                    )
                }
            )
        } catch {
            if case .responseTooLarge = error { partial?.discard() }
            guard let partial, case .status(let refused) = error, refused.status == 416 else {
                throw error
            }

            // The range starts beyond the end of the thing. If the file is as big as the thing, it
            // is the thing; otherwise it is not what was thought, and is made again whole.
            guard let total = PartialDownload.contentRange(of: refused.headers)?.total,
                total == partial.size
            else {
                partial.discard()
                return try await download(
                    request,
                    to: destination,
                    expecting: statuses,
                    maxBytes: maxBytes,
                    continuing: partial
                )
            }

            result = HTTPDownload(response: refused, file: partial.file, bytes: Int(total))
        }
        guard let temporary = result.file else { return result }

        if Task.isCancelled {
            if partial == nil { Self.removeQuietly(temporary) }
            throw .cancelled
        }
        do {
            try Self.place(temporary, at: destination)
        } catch {
            if partial == nil { Self.removeQuietly(temporary) }
            throw .fileSystem(underlying: error)
        }
        partial?.discardRecord()
        result.file = destination
        return result
    }

    /// Sends `request` with the content of `file` as its body, without reading the whole file into
    /// memory when the transport can avoid it.
    ///
    /// The request's own `body` is ignored. Statuses, retries and credentials work as for
    /// ``send(_:expecting:)``; the file is read again for each attempt, so a retry sends exactly
    /// what the first attempt sent, if the file did not change meanwhile.
    ///
    /// - Throws: As ``send(_:expecting:)``, and ``HTTPError/fileSystem(underlying:)`` when the file
    ///   cannot be read.
    public func upload(
        _ request: HTTPRequest,
        fromFile file: URL,
        expecting statuses: HTTPStatuses = .success
    ) async throws(HTTPError) -> HTTPResponse {
        try await perform(
            request,
            expecting: statuses,
            response: { $0 },
            discard: { _ in },
            transmit: { (outgoing: HTTPRequest) async throws(HTTPError) -> HTTPResponse in
                try await transport.upload(outgoing, fromFile: file, maxResponseBytes: maxResponseBytes)
            }
        )
    }

    /// Sends `request` with the stream `body` as its body: one that is produced as it goes, so that
    /// it need not be in memory or in a file.
    ///
    /// Statuses, retries and credentials work as for ``send(_:expecting:)``, and every attempt takes a
    /// new stream from `body`, which therefore has to be able to start over; see ``HTTPBodyStream``.
    /// The request's own `body` is ignored.
    ///
    /// - Throws: As ``send(_:expecting:)``, and ``HTTPError/fileSystem(underlying:)`` when a stream
    ///   cannot be made or read.
    public func upload(
        _ request: HTTPRequest,
        from body: HTTPBodyStream,
        expecting statuses: HTTPStatuses = .success
    ) async throws(HTTPError) -> HTTPResponse {
        try await perform(
            request,
            expecting: statuses,
            response: { $0 },
            discard: { _ in },
            transmit: { (outgoing: HTTPRequest) async throws(HTTPError) -> HTTPResponse in
                try await transport.upload(outgoing, from: body, maxResponseBytes: maxResponseBytes)
            }
        )
    }

    /// The attempts, retries and credential renewal that every kind of transfer shares.
    ///
    /// - Parameters:
    ///   - response: The answer inside an outcome, for judging its status.
    ///   - discard: Releases what an outcome holds when it is not returned — the file of an attempt
    ///     that is retried or refused.
    ///   - transmit: One attempt.
    private func perform<Outcome>(
        _ request: HTTPRequest,
        expecting statuses: HTTPStatuses,
        response responseOf: (Outcome) -> HTTPResponse,
        discard: (Outcome) -> Void,
        transmit: (HTTPRequest) async throws(HTTPError) -> Outcome
    ) async throws(HTTPError) -> Outcome {
        var prepared = request
        for (name, value) in defaultHeaders.all where prepared.headers[name] == nil {
            prepared.headers[name] = value
        }
        let label = Self.describe(prepared.url)
        let method = prepared.method.name
        var attempt = 1
        var hasRenewedCredentials = false

        while true {
            if Task.isCancelled { throw .cancelled }

            var outgoing = prepared
            var stamp: Int?
            if let authorizer {
                let authorized = try await authorizer.authorize(prepared)
                outgoing = authorized.request
                stamp = authorized.stamp
            }
            diagnostics?(.sending(method: method, url: label, attempt: attempt))

            let outcome: Outcome
            do {
                outcome = try await transmit(outgoing)
            } catch {
                if case .transport(let failure) = error, canRetry(prepared, attempt: attempt),
                    retry.transportFailures.contains(failure.kind)
                {
                    try await wait(
                        retry.delay(afterAttempt: attempt, random: environment.random()),
                        method: method,
                        url: label,
                        attempt: attempt,
                        reason: "\(failure.kind)"
                    )
                    attempt += 1
                    continue
                }
                throw error
            }
            let response = responseOf(outcome)
            diagnostics?(
                .received(method: method, url: label, status: response.status, attempt: attempt)
            )

            if response.status == 401, let authorizer, let stamp, !hasRenewedCredentials {
                let renewed: Bool
                do {
                    renewed = try await authorizer.handleUnauthorized(stamp: stamp)
                } catch {
                    discard(outcome)
                    throw error
                }
                if renewed {
                    discard(outcome)
                    hasRenewedCredentials = true
                    diagnostics?(.reauthorizing(method: method, url: label))
                    continue
                }
            }
            if statuses.contains(response.status) { return outcome }
            discard(outcome)

            if retry.statuses.contains(response.status), canRetry(prepared, attempt: attempt) {
                let computed = retry.delay(afterAttempt: attempt, random: environment.random())
                let requested = response.retryAfter(now: environment.now())
                // A server that asks for a very long wait is not waited for.
                if let requested, requested > retry.maxRetryAfter { throw .status(response) }

                try await wait(
                    max(computed, requested ?? 0),
                    method: method,
                    url: label,
                    attempt: attempt,
                    reason: "status \(response.status)"
                )
                attempt += 1
                continue
            }
            throw .status(response)
        }
    }

    /// Sends `request` and decodes the body as JSON.
    ///
    /// - Throws: The errors of ``send(_:expecting:)``; ``HTTPError/emptyResponse`` when the answer
    ///   has no body; ``HTTPError/decoding(underlying:)`` when it does not decode as `Value`.
    public func send<Value: Decodable & Sendable>(
        _ request: HTTPRequest,
        as type: Value.Type,
        expecting statuses: HTTPStatuses = .success
    ) async throws(HTTPError) -> Value {
        let response = try await send(request, expecting: statuses)
        if response.body.isEmpty { throw .emptyResponse }

        do {
            return try makeDecoder().decode(Value.self, from: response.body)
        } catch {
            throw .decoding(underlying: error)
        }
    }

    private func canRetry(_ request: HTTPRequest, attempt: Int) -> Bool {
        attempt < retry.maxAttempts && retry.allowsRepeating(request)
    }

    /// Waits out a retry delay, telling the diagnostics how long it is.
    private func wait(
        _ delay: TimeInterval,
        method: String,
        url: String,
        attempt: Int,
        reason: String
    ) async throws(HTTPError) {
        diagnostics?(
            .retrying(method: method, url: url, attempt: attempt, delay: delay, reason: reason)
        )
        do {
            try await environment.sleep(delay)
        } catch {
            throw .cancelled
        }
    }

    // MARK: Addresses

    /// The address of `path` on the ``baseURL``.
    ///
    /// `path` is given as it is meant, not percent-encoded: each segment is encoded here, so a
    /// name with a space or a `?` in it stays one segment. A leading `/` makes no difference —
    /// the path always continues the base URL's own path — and empty segments are dropped. `.` and
    /// `..` segments are refused so that a name taken from outside cannot climb out of the base
    /// path. The base URL's query and fragment are not carried over. Query items are encoded
    /// strictly: only unreserved characters stay as they are, so a `+` or `&` in a value is data.
    ///
    /// - Throws: ``HTTPError/invalidRequest(_:)`` without an `http` or `https` base URL, or with a
    ///   `.` or `..` segment.
    public func url(for path: String, query: [URLQueryItem] = []) throws(HTTPError) -> URL {
        guard let baseURL, HTTPOrigin(baseURL) != nil else {
            throw .invalidRequest("the client has no http or https base URL")
        }

        return try Self.address(of: path, on: baseURL, query: query)
    }

    /// The address of `path` on `base`, which may also be a `ws` or `wss` URL; the rules are those of
    /// ``url(for:query:)``, which checks that the base is an `http` or `https` one first.
    static func address(of path: String, on base: URL, query: [URLQueryItem] = [])
        throws(HTTPError) -> URL
    {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
            parts.host?.isEmpty == false
        else { throw .invalidRequest("\(base) is not an address with a host") }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.contains(where: { $0 == "." || $0 == ".." }) {
            throw .invalidRequest("\(path) has a . or .. segment")
        }
        var prefix = parts.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        parts.percentEncodedPath =
            prefix + "/"
            + segments.map { encode($0, allowing: segmentCharacters) }.joined(separator: "/")
        parts.fragment = nil
        parts.percentEncodedQuery =
            query.isEmpty
            ? nil
            : query.map {
                encode($0.name, allowing: unreservedCharacters) + "="
                    + encode($0.value ?? "", allowing: unreservedCharacters)
            }.joined(separator: "&")
        guard let url = parts.url else { throw .invalidRequest("\(path) is not a valid path") }

        return url
    }

    /// A request for `path` on the ``baseURL``; see ``url(for:query:)`` for how the address is made.
    public func request(
        _ method: HTTPMethod = .get,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws(HTTPError) -> HTTPRequest {
        HTTPRequest(
            method,
            try url(for: path, query: query),
            headers: headers,
            body: body,
            timeout: timeout
        )
    }

    /// A request for `path` on the ``baseURL`` whose body is `value` encoded as JSON; see
    /// ``HTTPRequest/json(_:_:body:headers:encoder:timeout:)``.
    public func request<Value: Encodable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        json value: Value,
        headers: HTTPHeaders = [:],
        encoder: JSONEncoder = JSONEncoder(),
        timeout: TimeInterval? = nil
    ) throws(HTTPError) -> HTTPRequest {
        try HTTPRequest.json(
            method,
            try url(for: path, query: query),
            body: value,
            headers: headers,
            encoder: encoder,
            timeout: timeout
        )
    }

    private static let segmentCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ text: String, allowing allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    // MARK: Files

    /// Puts `temporary` at `destination`, replacing what is there.
    private static func place(_ temporary: URL, at destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
    }

    private static func removeQuietly(_ file: URL?) {
        guard let file else { return }

        try? FileManager.default.removeItem(at: file)
    }

    /// The URL without query and fragment.
    private static func describe(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "(invalid url)"
        }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? "(invalid url)"
    }
}
