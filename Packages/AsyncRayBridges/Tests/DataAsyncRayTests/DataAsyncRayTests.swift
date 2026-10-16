import AsyncRay
import Foundation
import GRDB
import NetworkCore
import StorageCore
import StorageGRDB
import Testing
import os

@testable import DataAsyncRay

/// What a subscription received, and a count of the times a query ran.
private final class Collected<Value: Sendable>: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Value]())

    var all: [Value] { values.withLock { $0 } }

    func add(_ value: Value) { values.withLock { $0.append(value) } }
}

private final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { count.withLock { $0 } }

    func increment() { count.withLock { $0 += 1 } }
}

private let createNotes = DatabaseMigration("createNotes") { db in
    try db.create(table: "note") { table in table.column("text", .text).notNull() }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<2500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

private func count(_ db: Database) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? -1
}

@Test(.timeLimit(.minutes(1)))
func aDatabaseRayGivesTheSnapshotNowAndAfterEachCommit() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createNotes])
    let seen = Collected<Int>()
    let subscription = store.observeRay { db in try count(db) }
        .sink { result in if case .success(let value) = result { seen.add(value) } }

    #expect(await waitUntil { seen.all == [0] })
    try await store.write { db in try db.execute(sql: "INSERT INTO note VALUES ('a')") }
    #expect(await waitUntil { seen.all.last == 1 })
    subscription.cancel()
}

@Test(.timeLimit(.minutes(1)))
func aFailingQueryArrivesAsAFailureNotAsAnEmptyValue() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createNotes])
    let failures = Collected<String>()
    let successes = Collected<Int>()
    let subscription = store.observeRay { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM no_such_table") ?? 0
    }
    .sink { result in
        switch result {
        case .success(let value): successes.add(value)
        case .failure: failures.add("failed")
        }
    }

    #expect(await waitUntil { failures.all.count == 1 })
    #expect(successes.all.isEmpty)
    subscription.cancel()
}

@Test(.timeLimit(.minutes(1)))
func cancellingASubscriptionEndsTheObservationItStarted() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createNotes])
    let runs = Counter()
    let subscription = store.observeRay { db in
        runs.increment()
        return try count(db)
    }
    .sink { _ in }
    #expect(await waitUntil { runs.value == 1 })
    try await store.write { db in try db.execute(sql: "INSERT INTO note VALUES ('a')") }
    #expect(await waitUntil { runs.value == 2 })

    subscription.cancel()
    // Give the cancellation time to reach the observation, then write: nothing re-runs the query.
    try await Task.sleep(for: .milliseconds(100))
    let before = runs.value
    for _ in 0..<5 {
        try await store.write { db in try db.execute(sql: "INSERT INTO note VALUES ('b')") }
    }
    try await Task.sleep(for: .milliseconds(100))

    #expect(runs.value == before)
    // And the store can be closed at once: nothing is left holding it.
    try await store.close()
}

@Test(.timeLimit(.minutes(1)))
func everySubscriptionStartsItsOwnObservationAndEndsItAlone() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createNotes])
    let ray = store.observeRay { db in try count(db) }
    let first = Collected<Int>()
    let second = Collected<Int>()
    let one = ray.sink { result in if case .success(let value) = result { first.add(value) } }
    let two = ray.sink { result in if case .success(let value) = result { second.add(value) } }
    #expect(await waitUntil { first.all == [0] && second.all == [0] })

    one.cancel()
    try await store.write { db in try db.execute(sql: "INSERT INTO note VALUES ('a')") }

    #expect(await waitUntil { second.all.last == 1 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(first.all == [0], "A cancelled subscription went on receiving")
    two.cancel()
}

@Test(.timeLimit(.minutes(1)))
func aSubscriptionBagThatIsReleasedEndsWhatItHeld() async throws {
    let store = try await DatabaseStore.open(.inMemory, migrations: [createNotes])
    let runs = Counter()
    do {
        let bag = SubscriptionBag()
        store.observeRay { db in
            runs.increment()
            return try count(db)
        }
        .sink { _ in }
        .store(in: bag)
        #expect(await waitUntil { runs.value == 1 })
        bag.cancelAll()
    }
    try await Task.sleep(for: .milliseconds(100))
    let before = runs.value

    try await store.write { db in try db.execute(sql: "INSERT INTO note VALUES ('a')") }
    try await Task.sleep(for: .milliseconds(100))

    #expect(runs.value == before)
}

@Test(.timeLimit(.minutes(1)))
func aPreferenceRayFollowsTheValueAndReportsADamagedOneWithoutEnding() async throws {
    let key = PreferenceKey("count", default: 0)
    let preferences = MemoryPreferences(["count": .string("not a number")])
    let seen = Collected<String>()
    let subscription = preferences.valuesRay(for: key).sink { result in
        switch result {
        case .success(let value): seen.add("value \(value)")
        case .failure: seen.add("damaged")
        }
    }

    #expect(await waitUntil { seen.all == ["damaged"] })
    await preferences.remove(key)
    #expect(await waitUntil { seen.all.last == "value 0" })
    try await preferences.set(7, for: key)
    #expect(await waitUntil { seen.all.last == "value 7" })
    subscription.cancel()
}

@Test(.timeLimit(.minutes(1)))
func aSocketStateRayShowsTheClientsStatesAndStopsWhenCancelled() async throws {
    struct Refusing: WebSocketTransport {
        func connect(_ request: HTTPRequest, maxMessageBytes: Int) async throws(WebSocketError)
            -> any WebSocketConnection
        {
            throw .handshakeRejected(status: 403)
        }
    }
    let client = WebSocketClient(
        request: HTTPRequest(.get, URL(string: "wss://example.com/live")!),
        transport: Refusing()
    )
    let seen = Collected<String>()
    let subscription = client.statesRay.sink { state in
        switch state {
        case .idle: seen.add("idle")
        case .connecting: seen.add("connecting")
        case .failed: seen.add("failed")
        default: seen.add("other")
        }
    }
    #expect(await waitUntil { seen.all.contains("idle") })

    await client.connect()

    #expect(await waitUntil { seen.all.last == "failed" })
    subscription.cancel()
    await client.close()
}
