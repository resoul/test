import Foundation
import NetworkCore
import StateCore
import StorageCore
import StorageGRDB
import Testing

@testable import SyncDemo

@Test(.timeLimit(.minutes(1)))
@MainActor
func openingTheListShowsTheServersItemsFromTheDatabaseInTheDefaultOrder() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()

    model.start()

    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })
    // By title, ignoring case: the order is the database's, not the server's.
    #expect(model.rows.value.map(\.title) == ["apple", "Banana", "Cherry"])
    #expect(await waitUntil { model.connection.value == .live })
    #expect(try await harness.state().cursor == 3)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aLiveChangeReachesTheScreenThroughTheDatabaseAndMovesTheCursorWithIt() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.phase.value == .loaded })

    await harness.server.externalUpsert(title: "Date")
    await harness.server.externalDelete(id: "item-1")

    #expect(await waitUntil { await titles(model) == ["apple", "Cherry", "Date"] })
    let server = await harness.server.snapshot
    #expect(await waitUntil { (try? await harness.state().cursor) == server.cursor })
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aLostConnectionIsRemadeAndWhatWasMissedArrivesAsReplayNotAsAWholeSnapshot() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.phase.value == .loaded })
    #expect(await harness.server.snapshotRequests == 1)

    await harness.server.setOnline(false)
    #expect(await waitUntil { model.connection.value != .live })
    await harness.server.externalUpsert(title: "While away 1")
    await harness.server.externalUpsert(title: "While away 2")
    await harness.server.setOnline(true)

    #expect(await waitUntil { await titles(model).contains("While away 2") })
    #expect(await titles(model).contains("While away 1"))
    #expect(await titles(model).count == 5)
    // Only the first fetch was a snapshot: the rest came as the changes after the cursor.
    #expect(await harness.server.snapshotRequests == 1)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aReplayThatRepeatsWhatIsAlreadyStoredChangesNothing() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.phase.value == .loaded })
    await harness.server.externalUpsert(title: "Once")
    #expect(await waitUntil { await titles(model).contains("Once") })
    let before = model.rows.value

    // A new connection is told where the device is, so nothing is sent again; and even a repeat
    // would be ignored by its number.
    await harness.server.simulateDroppedConnections()
    #expect(await waitUntil { await harness.server.socketCount == 1 })
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.rows.value == before)
    #expect(try await harness.count("item") == 4)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func ifTheServerNoLongerKeepsWhatWasMissedASnapshotIsFetched() async throws {
    let harness = try await Harness.make(items: threeItems, retention: 2)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.phase.value == .loaded })

    await harness.server.setOnline(false)
    #expect(await waitUntil { model.connection.value != .live })
    for number in 1...5 { await harness.server.externalUpsert(title: "Missed \(number)") }
    await harness.server.setOnline(true)

    #expect(await waitUntil { await titles(model).contains("Missed 5") })
    #expect(await titles(model).count == 8)
    #expect(await harness.server.snapshotRequests == 2)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aSnapshotOlderThanAChangeAlreadyStoredIsDiscarded() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.phase.value == .loaded })

    // A refresh whose answer is slow: it is built now, at the current cursor, and arrives later.
    await harness.server.setHoldingSnapshots(true)
    let slow = Task { await model.refresh() }
    #expect(await waitUntil { await harness.server.snapshotRequests == 2 })

    // Meanwhile a newer change arrives over the socket and is stored.
    await harness.server.externalUpsert(title: "Newer than the snapshot")
    #expect(await waitUntil { await titles(model).contains("Newer than the snapshot") })
    let cursorAfterChange = try await harness.state().cursor

    await harness.server.setHoldingSnapshots(false)
    await slow.value

    // The old snapshot did not undo it.
    #expect(await titles(model).contains("Newer than the snapshot"))
    #expect(try await harness.state().cursor == cursorAfterChange)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aFailedRefreshKeepsTheRowsAndSaysWhyAndALaterOneRecovers() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })
    let rows = model.rows.value

    await harness.server.setOnline(false)
    await model.refresh()

    #expect(model.phase.value == .failed("There is no network connection."))
    #expect(model.rows.value == rows)

    await harness.server.setOnline(true)
    await model.refresh()
    #expect(model.phase.value == .loaded)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aCancelledRefreshIsNotShownAsAFailure() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })
    let rows = model.rows.value

    await harness.server.setHoldingSnapshots(true)
    let refresh = Task { await model.refresh() }
    #expect(await waitUntil { await harness.server.snapshotRequests == 2 })
    #expect(model.phase.value == .loading)
    refresh.cancel()
    await refresh.value

    // Not a failure, and the rows are as they were.
    if case .failed = model.phase.value { Issue.record("A cancellation was shown as a failure") }
    #expect(model.phase.value != .loading)
    #expect(model.rows.value == rows)
    await harness.server.setHoldingSnapshots(false)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aDatabaseThatCannotBeReadIsAFailureOnTheScreenNotAnEmptyList() async throws {
    // A database without the schema: every query fails.
    let harness = try await Harness.make(items: threeItems, migrations: [])
    let model = harness.model()

    model.start()

    #expect(
        await waitUntil {
            model.phase.value == .failed("The list on this device could not be read.")
        }
    )
    model.stop()
}
