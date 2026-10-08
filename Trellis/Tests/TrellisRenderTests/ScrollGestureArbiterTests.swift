import Testing

@testable import TrellisCore
@testable import TrellisRender

@Test @MainActor
func r09_nearestEligibleScrollOwnsTheGestureAndPreventsDoubleConsumption() {
    let inner = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 1),
        axis: .vertical,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 10),
            contentSize: MeasuredSize(width: 1, height: 300),
            viewportSize: MeasuredSize(width: 1, height: 100)
        )
    )
    let outer = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 2),
        axis: .vertical,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 10),
            contentSize: MeasuredSize(width: 1, height: 300),
            viewportSize: MeasuredSize(width: 1, height: 100)
        )
    )
    let arbiter = ScrollGestureArbiter()
    #expect(
        arbiter.owner(for: LayoutPoint(x: 0, y: 20), candidates: [inner, outer], momentum: false)
            == inner.id
    )
    #expect(
        arbiter.owner(for: LayoutPoint(x: 20, y: 0), candidates: [inner, outer], momentum: false)
            == inner.id
    )
}

@Test @MainActor
func r09_boundarySelectsTheNearestAncestorThatCanMoveButMomentumDoesNotHandoff() {
    let innerAtEnd = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 1),
        axis: .vertical,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 200),
            contentSize: MeasuredSize(width: 1, height: 300),
            viewportSize: MeasuredSize(width: 1, height: 100)
        )
    )
    let outer = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 2),
        axis: .vertical,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 10),
            contentSize: MeasuredSize(width: 1, height: 300),
            viewportSize: MeasuredSize(width: 1, height: 100)
        )
    )
    let arbiter = ScrollGestureArbiter()
    #expect(
        arbiter.owner(
            for: LayoutPoint(x: 0, y: 10),
            candidates: [innerAtEnd, outer],
            momentum: false
        ) == outer.id
    )
    #expect(
        arbiter.owner(for: LayoutPoint(x: 0, y: 10), candidates: [innerAtEnd], momentum: true)
            == nil
    )
}

@Test @MainActor
func r09_directionLockAndBoundaryReturnUnconsumedDeltaWithoutDoubleConsumption() {
    let inner = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 1),
        axis: .vertical,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 90),
            contentSize: MeasuredSize(width: 1, height: 200),
            viewportSize: MeasuredSize(width: 1, height: 100)
        )
    )
    let outer = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 2),
        axis: .both,
        state: ScrollState(
            offset: LayoutPoint(x: 20, y: 20),
            contentSize: MeasuredSize(width: 200, height: 200),
            viewportSize: MeasuredSize(width: 100, height: 100)
        )
    )
    let arbiter = ScrollGestureArbiter()

    let first = arbiter.decision(
        for: LayoutPoint(x: 7, y: 25),
        candidates: [inner, outer],
        momentum: false
    )
    #expect(first.owner == inner.id)
    #expect(first.axis == .vertical)
    #expect(first.offeredDelta == LayoutPoint(x: 0, y: 25))
    #expect(first.consumedDelta == LayoutPoint(x: 0, y: 10))
    #expect(first.unconsumedDelta == LayoutPoint(x: 7, y: 15))

    // The next finger delta has horizontal dominance, but the gesture's vertical lock stays.
    // Reaching the edge does not pass its remainder to the outer candidate.
    let innerAtEnd = ScrollGestureArbiter.Candidate(
        id: inner.id,
        axis: inner.axis,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 100),
            contentSize: inner.state.contentSize,
            viewportSize: inner.state.viewportSize
        )
    )
    let second = arbiter.decision(
        for: LayoutPoint(x: 40, y: 20),
        candidates: [innerAtEnd, outer],
        momentum: false
    )
    #expect(second.owner == inner.id)
    #expect(second.axis == .vertical)
    #expect(second.offeredDelta == LayoutPoint(x: 0, y: 20))
    #expect(second.consumedDelta == LayoutPoint(x: 0, y: 0))
    #expect(second.unconsumedDelta == LayoutPoint(x: 40, y: 20))
}

@Test @MainActor
func r09_momentumCannotAcquireAnOwnerAndIneligibleCandidatesAreSkipped() {
    let disabled = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 1),
        axis: .vertical,
        state: ScrollState(
            offset: LayoutPoint(x: 0, y: 10),
            contentSize: MeasuredSize(width: 1, height: 300),
            viewportSize: MeasuredSize(width: 1, height: 100)
        ),
        isEligible: false
    )
    let enabled = ScrollGestureArbiter.Candidate(
        id: NodeID(rawValue: 2),
        axis: .vertical,
        state: disabled.state
    )
    let arbiter = ScrollGestureArbiter()

    #expect(
        arbiter.decision(
            for: LayoutPoint(x: 0, y: 8),
            candidates: [disabled, enabled],
            momentum: true
        ).owner == nil
    )
    #expect(
        arbiter.decision(
            for: LayoutPoint(x: 0, y: 8),
            candidates: [disabled, enabled],
            momentum: false
        ).owner == enabled.id
    )
}
