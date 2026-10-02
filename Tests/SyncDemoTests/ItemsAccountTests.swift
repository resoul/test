import Foundation
import NetworkCore
import StateCore
import StorageCore
import StorageGRDB
import Testing

@testable import SyncDemo

private func path(_ text: String) -> FilePath { try! FilePath(text) }

@Test(.timeLimit(.minutes(1)))
@MainActor
func signingOutLeavesNothingOfTheAccountAndStopsTheSocket() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })
    await model.attach(name: "note.txt", data: Data("hello".utf8), to: "item-1")
    #expect(await waitUntil { model.rows.value.contains { $0.attachment != nil } })

    try await harness.repository.signOut()

    #expect(await waitUntil { model.rows.value.isEmpty })
    #expect(try await harness.count("item") == 0)
    let state = try await harness.state()
    #expect(state.cursor == 0 && state.epoch == 1 && !state.synced)
    #expect(try await harness.files.list(nil).isEmpty)
    #expect(await waitUntil { await harness.server.socketCount == 0 })
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func anAnswerThatArrivesAfterSigningOutBringsNothingBack() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })

    await harness.server.setHoldingSnapshots(true)
    let late = Task { await model.refresh() }
    #expect(await waitUntil { await harness.server.snapshotRequests == 2 })

    try await harness.repository.signOut()
    await harness.server.setHoldingSnapshots(false)
    await late.value

    // The answer was built for the account that is gone, and finds a different epoch.
    #expect(try await harness.count("item") == 0)
    #expect(model.rows.value.isEmpty)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func theEpochRefusesALateAnswerEvenWhenNothingCancelsTheRequest() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })

    // The fetch is not one the repository tracks, so signing out cannot cancel it: only the epoch
    // stands between its answer and the database.
    await harness.server.setHoldingSnapshots(true)
    let untracked = Task { try await harness.repository.performRefresh() }
    #expect(await waitUntil { await harness.server.snapshotRequests == 2 })

    try await harness.repository.signOut()
    await harness.server.setHoldingSnapshots(false)
    try await untracked.value

    #expect(try await harness.count("item") == 0)
    #expect(model.rows.value.isEmpty)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aNewAccountCanStartAfterSigningOut() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.rows.value.count == 3 })

    try await harness.repository.signOut()
    #expect(await waitUntil { model.rows.value.isEmpty })
    await harness.repository.start()
    await model.refresh()

    #expect(await waitUntil { model.rows.value.count == 3 })
    #expect(await waitUntil { model.connection.value == .live })
    #expect(try await harness.state().epoch == 1)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func twoWindowsShareOneRepositoryAndOneSortButEachHasItsOwnModel() async throws {
    let harness = try await Harness.make(items: threeItems)
    let first = harness.model()
    let second = harness.model()
    first.start()
    second.start()
    #expect(await waitUntil { first.rows.value.count == 3 && second.rows.value.count == 3 })

    // A change on the server reaches both.
    await harness.server.externalUpsert(title: "Both see this")
    #expect(await waitUntil { await titles(first).contains("Both see this") })
    #expect(await waitUntil { await titles(second).contains("Both see this") })

    // The sort is the device's: set in one window, followed in the other.
    await first.setSort(.newest)
    #expect(await waitUntil { second.sort.value == .newest })
    #expect(await waitUntil { await titles(second).first == "Both see this" })
    #expect(await titles(first) == (await titles(second)))

    // Closing one window does not touch the other.
    first.stop()
    await harness.server.externalUpsert(title: "Only the second sees this")
    #expect(await waitUntil { await titles(second).contains("Only the second sees this") })
    #expect(!(await titles(first)).contains("Only the second sees this"))
    second.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func addingAnItemShowsItOnceEvenThoughTheSocketReportsItToo() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.rows.value.count == 3 })

    await model.add(title: "Added here")

    #expect(await waitUntil { model.rows.value.count == 4 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(await titles(model).filter { $0 == "Added here" }.count == 1)
    #expect(model.problem.value == nil)
    let server = await harness.server.snapshot
    #expect(try await harness.state().cursor == server.cursor)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aLostReplyToAnAddIsRepeatedSafelyAndMakesOneItem() async throws {
    let harness = try await Harness.make(
        items: threeItems,
        retry: RetryPolicy(maxAttempts: 3, initialDelay: 0.01, jitter: 0)
    )
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.connection.value == .live && model.rows.value.count == 3 })

    // The server creates the item and the reply is lost; the client repeats the request, which
    // carries the same key.
    await harness.server.loseNextPostReply()
    await model.add(title: "Once only")

    #expect(await waitUntil { await titles(model).contains("Once only") })
    #expect(await harness.server.postsHandled == 2)
    #expect(await harness.server.snapshot.items.filter { $0.title == "Once only" }.count == 1)
    #expect(await titles(model).filter { $0 == "Once only" }.count == 1)
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func anAddThatFailsIsReportedAndLeavesTheListAlone() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.rows.value.count == 3 })
    await harness.server.failNextPosts(with: [503])

    await model.add(title: "Will not be added")

    #expect(model.problem.value == "The server answered with an error (503).")
    #expect(model.rows.value.count == 3)
    // A later success clears the message.
    await model.add(title: "Will be added")
    #expect(model.problem.value == nil)
    #expect(await waitUntil { model.rows.value.count == 4 })
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func anAttachmentIsKeptOnThisDeviceSurvivesARefreshAndGoesWithItsItem() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.rows.value.count == 3 })

    await model.attach(name: "note.txt", data: Data("hello".utf8), to: "item-2")

    #expect(await waitUntil { model.rows.value.first { $0.id == "item-2" }?.attachment != nil })
    #expect(
        model.rows.value.first { $0.id == "item-2" }?.attachment
            == Attachment(name: "note.txt", size: 5)
    )
    #expect(
        try await harness.repository.attachment(of: "item-2", named: "note.txt")
            == Data("hello".utf8)
    )

    // A fresh snapshot replaces the list but not what this device attached.
    await model.refresh()
    #expect(model.rows.value.first { $0.id == "item-2" }?.attachment?.name == "note.txt")

    // When the server deletes the item, its file goes too.
    await harness.server.externalDelete(id: "item-2")
    #expect(await waitUntil { !model.rows.value.contains { $0.id == "item-2" } })
    #expect(await waitUntil { (try? await harness.files.list(nil).isEmpty) == true })
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aFileNameThatCannotBeUsedIsReportedAndNothingIsKept() async throws {
    let harness = try await Harness.make(items: threeItems)
    let model = harness.model()
    model.start()
    #expect(await waitUntil { model.rows.value.count == 3 })

    await model.attach(name: "../escape.txt", data: Data("x".utf8), to: "item-1")

    #expect(model.problem.value == "That file name cannot be used.")
    #expect(try await harness.files.list(nil).isEmpty)
    #expect(model.rows.value.allSatisfy { $0.attachment == nil })
    model.stop()
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aStoppedModelIsFreedWithoutWaitingForAnything() async throws {
    let harness = try await Harness.make(items: threeItems)
    weak var weakModel: ItemsModel?
    do {
        let model = harness.model()
        weakModel = model
        model.start()
        #expect(await waitUntil { model.rows.value.count == 3 })
        model.stop()
    }

    // Nothing holds it: no task, no subscription.
    #expect(await waitUntil { weakModel == nil })
}

@Test(.timeLimit(.minutes(1)))
@MainActor
func aModelThatWasNeverStoppedIsStillReleasedWhenItsOwnerLetsGo() async throws {
    // The subscriptions hold the model weakly, so even a forgotten stop() does not make a cycle.
    let harness = try await Harness.make(items: threeItems)
    weak var weakModel: ItemsModel?
    do {
        let model = harness.model()
        weakModel = model
        model.start()
        #expect(await waitUntil { model.rows.value.count == 3 })
    }

    #expect(await waitUntil { weakModel == nil })
}
