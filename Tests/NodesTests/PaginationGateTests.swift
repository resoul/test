import Testing

@testable import Nodes

/// A window of 100 over a list of `count` items, 10 long each, whose window starts at `top`.
private func metrics(count: Int, top: Double = 0, window: Double = 100) -> PaginationMetrics {
    let total = Double(count) * 10
    let end = top + window
    let last = count == 0 ? nil : min(count - 1, Int((min(end, total) - 0.001) / 10))
    return PaginationMetrics(
        count: count,
        lastVisible: last,
        remainingLength: max(0, total - end),
        viewportLength: window
    )
}

@Test
func theGateAsksWhenTheEndIsWithinTheTriggerDistanceAndNotBefore() {
    var gate = PaginationGate(policy: PaginationPolicy(trigger: .remainingViewportLengths(2)))

    // 60 items: 600 long; the window ends at 100, so 500 are left — five windows.
    #expect(gate.evaluate(metrics(count: 60), version: 1, reachedEnd: false) == .notNeeded)
    // At 300 of it the window ends at 400: 200 left, exactly two windows.
    #expect(
        gate.evaluate(metrics(count: 60, top: 300), version: 1, reachedEnd: false) == .request
    )
}

@Test
func theTriggerCountsItemsLeftAfterTheLastOneThatShows() {
    var gate = PaginationGate(policy: PaginationPolicy(trigger: .remainingItems(5)))

    // The window shows items 0...9 of 40: 30 left.
    #expect(gate.evaluate(metrics(count: 40), version: 1, reachedEnd: false) == .notNeeded)
    // Items 25...34 show: 5 left.
    #expect(
        gate.evaluate(metrics(count: 40, top: 250), version: 1, reachedEnd: false) == .request
    )
}

@Test
func anEmptyListAsksForItsFirstPage() {
    var byLength = PaginationGate()
    var byItems = PaginationGate(policy: PaginationPolicy(trigger: .remainingItems(3)))

    #expect(byLength.evaluate(metrics(count: 0), version: 1, reachedEnd: false) == .request)
    #expect(byItems.evaluate(metrics(count: 0), version: 1, reachedEnd: false) == .request)
}

@Test
func aPageOnItsWayOrAlreadyAskedForIsNotAskedForAgain() {
    var gate = PaginationGate()
    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false) == .request)
    #expect(gate.isRequestInFlight)

    // While it is on its way, however many layouts there are.
    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false) == .duplicate)
    #expect(gate.evaluate(metrics(count: 10), version: 2, reachedEnd: false) == .duplicate)

    // It ended with more items: the next version asks again.
    gate.complete(count: 30)
    #expect(!gate.isRequestInFlight)
    #expect(gate.evaluate(metrics(count: 30, top: 200), version: 2, reachedEnd: false) == .request)
}

@Test
func theEndStopsEverything() {
    var gate = PaginationGate()

    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: true) == .endReached)
    #expect(!gate.isRequestInFlight)
}

@Test
func aFailedPageIsNotAskedForAgainUntilRetried() {
    var gate = PaginationGate()
    _ = gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false)

    gate.fail()
    #expect(!gate.isRequestInFlight)
    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false) == .awaitingRetry)
    #expect(gate.evaluate(metrics(count: 10), version: 7, reachedEnd: false) == .awaitingRetry)
    gate.userDidScroll()
    #expect(gate.evaluate(metrics(count: 10), version: 8, reachedEnd: false) == .awaitingRetry)

    gate.retry(count: 10, version: 8)
    #expect(gate.isRequestInFlight)
    gate.complete(count: 20)
    #expect(gate.evaluate(metrics(count: 20, top: 100), version: 9, reachedEnd: false) == .request)
}

@Test
func aPageThatAddedNothingStopsTheListUntilItIsScrolled() {
    var gate = PaginationGate()
    _ = gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false)

    gate.complete(count: 10)

    // The same items: nothing new to ask about.
    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false) == .duplicate)
    // Assigned again, still 10: the stall is what says so.
    #expect(gate.evaluate(metrics(count: 10), version: 2, reachedEnd: false) == .noProgress)
    // Scrolling lets it ask again, for the same items too.
    gate.userDidScroll()
    #expect(gate.evaluate(metrics(count: 10), version: 2, reachedEnd: false) == .request)
}

@Test
func itemsThatCameAfterThePageEndedWereProgressAfterAll() {
    var gate = PaginationGate()
    _ = gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false)
    gate.complete(count: 10)
    #expect(gate.evaluate(metrics(count: 10), version: 2, reachedEnd: false) == .noProgress)

    // The page was late, not empty.
    gate.itemsChanged(count: 25)

    #expect(gate.evaluate(metrics(count: 25, top: 100), version: 3, reachedEnd: false) == .request)
}

@Test
func theListStopsAfterTheAutomaticPagesUntilItIsScrolled() {
    var gate = PaginationGate(policy: PaginationPolicy(maximumAutomaticPages: 2))
    var count = 5
    for version in 1...2 {
        #expect(
            gate.evaluate(metrics(count: count), version: version, reachedEnd: false) == .request
        )
        count += 5
        gate.complete(count: count)
    }

    #expect(gate.evaluate(metrics(count: count), version: 3, reachedEnd: false) == .automaticLimit)
    gate.userDidScroll()
    #expect(gate.evaluate(metrics(count: count), version: 3, reachedEnd: false) == .request)
}

@Test
func aCancelledPageMayBeAskedForAgainAndDoesNotCountAgainstTheLimit() {
    var gate = PaginationGate(policy: PaginationPolicy(maximumAutomaticPages: 1))
    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false) == .request)

    gate.cancelInFlight()

    #expect(!gate.isRequestInFlight)
    #expect(gate.evaluate(metrics(count: 10), version: 1, reachedEnd: false) == .request)
}

@Test
func aPolicyAlwaysAllowsAtLeastOneAutomaticPage() {
    #expect(PaginationPolicy(maximumAutomaticPages: 0).maximumAutomaticPages == 1)
    #expect(PaginationPolicy(maximumAutomaticPages: -4).maximumAutomaticPages == 1)
}
