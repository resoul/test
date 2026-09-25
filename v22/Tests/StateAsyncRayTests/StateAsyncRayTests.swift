import AsyncRay
import StateCore
import StateAsyncRay
import Testing

@MainActor
private final class Received<Value> {
    var values: [Value] = []
}

/// Lets main-actor tasks run until `condition` holds, or two seconds pass.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@Test @MainActor
func aBoundStreamWritesIntoTheState() async {
    let state = State(0)
    let subscription = AsyncRay.from([1, 2, 3]).bind(to: state)

    await waitUntil { state.value == 3 }

    #expect(state.value == 3)
    subscription.cancel()
}

@Test @MainActor
func aStateStreamStartsWithTheCurrentValueThenFollowsChanges() async {
    let state = State("Ann")
    let received = Received<String>()
    let subscription = state.asyncRay.sinkOnMain { received.values.append($0) }

    await waitUntil { received.values == ["Ann"] }
    state.value = "Bob"
    await waitUntil { received.values.count == 2 }

    #expect(received.values == ["Ann", "Bob"])
    subscription.cancel()
}

@Test @MainActor
func changesBetweenTwoFlushesArriveAsTheLatestValue() async {
    let state = State(0)
    let received = Received<Int>()
    let subscription = state.asyncRay.sinkOnMain { received.values.append($0) }
    await waitUntil { received.values == [0] }

    state.value = 1
    state.value = 2
    state.value = 3
    await waitUntil { received.values.last == 3 }

    #expect(received.values == [0, 3])
    subscription.cancel()
}

@Test @MainActor
func aCancelledStreamNoLongerWatchesTheState() async {
    let state = State(0)
    let received = Received<Int>()
    let subscription = state.asyncRay.sinkOnMain { received.values.append($0) }
    await waitUntil { received.values == [0] }

    subscription.cancel()
    state.value = 1
    for _ in 0..<20 {
        await Task.yield()
    }

    #expect(received.values == [0])
}

@Test @MainActor
func aStateCanFeedAnotherThroughAsyncRay() async {
    let query = State("")
    let echo = State("")
    let subscription = query.asyncRay.map { $0.uppercased() }.bind(to: echo)

    query.value = "swift"
    await waitUntil { echo.value == "SWIFT" }

    #expect(echo.value == "SWIFT")
    subscription.cancel()
}

/// A transaction that notes the state's value right after the writes it was given.
private struct Recording: StateTransaction {
    let state: State<Int>
    let received: Received<Int>

    @MainActor
    func perform(_ writes: () -> Void) {
        writes()
        received.values.append(state.value)
    }
}

@Test @MainActor
func aStreamBoundWithATransactionWritesEachValueInsideIt() async {
    let state = State(0)
    let received = Received<Int>()
    let transaction = Recording(state: state, received: received)
    let subscription = AsyncRay.from([1, 2]).bind(to: state, animation: transaction)

    await waitUntil { received.values.count == 2 }

    #expect(received.values == [1, 2])
    subscription.cancel()
}
