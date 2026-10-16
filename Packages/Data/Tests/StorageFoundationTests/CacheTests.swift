import Foundation
import StorageCore
import Testing
import os

@testable import StorageFoundation

private final class EventLog: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [CacheEvent]())

    var events: [CacheEvent] { stored.withLock { $0 } }

    func record(_ event: CacheEvent) { stored.withLock { $0.append(event) } }
}

/// The bytes a `DiskCache` adds to a value under a one-character key: magic, key length, key, and
/// the checksum.
private let diskOverhead: Int64 = 4 + 4 + 1 + 32

private func path(_ text: String) -> FilePath { FileStoreContract.path(text) }

private func data(_ size: Int, _ byte: UInt8 = 1) -> Data { CacheContract.data(size, byte) }

private func files(_ store: any FileStore) async throws -> [String] {
    try await store.list(nil).map(\.path.description)
}

@Test
func aMemoryCacheKeepsTheCacheContract() async throws {
    try await CacheContract.run(overhead: 0) { policy, clock in
        MemoryCache(policy: policy, now: { clock.now })
    }
}

@Test
func aDiskCacheOverMemoryFilesKeepsTheCacheContract() async throws {
    try await CacheContract.run(overhead: diskOverhead) { policy, clock in
        let store = MemoryFileStore(now: { clock.now })
        return DiskCache(store: store, policy: policy, now: { clock.now })
    }
}

@Test
func aDiskCacheOverARealDirectoryKeepsTheCacheContract() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CacheTests." + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await CacheContract.run(overhead: diskOverhead) { policy, clock in
        DiskCache(store: DiskFileStore(root: root), policy: policy, now: { clock.now })
    }
}

@Test
func valuesSurviveANewCacheOverTheSameStore() async throws {
    let clock = TestClock()
    let store = MemoryFileStore(now: { clock.now })
    let first = DiskCache(store: store, policy: CachePolicy(timeToLive: 10), now: { clock.now })
    try await first.set(data(4, 9), for: "k")

    clock.advance(5)
    let second = DiskCache(store: store, policy: CachePolicy(timeToLive: 10), now: { clock.now })
    guard case .hit(let value, _) = try await second.get("k") else {
        Issue.record("A value was lost with the cache object")
        return
    }
    #expect(value == data(4, 9))

    // The expiry is part of the file name, so it also survives.
    clock.advance(6)
    guard case .stale = try await second.get("k") else {
        Issue.record("A restarted cache forgot the value's expiry")
        return
    }
}

@Test
func aChangedTimeToLiveReplacesTheFileInsteadOfLeavingTwo() async throws {
    let store = MemoryFileStore()
    let cache = DiskCache(store: store)

    try await cache.set(data(2), for: "k", timeToLive: 10)
    try await cache.set(data(2), for: "k", timeToLive: 20)

    #expect(try await files(store).count == 1)
}

@Test
func aDamagedFileIsAMissByDefaultAndIsReportedAndRemoved() async throws {
    let log = EventLog()
    let store = MemoryFileStore()
    let cache = DiskCache(store: store, diagnostics: { log.record($0) })
    try await cache.set(data(8, 5), for: "k")
    let name = try #require(await files(store).first)
    var blob = try await store.read(path(name))
    blob[blob.count - 1] ^= 0xFF  // flip a bit of the value
    try await store.write(blob, to: path(name))

    guard case .miss = try await cache.get("k") else {
        Issue.record("A damaged value was returned")
        return
    }

    #expect(log.events.count == 1)
    guard case .corrupted(let key, let reason)? = log.events.first else {
        Issue.record("The damage was not reported")
        return
    }
    #expect(key == "k")
    #expect(reason.contains("checksum"))
    #expect(try await files(store).isEmpty)
}

