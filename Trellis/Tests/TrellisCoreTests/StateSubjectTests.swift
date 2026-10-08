import Testing

@testable import TrellisCore

private struct Model: Equatable, Sendable {
    var title: String
    var count: Int
}

@Test @MainActor
func test_stateSubject_sendReplacesCurrentAndSkipsEqualValues() {
    let subject = StateSubject(Model(title: "a", count: 1))
    var received: [Model] = []
    let observation = subject.observe { received.append($0) }

    #expect(subject.send(Model(title: "a", count: 1)) == false)
    #expect(received.isEmpty)
    #expect(subject.send(Model(title: "b", count: 1)))
    #expect(subject.current == Model(title: "b", count: 1))
    #expect(received == [Model(title: "b", count: 1)])

    observation.cancel()
    subject.send(Model(title: "c", count: 2))
    #expect(received.count == 1)
    #expect(subject.observerCount == 0)
    // Cancelling twice is harmless.
    observation.cancel()
}

@Test @MainActor
func test_stateSubject_holdsOnlyTheLatestValueNoQueue() {
    let subject = StateSubject(0)
    // No observer registered: a burst leaves exactly one value behind.
    for value in 1...100 { subject.send(value) }
    #expect(subject.current == 100)

    var seen: [Int] = []
    let observation = subject.observe { seen.append($0) }
    #expect(seen.isEmpty)  // observing does not replay `current`
    subject.send(101)
    #expect(seen == [101])
    observation.cancel()
}
