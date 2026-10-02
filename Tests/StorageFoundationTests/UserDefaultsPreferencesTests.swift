import Foundation
import StorageCore
import StorageFoundation
import Testing

private let flag = PreferenceKey("flag", default: false)
private let count = PreferenceKey("count", default: 0)
private let ratio = PreferenceKey("ratio", default: 0.0)
private let title = PreferenceKey("title", default: "")
private let blob = PreferenceKey("blob", default: Data())
private let moment = PreferenceKey("moment", default: Date(timeIntervalSince1970: 0))

/// A domain name no other test shares, removed again by `cleanUp`.
private func makeSuiteName() -> String { "StorageFoundationTests.\(UUID().uuidString)" }

private func cleanUp(_ suiteName: String) {
    UserDefaults().removePersistentDomain(forName: suiteName)
}

@Test
func everyPlainKindRoundTripsThroughUserDefaults() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let preferences = Preferences.userDefaults(suiteName: suite)
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    try await preferences.set(true, for: flag)
    try await preferences.set(7, for: count)
    try await preferences.set(2.0, for: ratio)
    try await preferences.set("hello", for: title)
    try await preferences.set(Data([1, 2, 3]), for: blob)
    try await preferences.set(date, for: moment)

    #expect(try await preferences.value(for: flag) == true)
    #expect(try await preferences.value(for: count) == 7)
    #expect(try await preferences.value(for: ratio) == 2.0)
    #expect(try await preferences.value(for: title) == "hello")
    #expect(try await preferences.value(for: blob) == Data([1, 2, 3]))
    #expect(try await preferences.value(for: moment) == date)
}

@Test
func aBooleanAndAnIntegerAreNotMistakenForEachOther() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let preferences = Preferences.userDefaults(suiteName: suite)
    let defaults = try #require(UserDefaults(suiteName: suite))

    try await preferences.set(true, for: flag)
    try await preferences.set(1, for: count)

    #expect(defaults.object(forKey: "flag") is Bool)
    await #expect(throws: PreferenceError.self) {
        try await preferences.value(for: PreferenceKey("flag", default: 0))
    }
    await #expect(throws: PreferenceError.self) {
        try await preferences.value(for: PreferenceKey("count", default: false))
    }
}

@Test
func aValueWrittenByOtherCodeIsReadAndAnArrayIsReportedAsDamaged() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set("written elsewhere", forKey: "title")
    defaults.set([1, 2], forKey: "count")
    let preferences = Preferences.userDefaults(suiteName: suite)

    #expect(try await preferences.value(for: title) == "written elsewhere")
    await #expect(throws: PreferenceError.self) {
        try await preferences.value(for: count)
    }
}

@Test
func suitesAndNamespacesAreIsolated() async throws {
    let first = makeSuiteName()
    let second = makeSuiteName()
    defer {
        cleanUp(first)
        cleanUp(second)
    }
    let inFirst = Preferences.userDefaults(suiteName: first, namespace: "a")
    let inSecond = Preferences.userDefaults(suiteName: second, namespace: "a")
    let otherNamespace = Preferences.userDefaults(suiteName: first, namespace: "b")

    try await inFirst.set("one", for: title)

    #expect(try await inFirst.value(for: title) == "one")
    #expect(try await inSecond.value(for: title) == "")
    #expect(try await otherNamespace.value(for: title) == "")
}

@Test
func removingAKeyDeletesItFromUserDefaultsAndRestoresTheDefault() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let preferences = Preferences.userDefaults(suiteName: suite)

    try await preferences.set(9, for: count)
    await preferences.remove(count)

    #expect(try await preferences.value(for: count) == 0)
    let defaults = try #require(UserDefaults(suiteName: suite))
    #expect(defaults.object(forKey: "count") == nil)
}

@Test
func observationSeesOwnWritesWithoutDuplicates() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let preferences = Preferences.userDefaults(suiteName: suite)
    let stream = await preferences.values(for: count)
    var iterator = stream.makeAsyncIterator()
    guard case .success(0)? = await iterator.next() else {
        Issue.record("The first element was not the default")
        return
    }

    try await preferences.set(1, for: count)
    guard case .success(1)? = await iterator.next() else {
        Issue.record("The write was not reported")
        return
    }

    // The change notification that follows our own write must not report `1` a second time.
    try await preferences.set(2, for: count)
    guard case .success(2)? = await iterator.next() else {
        Issue.record("A duplicate of an earlier value was reported")
        return
    }
}

@Test
func observationSeesAChangeMadeByAnotherObjectOfTheSameDomain() async throws {
    let suite = makeSuiteName()
    defer { cleanUp(suite) }
    let preferences = Preferences.userDefaults(suiteName: suite)
    let stream = await preferences.values(for: title)
    let consumer = Task { () -> String? in
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        if case .success(let value)? = await iterator.next() { return value }
        return nil
    }
    try await Task.sleep(for: .milliseconds(50))

    let outsider = try #require(UserDefaults(suiteName: suite))
    outsider.set("from outside", forKey: "title")

    let received = await withTaskGroup(of: String?.self) { group in
        group.addTask { await consumer.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(3))
            consumer.cancel()
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    #expect(received == "from outside")
}
