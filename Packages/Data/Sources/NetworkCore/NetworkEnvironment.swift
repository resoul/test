import Foundation

/// What the network clients take from the outside world — the clock, waiting, and chance — so that a
/// test can replace each part and run a backoff without waiting.
public struct NetworkEnvironment: Sendable {
    public var now: @Sendable () -> Date
    /// Waits for the given number of seconds; throws if the task is cancelled meanwhile.
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// A number from 0 to 1, for jitter.
    public var random: @Sendable () -> Double

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.now = now
        self.sleep = sleep
        self.random = random
    }
}
