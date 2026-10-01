import Foundation
import Testing

@testable import StorageCore

private enum Sort: String, Sendable { case name, date }
private enum Level: Int, Sendable { case low = 1, high = 2 }

private struct Window: Codable, Sendable, Equatable {
    var width: Int
    var title: String
}

/// Collects what a stream yields, so a test can wait for a number of values without a timeout
/// in the stream itself.
private actor Recorder<Value: Sendable> {
    typealias Item = Result<Value, PreferenceError>

    private(set) var items: [Item] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Item>) async {
        task = Task { [weak self] in
            for await item in stream { await self?.append(item) }
        }
    }

    private func append(_ item: Item) { items.append(item) }

    /// The values received so far; a failure counts as a test failure.
    var values: [Value] { items.compactMap { try? $0.get() } }

    /// Waits until at least `count` items arrived, for at most five seconds.
    func items(atLeast count: Int) async -> [Item] {
        for _ in 0..<500 where items.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return items
    }

    func values(atLeast count: Int) async -> [Value] {
        _ = await items(atLeast: count)
        return values
    }

    func stop() { task?.cancel() }
}

@Suite struct PreferenceKeyTests {
    @Test func absentValueReadsAsTheDefault() async throws {
        let store = MemoryPreferences()
        #expect(try await store.value(for: PreferenceKey("a", default: 7)) == 7)
        #expect(try await store.value(for: PreferenceKey("b", default: "x")) == "x")
    }

    @Test func everyBuiltInTypeRoundTrips() async throws {
        let store = MemoryPreferences()
        let date = Date(timeIntervalSince1970: 1_000)
        try await store.set(true, for: PreferenceKey("bool", default: false))
        try await store.set(3, for: PreferenceKey("int", default: 0))
        try await store.set(2.5, for: PreferenceKey("double", default: 0))
        try await store.set("s", for: PreferenceKey("string", default: ""))
        try await store.set(Data([1]), for: PreferenceKey("data", default: Data()))
        try await store.set(date, for: PreferenceKey("date", default: .distantPast))
        #expect(try await store.value(for: PreferenceKey("bool", default: false)) == true)
        #expect(try await store.value(for: PreferenceKey("int", default: 0)) == 3)
        #expect(try await store.value(for: PreferenceKey("double", default: 0)) == 2.5)
        #expect(try await store.value(for: PreferenceKey("string", default: "")) == "s")
        #expect(try await store.value(for: PreferenceKey("data", default: Data())) == Data([1]))
        #expect(try await store.value(for: PreferenceKey("date", default: .distantPast)) == date)
    }

    @Test func removingReturnsToTheDefault() async throws {
        let store = MemoryPreferences()
        let key = PreferenceKey("n", default: 1)
        try await store.set(5, for: key)
        await store.remove(key)
        #expect(try await store.value(for: key) == 1)
    }

    @Test func aValueOfAnotherTypeIsAnErrorAndNotTheDefault() async throws {
        let store = MemoryPreferences(["n": .string("oops")])
        let key = PreferenceKey("n", default: 1)
        await #expect(throws: PreferenceError.self) { try await store.value(for: key) }
        // Removing the damaged value is the way back.
        await store.remove(key)
        #expect(try await store.value(for: key) == 1)
    }

