import Foundation
import StateCore
import Testing

@testable import SyncDemo

@Test(.timeLimit(.minutes(1)))
@MainActor
func aDemoSessionStartsInTitleOrderWithItsThreeItemsAndALiveConnection() async throws {
    let session = try await DemoSession.make()
    let model = session.makeModel()

    model.start()

    #expect(await waitUntil { model.phase.value == .loaded && model.rows.value.count == 3 })
    #expect(model.sort.value == .title)
    #expect(model.rows.value.map(\.title) == ["apple", "Banana", "Cherry"])
    #expect(await waitUntil { model.connection.value == .live })
    model.stop()
}
