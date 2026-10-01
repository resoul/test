import Foundation
import Testing

import StorageCore

@testable import StorageFoundation

/// A defaults domain that lives for one test and is removed after it.
private struct Suite: Sendable {
    let name = "StorageFoundationTests." + UUID().uuidString

    func defaults() -> UserDefaults { UserDefaults(suiteName: name)! }

    func remove() { UserDefaults().removePersistentDomain(forName: name) }
}

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

@Suite struct UserDefaultsPreferencesTests {
    @Test func everyTypeRoundTripsAndKeepsItsKindInTheDomain() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let store = UserDefaultsPreferences(defaults: suite.defaults())
        let date = Date(timeIntervalSince1970: 1_000)
        try await store.set(true, for: PreferenceKey("bool", default: false))
        try await store.set(1, for: PreferenceKey("one", default: 0))
        try await store.set(3.0, for: PreferenceKey("whole", default: 0.5))
        try await store.set("s", for: PreferenceKey("string", default: ""))
        try await store.set(Data([9]), for: PreferenceKey("data", default: Data()))
        try await store.set(date, for: PreferenceKey("date", default: .distantPast))

        // A Boolean and the number 1 are different things, and a stored 3.0 is still a double.
        #expect(await store.rawValue(forName: "bool") == .bool(true))
        #expect(await store.rawValue(forName: "one") == .int(1))
        #expect(await store.rawValue(forName: "whole") == .double(3.0))
        #expect(await store.rawValue(forName: "string") == .string("s"))
        #expect(await store.rawValue(forName: "data") == .data(Data([9])))
        #expect(await store.rawValue(forName: "date") == .date(date))

        // Other code sees plain property-list values.
        let defaults = suite.defaults()
        #expect(defaults.bool(forKey: "bool") && defaults.integer(forKey: "one") == 1)
        #expect(defaults.string(forKey: "string") == "s")
    }

    @Test func absentGivesTheDefaultAndTheWrongTypeIsAnError() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let store = UserDefaultsPreferences(defaults: suite.defaults())
        let key = PreferenceKey("n", default: 4)
        #expect(try await store.value(for: key) == 4)
        suite.defaults().set("text", forKey: "n")
        await #expect(throws: PreferenceError.self) { try await store.value(for: key) }
        await store.remove(key)
        #expect(try await store.value(for: key) == 4)
    }

    @Test func aTypeTheStoreDoesNotModelIsAnError() async throws {
        let suite = Suite()
        defer { suite.remove() }
        suite.defaults().set([1, 2], forKey: "n")
        let store = UserDefaultsPreferences(defaults: suite.defaults())
        await #expect(throws: PreferenceError.self) {
            try await store.value(for: PreferenceKey("n", default: 0))
        }
    }

    @Test func namespacesKeepStoresOfOneDomainApart() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let first = UserDefaultsPreferences(defaults: suite.defaults(), namespace: "first")
        let second = UserDefaultsPreferences(defaults: suite.defaults(), namespace: "second")
        let key = PreferenceKey("n", default: 0)
        try await first.set(1, for: key)
        try await second.set(2, for: key)
        #expect(try await first.value(for: key) == 1)
        #expect(try await second.value(for: key) == 2)
        #expect(suite.defaults().integer(forKey: "first.n") == 1)
    }

    @Test func separateSuitesDoNotShareValues() async throws {
        let one = Suite()
        let two = Suite()
        defer { one.remove(); two.remove() }
        let key = PreferenceKey("n", default: 0)
        try await UserDefaultsPreferences(defaults: one.defaults()).set(1, for: key)
        #expect(try await UserDefaultsPreferences(defaults: two.defaults()).value(for: key) == 0)
    }

    @Test func aStoreReadsWhatAnotherInstanceWrote() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let key = PreferenceKey("n", default: 0)
        try await UserDefaultsPreferences(defaults: suite.defaults()).set(8, for: key)
        #expect(try await UserDefaultsPreferences(defaults: suite.defaults()).value(for: key) == 8)
    }

    @Test func observingGivesTheCurrentValueThenOwnWritesWithoutRepeats() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let store = UserDefaultsPreferences(defaults: suite.defaults())
        let key = PreferenceKey("n", default: 1)
        let recorder = await Recorder(await store.values(for: key))
        _ = await recorder.values(atLeast: 1)
        try await store.set(2, for: key)
        _ = await recorder.values(atLeast: 2)
        try await store.set(2, for: key)
        try? await Task.sleep(for: .milliseconds(100))
        await store.remove(key)
        #expect(await recorder.values(atLeast: 3) == [1, 2, 1])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.values == [1, 2, 1])
        await recorder.stop()
    }

    @Test func observingSeesAChangeMadeByOtherCodeAndIgnoresOtherKeys() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let store = UserDefaultsPreferences(defaults: suite.defaults())
        let key = PreferenceKey("n", default: 1)
        let recorder = await Recorder(await store.values(for: key))
        _ = await recorder.items(atLeast: 1)
        // Written through another `UserDefaults` object of the same domain.
        suite.defaults().set(true, forKey: "unrelated")
        try? await Task.sleep(for: .milliseconds(100))
        suite.defaults().set(5, forKey: "n")
        #expect(await recorder.values(atLeast: 2) == [1, 5])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.values == [1, 5])
        await recorder.stop()
    }

    @Test func cancellingTheConsumerRemovesTheObserver() async throws {
        let suite = Suite()
        defer { suite.remove() }
        let store = UserDefaultsPreferences(defaults: suite.defaults())
        let recorder = await Recorder(await store.values(for: PreferenceKey("n", default: 0)))
        _ = await recorder.items(atLeast: 1)
        #expect(await store.observerCount == 1)
        await recorder.stop()
        for _ in 0..<200 where await store.observerCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.observerCount == 0)
    }
}
