import Foundation

/// When and how long to wait before sending a request again.
///
/// A request is sent again only if all of this holds: attempts are left, the failure is one the
/// policy names, and repeating the request is safe — its method is idempotent, or it carries an
/// `Idempotency-Key` header, which says the server will treat a repeat as the same operation. A
/// `POST` without such a key is never repeated, however it failed: the server may have acted
/// on the first one.
public struct RetryPolicy: Sendable {
    /// The most times a request is sent in all, the first included; `1` means never repeat.
    public var maxAttempts: Int
    /// The wait before the first repeat, in seconds. Each further wait is `multiplier` times longer.
    public var initialDelay: TimeInterval
    public var multiplier: Double
    /// The longest wait between two attempts, before jitter.
    public var maxDelay: TimeInterval
    /// How far a wait may stray from its nominal length, as a fraction: `0.2` is up to 20% shorter
    /// or longer. It keeps many clients that failed together from coming back together.
    public var jitter: Double
    /// Statuses that are worth another try.
    public var statuses: Set<Int>
    /// Transport failures that are worth another try.
    public var transportFailures: Set<TransportFailure.Kind>
    /// The longest `Retry-After` the policy will wait out. When the server asks for more, the
    /// answer is returned as it is instead of sitting on it.
    public var maxRetryAfter: TimeInterval

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 30,
        jitter: Double = 0.2,
        statuses: Set<Int> = [408, 429, 500, 502, 503, 504],
        transportFailures: Set<TransportFailure.Kind> = [.timedOut, .connectionLost],
        maxRetryAfter: TimeInterval = 60
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.statuses = statuses
        self.transportFailures = transportFailures
        self.maxRetryAfter = maxRetryAfter
    }

    /// Sends every request once.
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Whether a request may be sent again at all.
    func allowsRepeating(_ request: HTTPRequest) -> Bool {
        request.method.isIdempotent || request.headers["Idempotency-Key"] != nil
    }

    /// The wait before attempt `attempt + 1`, where `attempt` counts from one. `random` is a number
    /// from 0 to 1.
    func delay(afterAttempt attempt: Int, random: Double) -> TimeInterval {
        let nominal = min(maxDelay, initialDelay * pow(multiplier, Double(attempt - 1)))
        let spread = 1 + jitter * (random * 2 - 1)
        return max(0, nominal * spread)
    }
}

extension HTTPResponse {
    /// How long the server asked to wait, from `Retry-After` given as seconds or as a date.
    func retryAfter(now: Date) -> TimeInterval? {
        guard let value = headers["Retry-After"]?.trimmingCharacters(in: .whitespaces)
        else { return nil }

        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