    @Test func aWholeNumberReadsAsADoubleButNotTheReverse() async throws {
        let store = MemoryPreferences(["n": .int(2), "d": .double(2.5)])
        #expect(try await store.value(for: PreferenceKey("n", default: 0.0)) == 2.0)
        await #expect(throws: PreferenceError.self) {
            try await store.value(for: PreferenceKey("d", default: 0))
        }
    }

    @Test func aValueStoredByOtherCodeAsAnUnmodelledTypeIsAnError() async throws {
        let store = MemoryPreferences(["n": .unsupported("NSArray")])
        let error = await #expect(throws: PreferenceError.self) {
            try await store.value(for: PreferenceKey("n", default: 1))
        }
        #expect(error == .undecodable(key: "n", reason: "stored value has type NSArray"))
    }

    @Test func enumerationsUseTheirRawValueAndRejectUnknownOnes() async throws {
        let store = MemoryPreferences()
        let sort = PreferenceKey<Sort>("sort", default: .name)
        let level = PreferenceKey<Level>("level", default: .low)
        try await store.set(.date, for: sort)
        try await store.set(.high, for: level)
        #expect(await store.rawValue(forName: "sort") == .string("date"))
        #expect(await store.rawValue(forName: "level") == .int(2))
        #expect(try await store.value(for: sort) == .date)

        await store.setRawValue(.string("size"), forName: "sort")
        await store.setRawValue(.int(9), forName: "level")
        await #expect(throws: PreferenceError.self) { try await store.value(for: sort) }
        await #expect(throws: PreferenceError.self) { try await store.value(for: level) }
    }

    @Test func aCodableStructureIsStoredAsJSON() async throws {
        let store = MemoryPreferences()
        let key = PreferenceKey<Window>.json("window", default: Window(width: 1, title: ""))
        try await store.set(Window(width: 640, title: "Main"), for: key)
        #expect(try await store.value(for: key) == Window(width: 640, title: "Main"))

        await store.setRawValue(.data(Data("{}".utf8)), forName: "window")
        await #expect(throws: PreferenceError.self) { try await store.value(for: key) }
    }

    @Test func aConversionThatFailsWritesNothing() async throws {
        struct Refusal: Error {}
        let store = MemoryPreferences()
        let key = PreferenceKey<Int>(
            "n",
            default: 0,
            encode: { _ in throw Refusal() },
            decode: { _ in 0 }
        )
        let error = await #expect(throws: PreferenceError.self) {
            try await store.set(1, for: key)
        }
        guard case .unencodable(let name, _) = error else {
            Issue.record("expected unencodable, got \(String(describing: error))")
            return
        }
        #expect(name == "n")
        #expect(await store.rawValue(forName: "n") == nil)
    }

    @Test func aConversionMayNotProduceTheUnsupportedCase() async throws {
        let store = MemoryPreferences()
        let key = PreferenceKey<Int>(
            "n",
            default: 0,
            encode: { _ in .unsupported("x") },
            decode: { _ in 0 }
        )
        await #expect(throws: PreferenceError.self) { try await store.set(1, for: key) }
        #expect(await store.rawValue(forName: "n") == nil)
    }
}

@Suite struct MemoryPreferencesTests {
    @Test func valuesStartWithTheCurrentOneThenFollowChanges() async throws {
        let store = MemoryPreferences()
        let key = PreferenceKey("n", default: 1)
        let recorder = await Recorder(await store.values(for: key))
        _ = await recorder.values(atLeast: 1)
        try await store.set(2, for: key)
        _ = await recorder.values(atLeast: 2)
        await store.remove(key)
        #expect(await recorder.values(atLeast: 3) == [1, 2, 1])
        await recorder.stop()
    }

    @Test func writingTheValueThatIsAlreadyThereProducesNothing() async throws {
        let store = MemoryPreferences()
        let key = PreferenceKey("n", default: 1)
        let recorder = await Recorder(await store.values(for: key))
        _ = await recorder.values(atLeast: 1)
        try await store.set(1, for: key)  // same as the default, but now stored
        try await store.set(1, for: key)
        try? await Task.sleep(for: .milliseconds(100))
        try await store.set(2, for: key)
        #expect(await recorder.values(atLeast: 2) == [1, 2])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.values == [1, 2])
        await recorder.stop()
    }

    @Test func aDamagedValueArrivesAsAFailureAndTheStreamGoesOn() async throws {
        let store = MemoryPreferences()
        let key = PreferenceKey("n", default: 1)
        let recorder = await Recorder(await store.values(for: key))
        _ = await recorder.items(atLeast: 1)
        await store.setRawValue(.string("bad"), forName: "n")
        _ = await recorder.items(atLeast: 2)
        await store.remove(key)
        let items = await recorder.items(atLeast: 3)
        guard items.count == 3 else {
            Issue.record("expected 3 items, got \(items)")
            return
        }
        #expect(items[0] == .success(1))
        if case .failure = items[1] {} else { Issue.record("expected a failure, got \(items[1])") }
        #expect(items[2] == .success(1))
        await recorder.stop()
    }

    @Test func changesToOtherNamesAreNotDelivered() async throws {
        let store = MemoryPreferences()
        let recorder = await Recorder(await store.values(for: PreferenceKey("a", default: 0)))
        _ = await recorder.items(atLeast: 1)
        try await store.set(5, for: PreferenceKey("b", default: 0))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.items.count == 1)
        try await store.set(1, for: PreferenceKey("a", default: 0))
        #expect(await recorder.items(atLeast: 2).count == 2)
        await recorder.stop()
    }

    @Test func cancellingTheConsumerStopsTheWatching() async throws {
        let store = MemoryPreferences()
        let recorder = await Recorder(await store.values(for: PreferenceKey("a", default: 0)))
        _ = await recorder.items(atLeast: 1)
        #expect(await store.observerCount == 1)
        await recorder.stop()
        for _ in 0..<200 where await store.observerCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.observerCount == 0)
    }
}
