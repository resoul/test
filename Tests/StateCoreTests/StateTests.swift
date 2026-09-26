import Testing

@testable import StateCore

// Every test flushes explicitly: observers run at a flush, and the tests are synchronous, so
// nothing else can flush in between.

@MainActor
private final class Counter {
    var count = 0
}

@Test @MainActor
func readingAndWritingAreSynchronous() {
    let name = State("Ann")
    name.value = "Bob"

    #expect(name.value == "Bob")
}

@Test @MainActor
func writingAnEqualValueChangesNothing() {
    let count = State(1)
    let before = count.version
    count.value = 1

    #expect(count.version == before)
}

@Test @MainActor
func manyWritesInOneStretchReportOnce() {
    let count = State(0)
    let reports = Counter()
    let observer = Observer { reports.count += 1 }
    _ = observer.track { count.value }

    count.value = 1
    count.value = 2
    count.value = 3
    StateUpdates.flush()

    #expect(reports.count == 1)
}

@Test @MainActor
func onlyWhatWasReadIsWatched() {
    let read = State(0)
    let other = State(0)
    let reports = Counter()
    let observer = Observer { reports.count += 1 }
    _ = observer.track { read.value }

    other.value = 1
    StateUpdates.flush()

    #expect(reports.count == 0)
}

@Test @MainActor
func aBranchNoLongerTakenIsNoLongerWatched() {
    let showsDetails = State(true)
    let details = State("a")
    let reports = Counter()
    let observer = Observer { reports.count += 1 }
    let body = { showsDetails.value ? details.value : "" }
    _ = observer.track(body)

    showsDetails.value = false
    StateUpdates.flush()
    _ = observer.track(body)
    details.value = "b"
    StateUpdates.flush()

    #expect(reports.count == 1)
}

@Test @MainActor
func aChangeUndoneBeforeTheFlushIsNotReported() {
    let count = State(0)
    let doubled = Computed { count.value * 2 }
    let reports = Counter()
    let observer = Observer { reports.count += 1 }
    _ = observer.track { doubled.value }

    count.value = 1
    count.value = 0
    StateUpdates.flush()

    #expect(reports.count == 0)
}

@Test @MainActor
func computedIsLazyAndCached() {
    let count = State(1)
    let computations = Counter()
    let doubled = Computed {
        computations.count += 1
        return count.value * 2
    }

    #expect(computations.count == 0)
    #expect(doubled.value == 2)
    #expect(doubled.value == 2)
    #expect(computations.count == 1)

    count.value = 5

    #expect(doubled.value == 10)
    #expect(computations.count == 2)
}

@Test @MainActor
func anEqualComputedResultStopsTheUpdate() {
    let count = State(1)
    let isPositive = Computed { count.value > 0 }
    let reports = Counter()
    let observer = Observer { reports.count += 1 }
    _ = observer.track { isPositive.value }

    count.value = 2
    StateUpdates.flush()

    #expect(reports.count == 0)
}

@Test @MainActor
func aDiamondIsSeenConsistentAndReportedOnce() {
    let first = State("Ann")
    let greeting = Computed { "Hello, \(first.value)" }
    let initial = Computed { String(first.value.prefix(1)) }
    var seen: [String] = []
    let effect = Effect { seen.append("\(greeting.value) (\(initial.value))") }

    first.value = "Bob"
    StateUpdates.flush()

    #expect(seen == ["Hello, Ann (A)", "Hello, Bob (B)"])
    effect.cancel()
}

@Test @MainActor
func anEffectRunsAtOnceAndAfterEachChange() {
    let name = State("Ann")
    var shown: [String] = []
    let effect = Effect { shown.append(name.value) }

    name.value = "Bob"
    StateUpdates.flush()
    name.value = "Cid"
    StateUpdates.flush()

    #expect(shown == ["Ann", "Bob", "Cid"])
    effect.cancel()
}

@Test @MainActor
func cancelledOrReleasedObserversStopReporting() {
    let count = State(0)
    let reports = Counter()
    let cancelled = Observer { reports.count += 1 }
    _ = cancelled.track { count.value }
    cancelled.cancel()
    var released: Observer? = Observer { reports.count += 1 }
    _ = released?.track { count.value }
    released = nil

    count.value = 1
    StateUpdates.flush()

    #expect(reports.count == 0)
}

@Test @MainActor
func untrackedReadsAreNotDependencies() {
    let watched = State(0)
    let looked = State(0)
    let reports = Counter()
    let observer = Observer { reports.count += 1 }
    _ = observer.track { watched.value + untracked { looked.value } }

    looked.value = 1
    StateUpdates.flush()

    #expect(reports.count == 0)
}

@Test @MainActor
func observersRunInTheOrderTheyWereCreated() {
    let count = State(0)
    var order: [String] = []
    let parent = Effect {
        _ = count.value; order.append("parent")
    }
    let child = Effect {
        _ = count.value; order.append("child")
    }
    order.removeAll()

    count.value = 1
    StateUpdates.flush()

    #expect(order == ["parent", "child"])
    parent.cancel()
    child.cancel()
}

@Test @MainActor
func aFlushOfObserversThatFeedEachOtherEnds() {
    let count = State(0)
    let before = StateUpdates.limitReached
    let effect = Effect { count.value = count.value + 1 }

    StateUpdates.flush()

    #expect(StateUpdates.limitReached == before + 1)
    #expect(!StateUpdates.hasPendingUpdates)
    effect.cancel()
}

@Test @MainActor
func withoutAnExplicitFlushUpdatesArriveOnTheMainActorSoon() async {
    let name = State("Ann")
    var shown: [String] = []
    let effect = Effect { shown.append(name.value) }

    name.value = "Bob"
    for _ in 0..<10 where shown.count < 2 {
        await Task.yield()
    }

    #expect(shown == ["Ann", "Bob"])
    effect.cancel()
}