@Test
func aDamagedFileThrowsWhenThePolicySaysSo() async throws {
    let store = MemoryFileStore()
    let cache = DiskCache(store: store, policy: CachePolicy(corruption: .throwError))
    try await cache.set(data(8), for: "k")
    let name = try #require(await files(store).first)
    try await store.write(
        Data("not a cache file at all, but long enough to have a header".utf8),
        to: path(name)
    )

    await #expect {
        try await cache.get("k")
    } throws: { error in
        guard case CacheError.corrupted(let key, _) = error else { return false }
        return key == "k"
    }
    // The damaged entry is gone, so asking again is an ordinary miss.
    guard case .miss = try await cache.get("k") else {
        Issue.record("A damaged entry was kept after it was reported")
        return
    }
}

@Test
func aTruncatedFileIsDamagedToo() async throws {
    let store = MemoryFileStore()
    let cache = DiskCache(store: store)
    try await cache.set(data(100), for: "k")
    let name = try #require(await files(store).first)
    let blob = try await store.read(path(name))
    try await store.write(blob.prefix(20), to: path(name))

    guard case .miss = try await cache.get("k") else {
        Issue.record("A truncated value was returned")
        return
    }
    #expect(try await files(store).isEmpty)
}

@Test
func entriesOfAnotherVersionAreDroppedNotMisread() async throws {
    let store = MemoryFileStore()
    let old = DiskCache(store: store, policy: CachePolicy(version: 1))
    try await old.set(data(3), for: "k")
    try await store.write(data(1), to: path("unrelated.txt"))

    let current = DiskCache(store: store, policy: CachePolicy(version: 2))
    guard case .miss = try await current.get("k") else {
        Issue.record("A value of another version was read")
        return
    }

    // The old entry is deleted; a file that is not the cache's is left alone.
    #expect(try await files(store) == ["unrelated.txt"])
}

@Test
func aFileRemovedBehindTheCachesBackIsAMiss() async throws {
    let store = MemoryFileStore()
    let cache = DiskCache(store: store)
    try await cache.set(data(3), for: "k")
    let name = try #require(await files(store).first)
    await store.remove(path(name))

    guard case .miss = try await cache.get("k") else {
        Issue.record("A vanished file was a hit")
        return
    }
}

@Test
func afterARestartTheOldestWriteIsEvictedFirst() async throws {
    let clock = TestClock()
    let store = MemoryFileStore(now: { clock.now })
    let first = DiskCache(store: store, now: { clock.now })
    for key in ["a", "b", "c"] {
        try await first.set(data(10), for: key)
        clock.advance(1)
    }

    let restarted = DiskCache(
        store: store,
        policy: CachePolicy(maxBytes: 3 * (10 + diskOverhead)),
        now: { clock.now }
    )
    try await restarted.set(data(10), for: "d")

    guard case .miss = try await restarted.get("a") else {
        Issue.record("The oldest write survived")
        return
    }
    guard case .hit = try await restarted.get("b"), case .hit = try await restarted.get("c"),
        case .hit = try await restarted.get("d")
    else {
        Issue.record("A newer write was evicted")
        return
    }
}

@Test
func removeAllEmptiesTheStoreEvenOfFilesItDoesNotKnow() async throws {
    let store = MemoryFileStore()
    let cache = DiskCache(store: store)
    try await cache.set(data(3), for: "k")
    try await store.write(data(1), to: path("stray.txt"))

    try await cache.removeAll()

    #expect(try await files(store).isEmpty)
}

@Test
func concurrentWritesAndEvictionsLeaveACoherentCache() async throws {
    let store = MemoryFileStore()
    let limit = 5 * (10 + diskOverhead)
    let cache = DiskCache(store: store, policy: CachePolicy(maxBytes: limit))

    try await withThrowingTaskGroup(of: Void.self) { group in
        for number in 0..<40 {
            group.addTask {
                let key = String(UnicodeScalar(UInt8(97 + number % 26)))
                try await cache.set(data(10, UInt8(number)), for: key)
                _ = try await cache.get(key)
            }
        }
        try await group.waitForAll()
    }

    let listed = try await store.list(nil)
    #expect(listed.reduce(Int64(0)) { $0 + $1.metadata.size } <= limit)
    // Every file on disk is one the cache can read back, so the index and the store agree.
    for item in listed { #expect(try await store.read(item.path).count == 10 + Int(diskOverhead)) }
}
