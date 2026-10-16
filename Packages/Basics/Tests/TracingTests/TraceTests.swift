import Foundation
import Testing
import os

@testable import Tracing

/// What one test saw, among the records of tests running beside it: the test marks its own
/// with a detail that only it uses.
private final class Collector: Sendable {
    private let seen = OSAllocatedUnfairLock<[Trace.Record]>(initialState: [])
    private let marker: String

    init(marker: String) { self.marker = marker }

    func add(_ record: Trace.Record) {
        guard record.detail.hasPrefix(marker) else { return }
        seen.withLock { $0.append(record) }
    }

    var records: [Trace.Record] { seen.withLock { $0 } }
}

private struct Failure: Error {}

@Suite struct TraceTests {
    @Test func aStretchOfWorkIsToldAtItsBeginningAndItsEnd() {
        let collector = Collector(marker: "order-")
        let observation = Trace.observe { collector.add($0) }
        defer { observation.cancel() }

        let interval = Trace.begin(.draw, "order-1")
        Trace.event(.draw, "order-2")
        Trace.end(interval)

        #expect(
            collector.records == [
                Trace.Record(name: .draw, phase: .begin, detail: "order-1"),
                Trace.Record(name: .draw, phase: .event, detail: "order-2"),
                Trace.Record(name: .draw, phase: .end, detail: "order-1"),
            ]
        )
    }

    @Test func measureReturnsTheResultAndEndsTheStretchWhenTheBodyThrows() {
        let collector = Collector(marker: "measure-")
        let observation = Trace.observe { collector.add($0) }
        defer { observation.cancel() }

        let value = Trace.measure(.decode, "measure-ok") { 7 }
        #expect(value == 7)
        #expect(throws: Failure.self) {
            try Trace.measure(.decode, "measure-throws") { throw Failure() }
        }

        #expect(
            collector.records.map { "\($0.detail) \($0.phase)" } == [
                "measure-ok begin", "measure-ok end",
                "measure-throws begin", "measure-throws end",
            ]
        )
    }

    @Test func aCancelledObserverIsToldNothingMore() {
        let collector = Collector(marker: "cancelled-")
        let observation = Trace.observe { collector.add($0) }

        Trace.event(.layoutApply, "cancelled-before")
        observation.cancel()
        Trace.event(.layoutApply, "cancelled-after")

        #expect(collector.records.map(\.detail) == ["cancelled-before"])
    }

    @Test func everyObserverIsToldOfEveryRecord() {
        let first = Collector(marker: "both-")
        let second = Collector(marker: "both-")
        let one = Trace.observe { first.add($0) }
        let two = Trace.observe { second.add($0) }
        defer {
            one.cancel()
            two.cancel()
        }

        Trace.event(.pageLoad, "both-1")

        #expect(first.records.count == 1)
        #expect(second.records.count == 1)
    }

    @Test func theDetailIsBuiltForAnObserver() {
        let collector = Collector(marker: "built-")
        let observation = Trace.observe { collector.add($0) }
        defer { observation.cancel() }

        Trace.event(.draw, "built-" + String(repeating: "x", count: 3))

        #expect(collector.records.map(\.detail) == ["built-xxx"])
    }

    @Test func everyNameHasItsOwnText() {
        let names = Trace.Name.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }
}
