import Foundation
import StorageCore
import Testing
import os

private final class EventLog: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [CacheEvent]())

    var events: [CacheEvent] { stored.withLock { $0 } }

    func record(_ event: CacheEvent) { stored.withLock { $0.append(event) } }
}

@Test
func evictionIsReportedWithTheEntriesAndBytesRemoved() async throws {
    let log = EventLog()
    let cache = MemoryCache(
        policy: CachePolicy(maxBytes: 25),
        diagnostics: { log.record($0) }
    )
    try await cache.set(Data(repeating: 1, count: 10), for: "a")
    try await cache.set(Data(repeating: 1, count: 10), for: "b")

    try await cache.set(Data(repeating: 1, count: 10), for: "c")

    #expect(log.events == [.evicted(entries: 1, bytes: 10)])
}

@Test
func aLargeValueThatFitsAloneIsKeptAndPushesTheRestOut() async throws {
    let cache = MemoryCache(policy: CachePolicy(maxBytes: 20))
    try await cache.set(Data(repeating: 1, count: 5), for: "small")

    try await cache.set(Data(repeating: 2, count: 20), for: "big")

    guard case .hit = await cache.get("big") else {
        Issue.record("The value just written was evicted")
        return
    }
    guard case .miss = await cache.get("small") else {
        Issue.record("The older value was kept past the limit")
        return
    }
}

@Test
func replacingAValueFreesItsOldBytes() async throws {
    let cache = MemoryCache(policy: CachePolicy(maxBytes: 20))
    for _ in 0..<10 { try await cache.set(Data(repeating: 1, count: 15), for: "k") }

    try await cache.set(Data(repeating: 1, count: 4), for: "other")

    // Had the old bytes stayed counted, "k" would have been evicted by now.
    guard case .hit = await cache.get("k") else {
        Issue.record("Replacing a value left its old size counted")
        return
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let current = OSAllocatedUnfairLock(
        initialState: Date(timeIntervalSince1970: 1_000_000)
    )

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
