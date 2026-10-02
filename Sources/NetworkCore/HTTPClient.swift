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
        defaultHeaders: HTTPHeaders = [:],
        retry: RetryPolicy = .none,
        authorizer: (any HTTPAuthorizer)? = nil,
        maxResponseBytes: Int? = 10 * 1024 * 1024,
        environment: Environment = Environment(),
        diagnostics: (@Sendable (HTTPEvent) -> Void)? = nil,
        makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }
    ) {
        self.transport = transport
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

            let response: HTTPResponse
            do {
                response = try await transport.send(outgoing, maxResponseBytes: maxResponseBytes)
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
            diagnostics?(
                .received(method: method, url: label, status: response.status, attempt: attempt)
            )

            if response.status == 401, let authorizer, let stamp, !hasRenewedCredentials,
                try await authorizer.handleUnauthorized(stamp: stamp)
            {
                hasRenewedCredentials = true
                diagnostics?(.reauthorizing(method: method, url: label))
                continue
            }
            if statuses.contains(response.status) { return response }

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
