import Foundation
import StorageCore
import Testing
import os

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(
        initialState: Date(timeIntervalSince1970: 1_000_000)
    )

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// The behaviour every ``Cache`` has, checked by the tests of each implementation.
enum CacheContract {
    typealias Make = @Sendable (CachePolicy, TestClock) -> any Cache

    static func data(_ size: Int, _ byte: UInt8 = 1) -> Data { Data(repeating: byte, count: size) }

    /// `overhead` is what the cache adds to every value when it counts bytes against its limit.
    /// The size-limit checks use keys of one character, so that it is the same for every value.
    static func run(overhead: Int64, make: Make) async throws {
        try await storesAndReads(make)
        try await replacesAndRemoves(make)
        try await expiresIntoStaleAndRemovesExpired(make)
        try await evictsLeastRecentlyUsed(overhead: overhead, make)
        try await evictsExpiredBeforeUsed(overhead: overhead, make)
        try await refusesAValueOverTheLimit(overhead: overhead, make)
        try await storesCodableValues(make)
    }

    private static func storesAndReads(_ make: Make) async throws {
        let clock = TestClock()
        let cache = make(CachePolicy(), clock)

        guard case .miss = try await cache.get("a") else {
            Issue.record("An empty cache did not miss")
            return
        }
        try await cache.set(data(3, 7), for: "a")

        guard case .hit(let value, let storedAt) = try await cache.get("a") else {
            Issue.record("A stored value was not a hit")
            return
        }
        #expect(value == data(3, 7))
        #expect(abs(storedAt.timeIntervalSince(clock.now)) < 120)
    }

    private static func replacesAndRemoves(_ make: Make) async throws {
        let cache = make(CachePolicy(), TestClock())
        try await cache.set(data(2, 1), for: "r")
        try await cache.set(data(5, 2), for: "r")

        guard case .hit(let value, _) = try await cache.get("r") else {
            Issue.record("A replaced value was not a hit")
            return
        }
        #expect(value == data(5, 2))
        #expect(try await cache.remove("r") == true)
        #expect(try await cache.remove("r") == false)
        guard case .miss = try await cache.get("r") else {
            Issue.record("A removed value was not a miss")
            return
        }

        try await cache.set(data(1), for: "x")
        try await cache.set(data(1), for: "y")
        try await cache.removeAll()
        guard case .miss = try await cache.get("x"), case .miss = try await cache.get("y") else {
            Issue.record("removeAll left a value")
            return
        }
    }

    private static func expiresIntoStaleAndRemovesExpired(_ make: Make) async throws {
        let clock = TestClock()
        let cache = make(CachePolicy(timeToLive: 10), clock)
        try await cache.set(data(1, 1), for: "short")
        try await cache.set(data(1, 2), for: "long", timeToLive: 100)
        try await cache.set(data(1, 3), for: "forever", timeToLive: nil)

        clock.advance(11)
        guard case .stale(let value, _) = try await cache.get("short") else {
            Issue.record("An expired value was not stale")
            return
        }
        #expect(value == data(1, 1))
        guard case .hit = try await cache.get("long") else {
            Issue.record("A value with its own longer time expired early")
            return
        }

        // `forever` got the policy's ten seconds too: nil asks for the policy's time.
        #expect(try await cache.removeExpired() == 2)
        guard case .miss = try await cache.get("short") else {
            Issue.record("removeExpired left an expired value")
            return
        }
        guard case .hit = try await cache.get("long") else {
            Issue.record("removeExpired removed a fresh value")
            return
        }
    }

    private static func evictsLeastRecentlyUsed(overhead: Int64, _ make: Make) async throws {
        let cache = make(CachePolicy(maxBytes: 3 * (10 + overhead)), TestClock())
        try await cache.set(data(10), for: "a")
        try await cache.set(data(10), for: "b")
        try await cache.set(data(10), for: "c")
        _ = try await cache.get("a")  // a is now the most recently used

        try await cache.set(data(10), for: "d")

        guard case .hit = try await cache.get("a"), case .hit = try await cache.get("c"),
            case .hit = try await cache.get("d")
        else {
            Issue.record("A recently used value was evicted")
            return
        }
        guard case .miss = try await cache.get("b") else {
            Issue.record("The least recently used value was kept")
            return
        }
    }

    private static func evictsExpiredBeforeUsed(overhead: Int64, _ make: Make) async throws {
        let clock = TestClock()
        let cache = make(CachePolicy(maxBytes: 2 * (10 + overhead)), clock)
        try await cache.set(data(10), for: "o", timeToLive: 5)
        try await cache.set(data(10), for: "k", timeToLive: nil)
        _ = try await cache.get("k")
        _ = try await cache.get("o")  // used last, but expired below
        clock.advance(6)

        try await cache.set(data(10), for: "n")

        guard case .miss = try await cache.get("o") else {
            Issue.record("An expired value outlived a fresh one")
            return
        }
        guard case .hit = try await cache.get("k"), case .hit = try await cache.get("n") else {
            Issue.record("A fresh value was evicted before an expired one")
            return
        }
    }

    private static func refusesAValueOverTheLimit(overhead: Int64, _ make: Make) async throws {
        let cache = make(CachePolicy(maxBytes: 10 + overhead), TestClock())
        try await cache.set(data(10), for: "k")

        await #expect {
            try await cache.set(data(11), for: "k")
        } throws: { error in
            guard case CacheError.entryTooLarge(_, let limit) = error else { return false }
            return limit == 10 + overhead
        }
        // The refused write did not disturb what was there.
        guard case .hit(let value, _) = try await cache.get("k") else {
            Issue.record("A refused write removed the old value")
            return
        }
        #expect(value == data(10))
    }

    private struct Profile: Codable, Sendable, Equatable {
        var name: String
        var age: Int
    }

    private struct OtherShape: Codable, Sendable {
        var title: String
    }

    private static func storesCodableValues(_ make: Make) async throws {
        let cache = make(CachePolicy(), TestClock())
        try await cache.set(Profile(name: "Ann", age: 30), for: "p")

        guard case .hit(let profile, _) = try await cache.get(Profile.self, for: "p") else {
            Issue.record("A codable value was not a hit")
            return
        }
        #expect(profile == Profile(name: "Ann", age: 30))

        // Read with a shape it does not have: reported as a miss and removed, not thrown.
        guard case .miss = try await cache.get(OtherShape.self, for: "p") else {
            Issue.record("A value of another shape was not a miss")
            return
        }
        guard case .miss = try await cache.get("p") else {
            Issue.record("A value that did not decode was kept")
            return
        }
    }
}
