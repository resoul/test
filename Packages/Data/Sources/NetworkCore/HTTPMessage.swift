import Foundation

/// An HTTP method. The common ones are provided; any other token can be made with
/// ``init(_:)``.
public struct HTTPMethod: Hashable, Sendable, CustomStringConvertible {
    public let name: String

    /// - Parameter name: The method token, such as `"PROPFIND"`; it is upper-cased.
    public init(_ name: String) {
        self.name = name.uppercased()
    }

    public static let get = HTTPMethod("GET")
    public static let head = HTTPMethod("HEAD")
    public static let options = HTTPMethod("OPTIONS")
    public static let post = HTTPMethod("POST")
    public static let put = HTTPMethod("PUT")
    public static let patch = HTTPMethod("PATCH")
    public static let delete = HTTPMethod("DELETE")

    /// Whether repeating the request has the same effect as sending it once, by the HTTP
    /// standard. A retry policy repeats only these on its own: `POST` and `PATCH` are not, and
    /// `PUT` and `DELETE` are because they name a state, not an action.
    public var isIdempotent: Bool {
        ["GET", "HEAD", "OPTIONS", "TRACE", "PUT", "DELETE"].contains(name)
    }

    public var description: String { name }
}

/// Header fields, looked up without regard to case. A name may appear more than once.
public struct HTTPHeaders: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private struct Field: Sendable, Equatable {
        var name: String
        var value: String
    }

    private var fields: [Field] = []

    public init() {}

    public init(dictionaryLiteral elements: (String, String)...) {
        for (name, value) in elements { add(value, for: name) }
    }

    /// The first value of `name`. Assigning replaces every value of that name; `nil` removes them.
    public subscript(name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            remove(name)
            if let newValue { add(newValue, for: name) }
        }
    }

    /// Adds a value without disturbing the ones already there.
    public mutating func add(_ value: String, for name: String) {
        fields.append(Field(name: name, value: value))
    }

    public mutating func remove(_ name: String) {
        fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func values(for name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Every field in the order it was added, with the name as it was written.
    public var all: [(name: String, value: String)] { fields.map { ($0.name, $0.value) } }

    public var isEmpty: Bool { fields.isEmpty }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        let key: (Field) -> String = { $0.name.lowercased() + "\u{0}" + $0.value }
        return lhs.fields.map(key).sorted() == rhs.fields.map(key).sorted()
    }
}

/// The scheme, host and port that decide who a credential may be sent to. Two URLs with the same
/// origin trust each other; anything else is a different party.
public struct HTTPOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    /// - Returns: `nil` for a URL without a host or with a scheme other than `http` and `https`.
    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }

        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// A request to send. A value: change a copy.
public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: HTTPHeaders
    /// The whole body, held in memory, so that a request can be sent again exactly as it was.
    public var body: Data?
    /// How long to wait without any progress before giving up, in seconds; the transport's own
    /// default when `nil`.
    public var timeout: TimeInterval?

    public init(
        _ method: HTTPMethod = .get,
        _ url: URL,
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// A request whose body is `value` encoded as JSON, with `Content-Type` and `Accept` set
    /// unless the headers already name them.
    ///
    /// - Throws: ``HTTPError/encoding(underlying:)``.
    public static func json<Value: Encodable>(
        _ method: HTTPMethod,
        _ url: URL,
        body value: Value,
        headers: HTTPHeaders = [:],
        encoder: JSONEncoder = JSONEncoder(),
        timeout: TimeInterval? = nil
    ) throws(HTTPError) -> HTTPRequest {
        var request = HTTPRequest(method, url, headers: headers, timeout: timeout)
        do {
            request.body = try encoder.encode(value)
        } catch {
            throw .encoding(underlying: error)
        }
        if request.headers["Content-Type"] == nil {
            request.headers["Content-Type"] = "application/json"
        }
        if request.headers["Accept"] == nil { request.headers["Accept"] = "application/json" }
        return request
    }
}

/// An answer from the server. Any answer is a response, whatever its status: judging the status is
/// the caller's job, or ``HTTPClient``'s.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: HTTPHeaders
    /// Empty for a `204` or `HEAD` answer and for any answer with no body.
    public var body: Data
    /// The URL the answer came from, which differs from the request's after a redirect.
    public var url: URL

    public init(status: Int, headers: HTTPHeaders = [:], body: Data = Data(), url: URL) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }
}
