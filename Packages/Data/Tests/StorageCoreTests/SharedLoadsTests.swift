import Foundation
import Testing
import os

@testable import StorageCore

/// A load that waits until the test lets it go, counting starts and cancellations.
private actor Gate {
    private(set) var started = 0
    private(set) var cancelled = 0
    private var isOpen = false

    func open() { isOpen = true }

    func pass(_ value: Int) async throws -> Int {
        started += 1
        while !isOpen {
            if Task.isCancelled {
                cancelled += 1
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return value
    }
}

/// Keeps the wants of the callers of one load, in the order they came.
private final class Wants: LoadDemand {
    private let state = OSAllocatedUnfairLock(initialState: [(caller: UInt64, want: String)]())

    var current: [String] { state.withLock { $0.map(\.want) } }

    func add(_ want: String, for caller: UInt64) {
        state.withLock { $0.append((caller, want)) }
    }

    func remove(_ caller: UInt64) {
        state.withLock { $0.removeAll { $0.caller == caller } }
    }
}

/// The demands the loads were given, so a test can read one after its load started.
private actor Demands {
    private(set) var all: [Wants] = []

    func keep(_ demand: Wants) { all.append(demand) }
}

private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<2000 where !(await condition()) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Test
func aLoadKnowsWhatItsCallersWantWhileTheyWait() async throws {
    let loads = SharedLoads<String, Int, Wants>()
    let gate = Gate()
    let demands = Demands()
    func call(_ want: String) -> Task<Int, any Error> {
        Task {
            try await loads.value(for: "k", want: want) { demand in
                await demands.keep(demand)
                return try await gate.pass(1)
            }
        }
    }

    let first = call("first")
    await waitUntil { await loads.waiterCount(for: "k") == 1 }
    let second = call("second")
    await waitUntil { await loads.waiterCount(for: "k") == 2 }
    await waitUntil { await demands.all.count == 1 }
    let demand = try #require(await demands.all.first)
    #expect(demand.current == ["first", "second"])

    second.cancel()
    await waitUntil { await loads.waiterCount(for: "k") == 1 }
    #expect(demand.current == ["first"])

    await gate.open()
    #expect(try await first.value == 1)
    #expect(demand.current.isEmpty, "the callers leave the demand when the load ends")
    #expect(await demands.all.count == 1, "one load for both")
}

@Test
func aCancelledCallerReturnsAtOnceAndTheLoadGoesOnForTheOthers() async throws {
    let loads = SharedLoads<String, Int, EqualDemand>()
    let gate = Gate()
    let staying = Task { try await loads.value(for: "k") { try await gate.pass(7) } }
    let leaving = Task { try await loads.value(for: "k") { try await gate.pass(8) } }
    await waitUntil { await loads.waiterCount(for: "k") == 2 }

    leaving.cancel()
    await #expect(throws: CancellationError.self) { try await leaving.value }
    #expect(await gate.cancelled == 0)

    await gate.open()
    #expect(try await staying.value == 7)
    #expect(await gate.started == 1)
}

@Test
func cancellingAKeyReleasesItsCallersAndTheNextCallStartsAnew() async throws {
    let loads = SharedLoads<String, Int, EqualDemand>()
    let gate = Gate()
    let caller = Task { try await loads.value(for: "k") { try await gate.pass(1) } }
    await waitUntil { await loads.waiterCount(for: "k") == 1 }

    await loads.cancel("k")
    await #expect(throws: CancellationError.self) { try await caller.value }
    await waitUntil { await gate.cancelled == 1 }
    #expect(await gate.cancelled == 1)
    #expect(await loads.waiterCount(for: "k") == 0)

    await gate.open()
    #expect(try await loads.value(for: "k") { try await gate.pass(2) } == 2)
    #expect(await gate.started == 2)

    // A finished load is forgotten too: the next caller starts another.
    #expect(try await loads.value(for: "k") { try await gate.pass(3) } == 3)
}

@Test
func cancellingEverythingReleasesTheCallersOfEveryKey() async throws {
    let loads = SharedLoads<String, Int, EqualDemand>()
    let gate = Gate()
    let one = Task { try await loads.value(for: "a") { try await gate.pass(1) } }
    let two = Task { try await loads.value(for: "b") { try await gate.pass(2) } }
    await waitUntil { await loads.waiterCount(for: "a") == 1 }
    await waitUntil { await loads.waiterCount(for: "b") == 1 }

    await loads.cancelAll()
    await #expect(throws: CancellationError.self) { try await one.value }
    await #expect(throws: CancellationError.self) { try await two.value }
}
