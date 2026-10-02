import Foundation
import StorageCore
import Testing

private enum Sort: String, Sendable {
    case name, date
}

private struct Layout: Codable, Sendable, Equatable {
    var columns: Int
}

private let showsCompleted = PreferenceKey("showsCompleted", default: true)
private let sort = PreferenceKey("sort", default: Sort.name)

private func success<Value: Sendable>(_ result: Result<Value, PreferenceError>?) -> Value? {
    if case .success(let value)? = result { return value }
    return nil
}

@Test
func readingAnUnsetKeyGivesTheDefault() async throws {
    let preferences = Preferences.inMemory()

    #expect(try await preferences.value(for: showsCompleted) == true)
    #expect(try await preferences.value(for: sort) == .name)
}

@Test
func aWrittenValueIsReadBackAndRemovingRestoresTheDefault() async throws {
    let preferences = Preferences.inMemory()

    try await preferences.set(false, for: showsCompleted)
    try await preferences.set(.date, for: sort)
    #expect(try await preferences.value(for: showsCompleted) == false)
    #expect(try await preferences.value(for: sort) == .date)

    await preferences.remove(showsCompleted)
    #expect(try await preferences.value(for: showsCompleted) == true)
}

@Test
func aStoredValueOfAnotherTypeIsAnErrorNotTheDefault() async throws {
    let preferences = Preferences(
        backend: InMemoryPreferenceBackend(["sort": .bool(true)])
    )

    await #expect {
        try await preferences.value(for: sort)
    } throws: { error in
        guard case PreferenceError.decodingFailed(let key, _) = error else { return false }
        return key == "sort"
    }

    await preferences.remove(sort)
    #expect(try await preferences.value(for: sort) == .name)
}

@Test
func aRawValueNoCaseHasIsNotReadAsTheDefault() async throws {
    let preferences = Preferences(
        backend: InMemoryPreferenceBackend(["sort": .string("size")])
    )

    await #expect(throws: PreferenceError.self) {
        try await preferences.value(for: sort)
    }
}

@Test
func namespacesKeepSameNamedKeysApart() async throws {
    let backend = InMemoryPreferenceBackend()
    let list = Preferences(backend: backend, namespace: "list")
    let other = Preferences(backend: InMemoryPreferenceBackend(), namespace: "grid")

    try await list.set(false, for: showsCompleted)

    #expect(try await list.value(for: showsCompleted) == false)
    #expect(try await other.value(for: showsCompleted) == true)
}

@Test
func aNamespaceIsPartOfTheStoredName() async throws {
    let preferences = Preferences(
        backend: InMemoryPreferenceBackend(["list.showsCompleted": .bool(false)]),
        namespace: "list"
    )

    #expect(try await preferences.value(for: showsCompleted) == false)
}

@Test
func aVersionedJSONValueRoundTripsAndRefusesAnotherVersion() async throws {
    let layout = PreferenceKey(
        "layout",
        default: Layout(columns: 1),
        codec: .json(version: 1)
    )
    let preferences = Preferences.inMemory()

    try await preferences.set(Layout(columns: 3), for: layout)
    #expect(try await preferences.value(for: layout) == Layout(columns: 3))

    let newer = PreferenceKey(
        "layout",
        default: Layout(columns: 1),
        codec: .json(version: 2)
    )
    await #expect {
        try await preferences.value(for: newer)
    } throws: { error in
        guard case PreferenceError.decodingFailed(_, let underlying) = error else { return false }
        return underlying as? PreferenceCodecError == .unsupportedVersion(found: 1, expected: 2)
    }
}

@Test
func aFailedEncodingWritesNothing() async throws {
    struct Refusal: Error {}
    let refusing = PreferenceKey(
        "refusing",
        default: 0,
        codec: PreferenceCodec<Int>(encode: { _ in throw Refusal() }, decode: { _ in 0 })
    )
    let preferences = Preferences(backend: InMemoryPreferenceBackend(["refusing": .int(7)]))

    await #expect(throws: PreferenceError.self) {
        try await preferences.set(1, for: refusing)
    }
    #expect(try await preferences.value(for: PreferenceKey("refusing", default: 0)) == 7)
}

@Test
func observationStartsWithTheCurrentValueThenFollowsChanges() async throws {
    let preferences = Preferences.inMemory()
    try await preferences.set(false, for: showsCompleted)
    let stream = await preferences.values(for: showsCompleted)
    var iterator = stream.makeAsyncIterator()

    #expect(success(await iterator.next()) == false)

    try await preferences.set(true, for: showsCompleted)
    #expect(success(await iterator.next()) == true)

    // Removing the key reports the default it falls back to.
    await preferences.remove(showsCompleted)
    #expect(success(await iterator.next()) == true)
}

@Test
func observationDoesNotReportAValueStoredAgainUnchanged() async throws {
    let preferences = Preferences.inMemory()
    let stream = await preferences.values(for: sort)
    var iterator = stream.makeAsyncIterator()
    #expect(success(await iterator.next()) == .name)

    try await preferences.set(.date, for: sort)
    #expect(success(await iterator.next()) == .date)
    try await preferences.set(.date, for: sort)
    try await preferences.set(.name, for: sort)

    // `date` again was not reported, so the next element is the change back to `name`.
    #expect(success(await iterator.next()) == .name)
}

@Test
func aDamagedValueIsReportedAndLaterValuesStillArrive() async throws {
    let preferences = Preferences(backend: InMemoryPreferenceBackend(["sort": .bool(true)]))
    let stream = await preferences.values(for: sort)
    var iterator = stream.makeAsyncIterator()

    guard case .failure? = await iterator.next() else {
        Issue.record("The damaged value was not reported as a failure")
        return
    }

    try await preferences.set(.date, for: sort)
    #expect(success(await iterator.next()) == .date)
}

@Test
func severalObserversOfOneKeyAllSeeTheChange() async throws {
    let preferences = Preferences.inMemory()
    let first = await preferences.values(for: showsCompleted)
    let second = await preferences.values(for: showsCompleted)
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()
    _ = await firstIterator.next()
    _ = await secondIterator.next()

    try await preferences.set(false, for: showsCompleted)

    #expect(success(await firstIterator.next()) == false)
    #expect(success(await secondIterator.next()) == false)
}

@Test
func anObserverOfAnotherKeyIsNotTold() async throws {
    let preferences = Preferences.inMemory()
    let stream = await preferences.values(for: sort)
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    try await preferences.set(false, for: showsCompleted)
    try await preferences.set(.date, for: sort)

    #expect(success(await iterator.next()) == .date)
}

@Test
func aCancelledObserverStopsAndTheStoreKeepsWorking() async throws {
    let preferences = Preferences.inMemory()
    let stream = await preferences.values(for: showsCompleted)
    let consumer = Task {
        var count = 0
        for await _ in stream { count += 1 }
        return count
    }
    try await Task.sleep(for: .milliseconds(20))
    consumer.cancel()
    _ = await consumer.value

    try await preferences.set(false, for: showsCompleted)
    #expect(try await preferences.value(for: showsCompleted) == false)
}
