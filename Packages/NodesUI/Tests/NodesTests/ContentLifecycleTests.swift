import Nodes
import Testing

@Test
func coldVisibleDemandDoesNotPretendAnyPreparationIsReady() throws {
    var content = ContentLifecycle(key: "item")
    let changeRequest = content.updateDemand(.visible)
    let change = try #require(changeRequest)

    #expect(change.previous.isEmpty)
    #expect(change.entered == [.preload, .measure, .display, .visible])
    #expect(change.exited.isEmpty)
    #expect(change.cancelled.isEmpty)
    for phase in PreparationPhase.allCases {
        #expect(content.readiness[phase] == .idle)
        #expect(content.begin(phase) != nil)
        #expect(content.readiness[phase] == .running)
        #expect(content.begin(phase) == nil)
    }
    #expect(content.updateDemand([.visible, .preload, .measure, .display]) == nil)
}

@Test
func geometryCanBePreparedBeforeResourceBytesOrDisplayAreNeeded() throws {
    var content = ContentLifecycle(key: 1, demand: .measure)
    let measurementRequest = content.begin(.measurement)
    let measurement = try #require(measurementRequest)

    #expect(content.begin(.data) == nil)
    #expect(content.begin(.drawing) == nil)
    #expect(content.complete(measurement, with: .ready) == true)
    #expect(content.readiness.measurement == .ready)
    #expect(content.readiness.data == .idle)
    #expect(content.readiness.drawing == .idle)
    #expect(!content.demand.contains(.visible))

    content.updateDemand(.visible)
    #expect(content.begin(.measurement) == nil)
    #expect(content.begin(.data) != nil)
    #expect(content.begin(.drawing) != nil)
}

@Test
func leavingVisibleKeepsNearbyWorkAndLeavingPreloadInvalidatesOnlyClientAttempts() throws {
    var content = ContentLifecycle(key: 1, demand: .visible)
    let dataRequest = content.begin(.data)
    let data = try #require(dataRequest)
    let measurementRequest = content.begin(.measurement)
    let measurement = try #require(measurementRequest)
    let drawingRequest = content.begin(.drawing)
    let drawing = try #require(drawingRequest)

    let noLongerVisibleRequest = content.updateDemand(.display)
    let noLongerVisible = try #require(noLongerVisibleRequest)
    #expect(noLongerVisible.exited == .visible)
    #expect(noLongerVisible.cancelled.isEmpty)
    #expect(content.isCurrent(data))
    #expect(content.isCurrent(drawing))

    #expect(content.complete(measurement, with: .ready) == true)
    let noLongerDisplayedRequest = content.updateDemand(.preload)
    let noLongerDisplayed = try #require(noLongerDisplayedRequest)
    #expect(noLongerDisplayed.cancelled == [drawing])
    #expect(content.readiness.measurement == .ready)
    #expect(content.readiness.drawing == .cancelled)
    #expect(content.complete(drawing, with: .ready) == false)
    #expect(content.isCurrent(data))

    let noLongerNeededRequest = content.updateDemand([])
    let noLongerNeeded = try #require(noLongerNeededRequest)
    #expect(noLongerNeeded.cancelled == [data])
    #expect(content.complete(data, with: .failed) == false)
    #expect(content.readiness.data == .cancelled)
}

@Test
func reentryUsesReadyContentAndDoesNotAcceptThePreviousCancelledAttempt() throws {
    var content = ContentLifecycle(key: "row", demand: .display)
    let dataRequest = content.begin(.data)
    let data = try #require(dataRequest)
    let drawingRequest = content.begin(.drawing)
    let drawing = try #require(drawingRequest)
    #expect(content.complete(data, with: .ready) == true)

    content.updateDemand([])
    content.updateDemand(.visible)
    #expect(content.begin(.data) == nil)
    #expect(content.readiness.data == .ready)
    let replacementRequest = content.begin(.drawing)
    let replacement = try #require(replacementRequest)
    #expect(replacement != drawing)
    #expect(content.complete(drawing, with: .ready) == false)
    #expect(content.readiness.drawing == .running)
    #expect(content.complete(replacement, with: .ready) == true)
    #expect(content.complete(replacement, with: .failed) == false)
    #expect(content.readiness.drawing == .ready)
}

