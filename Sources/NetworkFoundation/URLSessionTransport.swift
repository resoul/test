import Foundation
import NetworkCore

/// An ``HTTPTransport`` over `URLSession`.
///
/// **Limits.** The body is read as it arrives and reading stops, and the connection is dropped, as
/// soon as it passes the limit; an answer that announces a larger size is refused before any body
/// is read. So a server cannot make a request use more memory than the limit.
///
/// **Redirects.** Followed, up to the system's own limit, unless ``RedirectPolicy/refuse`` is
/// chosen, in which case the redirect response itself is returned. The `Authorization`, `Cookie`
/// and `Proxy-Authorization` headers stay with a redirect that remains on the origin the request
/// was addressed to, and are dropped for any other origin, so credentials never follow a request
/// to a party they were not meant for. A redirect from `https` to `http` is never followed.
///
/// **Cookies.** Requests do not take part in the cookie store: the headers a request carries are
/// the headers that are sent. Put a `Cookie` header on the request if one is needed.
///
/// **Caching.** Whatever `URLCache` the session's configuration gives; the transport adds nothing.
public struct URLSessionTransport: HTTPTransport {
    public enum RedirectPolicy: Sendable {
        case follow
        /// Return the `3xx` response itself.
        case refuse
    }

    let session: URLSession
    let redirects: RedirectPolicy
    let downloadDirectory: URL

    /// - Parameters:
    ///   - session: The session to use; it is held, not owned, so the app decides when to
    ///     invalidate it. A session of its own is made when none is given.
    ///   - redirects: What to do with a redirect.
    ///   - downloadDirectory: Where ``download(_:maxBytes:)`` makes its files, which are then the
    ///     caller's to move or delete. The system's temporary directory by default; it must exist.
    public init(
        session: URLSession = URLSession(configuration: .default),
        redirects: RedirectPolicy = .follow,
        downloadDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.session = session
        self.redirects = redirects
        self.downloadDirectory = downloadDirectory
    }

    public func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        let urlRequest = try Self.makeURLRequest(request)

        do {
            let (bytes, urlResponse) = try await session.bytes(
                for: urlRequest,
                delegate: RedirectDelegate(policy: redirects)
            )
            guard let http = urlResponse as? HTTPURLResponse else {
                throw HTTPError.notHTTPResponse
            }

            let announced = http.expectedContentLength
            if let limit = maxResponseBytes, request.method != .head, announced > Int64(limit) {
                throw HTTPError.responseTooLarge(limit: limit)
            }
            var body = Data()
            if request.method != .head {
                if announced > 0 {
                    body.reserveCapacity(Int(min(announced, Int64(maxResponseBytes ?? Int.max))))
                }
                for try await byte in bytes {
                    body.append(byte)
                    if let limit = maxResponseBytes, body.count > limit {
                        throw HTTPError.responseTooLarge(limit: limit)
                    }
                }
            }
            var headers = HTTPHeaders()
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String {
                    headers.add(value, for: name)
                }
            }
            return HTTPResponse(
                status: http.statusCode,
                headers: headers,
                body: body,
                url: http.url ?? request.url
            )
        } catch let error as HTTPError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    /// The `URLRequest` for `request`; the body is left to the caller, because an upload takes it
    /// from a file.
    static func makeURLRequest(_ request: HTTPRequest, includingBody: Bool = true) throws(HTTPError)
        -> URLRequest
    {
        guard HTTPOrigin(request.url) != nil else {
            throw .invalidRequest("\(request.url) is not an http or https URL")
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.name
        for (name, value) in request.headers.all {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        if includingBody { urlRequest.httpBody = request.body }
        urlRequest.httpShouldHandleCookies = false
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        return urlRequest
    }

    static func map(_ error: any Error) -> HTTPError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else {
            return .transport(TransportFailure(kind: .other, underlying: error))
        }

        let kind: TransportFailure.Kind
        switch urlError.code {
        case .cancelled: return .cancelled
        case .badURL, .unsupportedURL: return .invalidRequest(urlError.localizedDescription)
        case .timedOut: kind = .timedOut
        case .networkConnectionLost: kind = .connectionLost
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: kind = .cannotConnect
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            kind = .notConnected
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired:
            kind = .secureConnectionFailed
        default: kind = .other
        }
        return .transport(TransportFailure(kind: kind, underlying: error))
    }
}

/// What to do with a redirect: whether to follow it and which credentials go along. Shared by
/// every kind of transfer, so a download and an upload treat credentials as a plain request does.
enum RedirectRules {
    static func decide(
        policy: URLSessionTransport.RedirectPolicy,
        task: URLSessionTask,
        response: HTTPURLResponse,
        newRequest request: URLRequest
    ) -> URLRequest? {
        guard case .follow = policy, let target = request.url,
            let targetOrigin = HTTPOrigin(target),
            let source = response.url, let sourceOrigin = HTTPOrigin(source)
        else { return nil }

        if sourceOrigin.scheme == "https" && targetOrigin.scheme == "http" { return nil }

        // URLSession drops `Authorization` on every redirect, even one that stays on the same
        // server. A request is meant for the origin it was addressed to, so credentials are put
        // back while the redirect is still there, and are gone for any other origin.
        let sensitive = ["Authorization", "Cookie", "Proxy-Authorization"]
        var next = request
        if let original = task.originalRequest, let first = original.url,
            HTTPOrigin(first) == targetOrigin
        {
            for name in sensitive where next.value(forHTTPHeaderField: name) == nil {
                next.setValue(original.value(forHTTPHeaderField: name), forHTTPHeaderField: name)
            }
        } else {
            for name in sensitive { next.setValue(nil, forHTTPHeaderField: name) }
        }
        return next
    }
}

/// Decides each redirect of one request.
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: URLSessionTransport.RedirectPolicy

    init(policy: URLSessionTransport.RedirectPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectRules.decide(policy: policy, task: task, response: response, newRequest: request)
    }
}
