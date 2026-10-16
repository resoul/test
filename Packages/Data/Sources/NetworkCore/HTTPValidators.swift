import Foundation

/// What a server said about a stored response: the validators that let a copy be checked cheaply
/// later, and until when the copy may be used without asking at all.
///
/// A cache that keeps HTTP responses keeps one of these beside each. When ``isFresh(at:)`` is
/// false it asks the server again with ``conditionalHeaders``, and a `304` answer means the copy
/// is still good — ``init(headers:now:keeping:)`` then renews the freshness and keeps the
/// validators the `304` does not repeat. The type is plain data and `Codable`, so a cache can put it
/// wherever it keeps its entries.
///
/// This follows the rules of HTTP caching (RFC 9111) for what a single-user cache needs:
/// `Cache-Control` `no-store`, `no-cache` and `max-age`, `Age`, and `Expires`. `Vary` and
/// `s-maxage`, which concern shared caches and content negotiation, are not handled: a cache that
/// keys entries by URL alone must not store responses that vary.
public struct HTTPValidators: Sendable, Codable, Equatable {
    public var etag: String?
    public var lastModified: String?
    /// When the copy stops being usable without a check; `nil` when the server said nothing about
    /// freshness, which leaves it to the cache how long it keeps the copy.
    public var freshUntil: Date?

    public init(etag: String? = nil, lastModified: String? = nil, freshUntil: Date? = nil) {
        self.etag = etag
        self.lastModified = lastModified
        self.freshUntil = freshUntil
    }

    /// The validators and freshness of a response received at `now`.
    ///
    /// - Parameters:
    ///   - headers: The response's headers.
    ///   - stored: The validators of the copy this response is the answer to a check of. A `304`
    ///     leaves out validators it has not changed, so those are carried over.
    public init(headers: HTTPHeaders, now: Date, keeping stored: HTTPValidators? = nil) {
        etag = headers["ETag"] ?? stored?.etag
        lastModified = headers["Last-Modified"] ?? stored?.lastModified
        freshUntil = Self.freshUntil(headers, now: now)
    }

    /// Whether a check with the server can use these: there is an `ETag` or `Last-Modified`.
    /// Without one a stale copy can only be fetched again whole.
    public var canRevalidate: Bool { etag != nil || lastModified != nil }

    /// Whether the copy may be used at `date` without asking the server.
    public func isFresh(at date: Date) -> Bool {
        guard let freshUntil else { return true }

        return date < freshUntil
    }

    /// The headers that turn a request into a check of the stored copy: the server answers `304`
    /// with no body if it is unchanged. Empty when ``canRevalidate`` is false.
    public var conditionalHeaders: HTTPHeaders {
        var headers = HTTPHeaders()
        if let etag { headers["If-None-Match"] = etag }
        if let lastModified { headers["If-Modified-Since"] = lastModified }
        return headers
    }

    /// `Cache-Control: no-store`: the response must not be written anywhere.
    public static func forbidsStoring(_ headers: HTTPHeaders) -> Bool {
        directives(headers).keys.contains("no-store")
    }

    /// `no-cache` is stale at once; `max-age` counts from the response minus its `Age`; else
    /// `Expires`. Without any of them, `nil`.
    private static func freshUntil(_ headers: HTTPHeaders, now: Date) -> Date? {
        let directives = directives(headers)
        if directives.keys.contains("no-cache") { return now }
        if let value = directives["max-age"], let seconds = value.flatMap(Double.init) {
            let age = headers["Age"].flatMap(Double.init) ?? 0
            return now.addingTimeInterval(max(0, seconds - max(0, age)))
        }
        if let expires = headers["Expires"] {
            // An invalid date means already expired (RFC 9111 §5.3).
            return httpDate(expires) ?? now
        }
        return nil
    }

    /// `Cache-Control` directives by lowercased name, with their values.
    private static func directives(_ headers: HTTPHeaders) -> [String: String?] {
        var directives: [String: String?] = [:]
        for header in headers.values(for: "Cache-Control") {
            for part in header.split(separator: ",") {
                let pair = part.split(separator: "=", maxSplits: 1)
                guard let name = pair.first?.trimmingCharacters(in: .whitespaces).lowercased(),
                    !name.isEmpty
                else { continue }

                directives[name] =
                    pair.count > 1
                    ? pair[1].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    : String?.none
            }
        }
        return directives
    }

    /// An HTTP date in its preferred form, `Sun, 06 Nov 1994 08:49:37 GMT`.
    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