@Test
func aPreparationFailureNeedsExplicitRetryEvenAfterRangeReentry() throws {
    var content = ContentLifecycle(key: 1, demand: .visible)
    let firstRequest = content.begin(.data)
    let first = try #require(firstRequest)
    #expect(content.complete(first, with: .failed) == true)
    #expect(content.readiness.data == .failed)
    #expect(content.begin(.data) == nil)

    content.updateDemand([])
    content.updateDemand(.visible)
    #expect(content.begin(.data) == nil)
    let retryRequest = content.begin(.data, retrying: true)
    let retry = try #require(retryRequest)
    #expect(retry != first)
    #expect(content.complete(first, with: .ready) == false)
    #expect(content.complete(retry, with: .cancelled) == true)
    #expect(content.readiness.data == .cancelled)
    #expect(content.begin(.data) != nil)
}

@Test
func releasingOnePhaseLeavesOtherReadyContentAndInvalidatesItsOldTicket() throws {
    var content = ContentLifecycle(key: 1, demand: .display)
    let dataRequest = content.begin(.data)
    let data = try #require(dataRequest)
    let drawingRequest = content.begin(.drawing)
    let drawing = try #require(drawingRequest)
    #expect(content.complete(data, with: .ready) == true)

    #expect(content.release(.drawing) == drawing)
    #expect(content.readiness.drawing == .idle)
    #expect(content.readiness.data == .ready)
    #expect(content.complete(drawing, with: .ready) == false)
    let nextDrawingRequest = content.begin(.drawing)
    let nextDrawing = try #require(nextDrawingRequest)
    #expect(content.complete(nextDrawing, with: .ready) == true)
    #expect(content.release(.drawing) == nil)
    #expect(content.readiness.drawing == .idle)
    #expect(content.readiness.data == .ready)
}

@Test
func resettingEvenTheSameKeyRejectsOldWorkAndDropsReadinessWithoutDroppingDemand() throws {
    var content = ContentLifecycle(key: 1, demand: .visible)
    let dataRequest = content.begin(.data)
    let data = try #require(dataRequest)
    let measurementRequest = content.begin(.measurement)
    let measurement = try #require(measurementRequest)
    let drawingRequest = content.begin(.drawing)
    let drawing = try #require(drawingRequest)
    #expect(content.complete(data, with: .ready) == true)

    #expect(content.reset(for: 1) == [measurement, drawing])
    #expect(content.demand == ContentDemand.visible.requirements)
    #expect(content.readiness == ContentReadiness())
    #expect(content.complete(drawing, with: .ready) == false)
    #expect(content.complete(measurement, with: .ready) == false)
    #expect(content.complete(data, with: .ready) == false)
    #expect(content.begin(.data) != nil)
}

private struct PreparationKey: Sendable, Hashable {
    let revision: Int
    let width: Int
    let locale: String
    let theme: String
}

@Test(arguments: [
    PreparationKey(revision: 2, width: 200, locale: "en", theme: "light"),
    PreparationKey(revision: 1, width: 400, locale: "en", theme: "light"),
    PreparationKey(revision: 1, width: 200, locale: "ru", theme: "light"),
    PreparationKey(revision: 1, width: 200, locale: "en", theme: "dark"),
])
private func aRevisionOrEnvironmentChangeRejectsTheLateWorkerResult(_ next: PreparationKey)
    async throws
{
    let original = PreparationKey(revision: 1, width: 200, locale: "en", theme: "light")
    var content = ContentLifecycle(key: original, demand: .measure)
    let ticketRequest = content.begin(.measurement)
    let ticket = try #require(ticketRequest)
    let work = Task.detached { ticket }
    #expect(content.reset(for: next) == [ticket])
    let replacementRequest = content.begin(.measurement)
    let replacement = try #require(replacementRequest)
    let oldResult = await work.value

    #expect(oldResult.key == original)
    #expect(content.complete(oldResult, with: .ready) == false)
    #expect(content.key == next)
    #expect(content.readiness.measurement == .running)
    #expect(content.complete(replacement, with: .ready) == true)
}

@Test
func cancellingOneClientDoesNotInvalidateAnotherClientWithTheSameResourceKey() throws {
    var first = ContentLifecycle(key: "shared-url", demand: .preload)
    var second = ContentLifecycle(key: "shared-url", demand: .preload)
    let firstTicketRequest = first.begin(.data)
    let firstTicket = try #require(firstTicketRequest)
    let secondTicketRequest = second.begin(.data)
    let secondTicket = try #require(secondTicketRequest)

    #expect(firstTicket != secondTicket)
    #expect(second.complete(firstTicket, with: .ready) == false)
    #expect(first.updateDemand([])?.cancelled == [firstTicket])
    #expect(second.isCurrent(secondTicket))
    #expect(second.complete(secondTicket, with: .ready) == true)
    #expect(first.complete(firstTicket, with: .ready) == false)
    #expect(first.readiness.data == .cancelled)
    #expect(second.readiness.data == .ready)
}
