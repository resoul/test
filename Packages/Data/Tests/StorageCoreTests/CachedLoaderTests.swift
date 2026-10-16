import Foundation
import Testing

@testable import StorageCore

private actor Probe {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var finished = 0
    private var isOpen = false

    func open() { isOpen = true }

    /// A fetch that starts, waits until the test opens it, and gives `value`. Cancellation is
    /// counted and thrown, the way a well-behaved fetch reacts.
    func fetch(_ value: String) async throws -> Data {
        started += 1
        while !isOpen {
            if Task.isCancelled {
                cancelled += 1
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        finished += 1
        return Data(value.utf8)
    }
}

private struct Boom: Error {}

private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<2000 where !(await condition()) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test
func aFetchedValueIsStoredAndTheNextCallDoesNotFetch() async throws {
    let cache = MemoryCache()
    let loader = CachedLoader(cache: cache)
    let probe = Probe()
    await probe.open()

    let first = try await loader.value(for: "k") { try await probe.fetch("one") }
    let second = try await loader.value(for: "k") { try await probe.fetch("two") }

    #expect(text(first) == "one")
    #expect(text(second) == "one")
    #expect(await probe.started == 1)
}

@Test
func aStaleValueIsFetchedAgain() async throws {
    let clock = ManualClock()
    let cache = MemoryCache(policy: CachePolicy(timeToLive: 10), now: { clock.now })
    let loader = CachedLoader(cache: cache)
    let probe = Probe()
    await probe.open()
    _ = try await loader.value(for: "k") { try await probe.fetch("old") }
    clock.advance(11)

    let refreshed = try await loader.value(for: "k") { try await probe.fetch("new") }

    #expect(text(refreshed) == "new")
    #expect(await probe.started == 2)
}

@Test
func callersOfTheSameKeyShareOneFetch() async throws {
    let loader = CachedLoader(cache: MemoryCache())
    let probe = Probe()
    let callers = (0..<3).map { _ in
        Task { try await loader.value(for: "k") { try await probe.fetch("shared") } }
    }
    await waitUntil { await loader.waiterCount(for: "k") == 3 }

    await probe.open()

    for caller in callers { #expect(text(try await caller.value) == "shared") }
    #expect(await probe.started == 1)
}

@Test
func cancellingOneCallerLeavesTheOthersWaiting() async throws {
    let loader = CachedLoader(cache: MemoryCache())
    let probe = Probe()
    let staying = Task { try await loader.value(for: "k") { try await probe.fetch("kept") } }
    let leaving = Task { try await loader.value(for: "k") { try await probe.fetch("kept") } }
    await waitUntil { await loader.waiterCount(for: "k") == 2 }

    leaving.cancel()
    await #expect(throws: CancellationError.self) { try await leaving.value }
    await waitUntil { await loader.waiterCount(for: "k") == 1 }
    await probe.open()

    #expect(text(try await staying.value) == "kept")
    #expect(await probe.cancelled == 0)
    #expect(await probe.started == 1)
}

@Test
func cancellingEveryCallerCancelsTheFetchAndStoresNothing() async throws {
    let cache = MemoryCache()
    let loader = CachedLoader(cache: cache)
    let probe = Probe()
    let callers = (0..<2).map { _ in
        Task { try await loader.value(for: "k") { try await probe.fetch("never") } }
    }
    await waitUntil { await loader.waiterCount(for: "k") == 2 }

    for caller in callers { caller.cancel() }
    for caller in callers {
        await #expect(throws: CancellationError.self) { try await caller.value }
    }
    await waitUntil { await probe.cancelled == 1 }

    #expect(await probe.cancelled == 1)
    guard case .miss = await cache.get("k") else {
        Issue.record("A cancelled fetch stored a value")
        return
    }
}

@Test
func aFailedFetchGivesEveryCallerTheErrorAndIsNotStored() async throws {
    let cache = MemoryCache()
    let loader = CachedLoader(cache: cache)
    let gate = Probe()
    let callers = (0..<2).map { _ in
        Task {
            try await loader.value(for: "k") {
                _ = try await gate.fetch("")
                throw Boom()
            }
        }
    }
    await waitUntil { await loader.waiterCount(for: "k") == 2 }
    await gate.open()

    for caller in callers { await #expect(throws: Boom.self) { try await caller.value } }
    guard case .miss = await cache.get("k") else {
        Issue.record("A failed fetch stored a value")
        return
    }
    // The failure is not remembered: the next call fetches again.
    let probe = Probe()
    await probe.open()
    #expect(text(try await loader.value(for: "k") { try await probe.fetch("again") }) == "again")
}

@Test
func invalidatingDuringAFetchCancelsItsCallersAndALateResultStoresNothing() async throws {
    let cache = MemoryCache()
    let loader = CachedLoader(cache: cache)
    let slow = SlowFetch()
    let caller = Task { try await loader.value(for: "k") { await slow.fetch() } }
    await waitUntil { await loader.waiterCount(for: "k") == 1 }

    try await loader.invalidate()
    await #expect(throws: CancellationError.self) { try await caller.value }

    // The fetch ignores cancellation and finishes anyway, as a careless one would.
    await slow.release()
    await waitUntil { await slow.finished }
    try await Task.sleep(for: .milliseconds(50))

    guard case .miss = await cache.get("k") else {
        Issue.record("A late result came back after the cache was cleared")
        return
    }
}

@Test
func invalidatingClearsWhatTheCacheHolds() async throws {
    let cache = MemoryCache()
    let loader = CachedLoader(cache: cache)
    let probe = Probe()
    await probe.open()
    _ = try await loader.value(for: "a") { try await probe.fetch("a") }

    try await loader.invalidate()

    guard case .miss = await cache.get("a") else {
        Issue.record("invalidate left a value")
        return
    }
}

/// A fetch that does not look at cancellation: it waits to be released and then answers.
private actor SlowFetch {
    private var released = false
    private(set) var finished = false

    func release() { released = true }

    func fetch() async -> Data {
        while !released { try? await Task.sleep(for: .milliseconds(2)) }
        finished = true
        return Data("late".utf8)
    }
}
