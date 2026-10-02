import Foundation

/// A request with its credentials attached, and the version of the credentials it was signed
/// with.
public struct AuthorizedRequest: Sendable {
    public var request: HTTPRequest
    /// Tells which credentials signed the request, so that an answer of "unauthorized" can be
    /// told apart from one that is already out of date. `nil` when the request was not signed —
    /// it is for a server the credentials do not belong to, or has no credentials to carry — and
    /// then a `401` is not about our credentials and nothing is renewed.
    public var stamp: Int?

    public init(request: HTTPRequest, stamp: Int?) {
        self.request = request
        self.stamp = stamp
    }
}

/// Puts credentials on requests and renews them when the server refuses them.
///
/// Credentials come from the app — a keychain, an account — through the authorizer; the client
/// never stores them.
public protocol HTTPAuthorizer: Sendable {
    /// Returns `request` signed with the current credentials. A request for a server the
    /// credentials do not belong to must be returned unsigned.
    func authorize(_ request: HTTPRequest) async throws(HTTPError) -> AuthorizedRequest

    /// Called when the server answered `401` to a request signed with `stamp`. Renews the
    /// credentials if they are still the ones that were refused.
    ///
    /// - Returns: Whether the request is worth sending again with fresh credentials.
    func handleUnauthorized(stamp: Int) async throws(HTTPError) -> Bool
}

/// Credentials of the bearer kind for one server, renewed when the server refuses them.
///
/// Requests to other servers are sent without credentials, so a token never leaks to a host that
/// merely appears in a URL. When many requests are refused at once, one of them renews the token
/// and the rest wait for it: the refresh runs once, and then every one of them is sent again.
///
/// The authorizer holds neither the token nor the secret behind it; it asks `token` for the current
/// token each time and calls `refresh` to get a new one, and the app keeps both in the keychain or
/// wherever it chooses. `refresh` must store the new token before it returns, so that `token`
/// gives it from then on.
public actor TokenAuthorizer: HTTPAuthorizer {
    private let origin: HTTPOrigin
    private let scheme: String
    private let token: @Sendable () async throws -> String?
    private let refresh: @Sendable () async throws -> Void
    /// Counts completed renewals; a stamp lower than this belongs to a token already replaced.
    private var generation = 0
    private var refreshing: Task<Result<Void, any Error>, Never>?

    /// - Parameters:
    ///   - origin: The server the token is for.
    ///   - scheme: The word before the token in the header, `Bearer` by default.
    ///   - token: The current token, or `nil` when there is none, in which case requests go
    ///     unsigned.
    ///   - refresh: Obtains and stores a new token. Not called for more than one refused request
    ///     at a time.
    public init(
        origin: HTTPOrigin,
        scheme: String = "Bearer",
        token: @escaping @Sendable () async throws -> String?,
        refresh: @escaping @Sendable () async throws -> Void
    ) {
        self.origin = origin
        self.scheme = scheme
        self.token = token
        self.refresh = refresh
    }

    public func authorize(_ request: HTTPRequest) async throws(HTTPError) -> AuthorizedRequest {
        let stamp = generation
        guard HTTPOrigin(request.url) == origin, request.headers["Authorization"] == nil else {
            return AuthorizedRequest(request: request, stamp: nil)
        }

        let value: String?
        do {
            value = try await token()
        } catch {
            throw .authorizationFailed(underlying: error)
        }
        guard let value else { return AuthorizedRequest(request: request, stamp: nil) }

        var signed = request
        signed.headers["Authorization"] = "\(scheme) \(value)"
        return AuthorizedRequest(request: signed, stamp: stamp)
    }

    public func handleUnauthorized(stamp: Int) async throws(HTTPError) -> Bool {
        // The token was renewed after this request was signed: it only needs sending again.
        if stamp < generation { return true }

        let task: Task<Result<Void, any Error>, Never>
        if let running = refreshing {
            task = running
        } else {
            let refresh = refresh
            task = Task { await Result { try await refresh() } }
            refreshing = task
        }
        let result = await task.value
        // Several callers wake up here one after another; only the first finds the task still
        // registered and counts the renewal.
        if refreshing == task {
            refreshing = nil
            if case .success = result { generation += 1 }
        }
        switch result {
        case .success: return true
        case .failure(let error): throw .authorizationFailed(underlying: error)
        }
    }
}
