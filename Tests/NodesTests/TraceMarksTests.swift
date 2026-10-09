import LayoutCore
import Testing
import Tracing
import os

@testable import Nodes

@MainActor
private final class Box: Node {
    override var layoutContent: LeafContent? { .size(LayoutSize(width: 20, height: 30)) }
}

/// The records of the work one host does, told apart from other tests' by the host's number.
private final class Marks: Sendable {
    private let seen = OSAllocatedUnfairLock<[Trace.Record]>(initialState: [])
    private let observation = OSAllocatedUnfairLock<Trace.Observation?>(initialState: nil)
    private let prefix: String

    init(prefix: String) {
        self.prefix = prefix
        let observation = Trace.observe { [seen, prefix] record in
            guard record.detail.hasPrefix(prefix) else { return }
            seen.withLock { $0.append(record) }
        }
        self.observation.withLock { $0 = observation }
    }

    deinit { observation.withLock { $0?.cancel() } }

    func records(_ name: Trace.Name) -> [Trace.Record] {
        seen.withLock { $0 }.filter { $0.name == name }
    }
}

@Test @MainActor
func aLayoutOnTheMainThreadIsMarkedAndThenItsApplication() {
    let host = NodeHost(root: Box(), size: LayoutSize(width: 100, height: 100))
    let marks = Marks(prefix: "host \(host.number) ")

    host.layoutIfNeeded()

    let solving = marks.records(.layoutOnMain)
    #expect(solving.map(\.phase) == [.begin, .end])
    #expect(marks.records(.layoutApply).map(\.phase) == [.begin, .end])
    #expect(marks.records(.layoutInBackground).isEmpty)
    host.detach()
}

@Test @MainActor
func aLayoutOnTheHostsOwnThreadIsMarkedAsBackground() async {
    let host = NodeHost(root: Box(), size: LayoutSize(width: 100, height: 100))
    host.solvesInBackground = true
    host.layoutIfNeeded()
    await host.layoutFinished()
    let marks = Marks(prefix: "host \(host.number) ")

    // The first pass is solved on the main thread; the next one goes to the thread.
    host.root.setNeedsLayout()
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(marks.records(.layoutInBackground).map(\.phase) == [.begin, .end])
    #expect(marks.records(.layoutApply).map(\.phase) == [.begin, .end])
    host.detach()
}
