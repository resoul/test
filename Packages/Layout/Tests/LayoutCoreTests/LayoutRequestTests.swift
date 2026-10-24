import FlexEngine
import Foundation
import Testing

@testable import LayoutCore

@MainActor
private final class RequestBox: LayoutElement {
    var content: LeafContent
    private(set) var reads = 0
    private(set) var frame: LayoutRect?
    private(set) var visible: Bool?

    init(_ content: LeafContent = .size(width: 10, height: 10)) {
        self.content = content
    }

    var layoutContent: LeafContent? {
        reads += 1
        return content
    }

    func applyLayoutFrame(_ frame: LayoutRect) {
        self.frame = frame
    }

    func applyLayoutVisibility(_ isVisible: Bool) {
        visible = isVisible
    }
}

@MainActor
private final class MainActorRequestMeasurer: ContentMeasurer {
    nonisolated var requiresMainThread: Bool { true }
    nonisolated func minContentWidth() -> Double { MainActor.assumeIsolated { 10 } }
    nonisolated func maxContentWidth() -> Double { MainActor.assumeIsolated { 10 } }
    nonisolated func height(forWidth width: Double) -> Double { MainActor.assumeIsolated { 10 } }
}

@Test @MainActor
func aRequestSolvesItsCapturedInputOffMainWithoutReadingOrApplyingElements() async throws {
    let first = RequestBox(.size(width: 20, height: 10))
    let second = RequestBox(.size(width: 30, height: 15))
    let prepared = FlexContainer(.row) {
        first
        second
    }
    .gap(4)
    .padding(3)
    .prepare()
    let size = LayoutSize(width: 120, height: 50)
    let expected = try FlexboxEngine.layout(prepared.input, size: size)
    let request = prepared.request(size: size)
    let reads = first.reads + second.reads
    first.content = .size(width: 90, height: 40)

    let computed = try await Task.detached { try request.solve() }.value

    #expect(first.reads + second.reads == reads)
    #expect(first.frame == nil)
    #expect(second.frame == nil)
    #expect(computed.size == size)
    #expect(computed.result.frames.count == expected.frames.count)
    for entry in expected.frames {
        #expect(computed.result.frame(for: entry.id) == entry.frame)
    }
    let placements = try #require(
        prepared.apply(computed, in: LayoutRect(origin: .zero, size: size))
    )
    #expect(placements.count == 2)
    #expect(first.frame?.size.width == 20)
}

@Test @MainActor
func aNewPreparationRejectsAnOlderComputationEvenWhenElementIDsMatch() async throws {
    let box = RequestBox()
    let spec = FlexContainer { box }
    let previous = spec.prepare()
    let size = LayoutSize(width: 100, height: 50)
    let request = previous.request(size: size)
    let computed = try await Task.detached { try request.solve() }.value
    box.content = .size(width: 40, height: 30)
    let current = spec.prepare()

    #expect(current.ids(of: box) == previous.ids(of: box))
    #expect(current.apply(computed, in: LayoutRect(origin: .zero, size: size)) == nil)
    #expect(box.frame == nil)
    #expect(box.visible == nil)
}

@Test @MainActor
func aComputationRejectsChangedConstraintsButAcceptsANewOriginAndScale() throws {
    let box = RequestBox(.size(width: 10.2, height: 10.2))
    let prepared = FlexContainer { box }.alignItems(.start).prepare()
    let size = LayoutSize(width: 100, height: 50)
    let computed = try prepared.request(size: size).solve()

    #expect(prepared.apply(computed, in: LayoutRect(x: 0, y: 0, width: 200, height: 50)) == nil)
    #expect(box.frame == nil)
    #expect(box.visible == nil)

    let copy = prepared
    let placements = try #require(
        copy.apply(computed, in: LayoutRect(x: 7.2, y: 3.2, width: 100, height: 50), scale: 2)
    )
    #expect(placements.count == 1)
    #expect(box.frame == LayoutRect(x: 7, y: 3, width: 10.5, height: 10.5))
}

@Test @MainActor
func aCheckedApplicationRejectsDuplicateElementsBeforeAnyMutation() throws {
    let box = RequestBox()
    let prepared = FlexContainer(.row) {
        box; box
    }.prepare()
    let size = LayoutSize(width: 100, height: 50)
    let computed = try prepared.request(size: size).solve()

    #expect(prepared.apply(computed, in: LayoutRect(origin: .zero, size: size)) == nil)
    #expect(box.frame == nil)
    #expect(box.visible == nil)
}

@Test @MainActor
func mainOnlyRequestsAreRejectedOffMainAndHaveAnExplicitMainActorPath() async throws {
    let box = RequestBox(.measured(MainActorRequestMeasurer()))
    let prepared = FlexContainer { box }.prepare()
    let size = LayoutSize(width: 100, height: 50)
    let request = prepared.request(size: size)
    #expect(request.requiresMainThread)

    let rejected = await Task.detached {
        do {
            _ = try request.solve()
            return false
        } catch LayoutRequestError.requiresMainThread {
            return true
        } catch {
            return false
        }
    }.value
    #expect(rejected)
    #expect(box.frame == nil)

    let computed = try request.solveOnMainActor()
    #expect(prepared.apply(computed, in: LayoutRect(origin: .zero, size: size)) != nil)
    #expect(box.frame != nil)
}

@Test @MainActor
func cancellingARequestTaskThrowsWithoutApplyingAnything() async {
    let box = RequestBox()
    let prepared = FlexContainer { box }.prepare()
    let request = prepared.request(size: LayoutSize(width: 100, height: 50))

    let cancelled = await Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try request.solve()
            return false
        } catch is LayoutCancelled {
            return true
        } catch {
            return false
        }
    }.value

    #expect(cancelled)
    #expect(box.frame == nil)
    #expect(box.visible == nil)
}

@Test @MainActor
func requestContextsPreserveCancellationStackLimitsAndTracing() throws {
    let box = RequestBox()
    let prepared = FlexContainer { box }.prepare()
    let request = prepared.request(size: LayoutSize(width: 100, height: 50))

    #expect(throws: LayoutCancelled.self) {
        try request.solve(context: LayoutContext(isCancelled: { true }))
    }
    #expect(throws: LayoutStackExhausted.self) {
        try request.solve(context: LayoutContext(stackBudget: 0))
    }
    let context = LayoutContext(trace: LayoutTraceRequest(areas: [.place]))
    let computed = try request.solve(context: context)
    #expect(!computed.result.trace.isEmpty)
    #expect(box.frame == nil)
}

@Test @MainActor
func anEmptyPreparedLayoutAppliesAsAnEmptySuccess() throws {
    let prepared = FlexContainer {}.prepare()
    let size = LayoutSize(width: 100, height: 50)
    let computed = try prepared.request(size: size).solve()

    let placements = try #require(
        prepared.apply(computed, in: LayoutRect(origin: .zero, size: size))
    )
    #expect(placements.isEmpty)
}

@Test @MainActor
func aValueOnlyRequestDoesNotKeepItsLiveElements() throws {
    weak var released: RequestBox?
    let request: LayoutRequest
    do {
        let box = RequestBox()
        released = box
        request = FlexContainer { box }.prepare().request(size: LayoutSize(width: 100, height: 50))
    }

    #expect(released == nil)
    #expect(try !request.solve().result.frames.isEmpty)
}
