import Testing

@testable import TrellisCore

// D09/§3.13: checkpoints sit at layoutContainer's entry (every recursive level) and at each
// resolved flex line inside measure's `resolveLines` — not on every child. These tests prove
// both checkpoints actually fire and that cancellation surfaces via `throw`, never as an empty
// or partial result.

@Test
func test_layoutContainer_cancelledContextThrowsAtEntry() {
    let root = LayoutInputSnapshot(identity: flexID(1))
    let cancelled = LayoutContext(cancellationCheck: { true })

    #expect(throws: LayoutCancellationError.cancelled) {
        try FlexboxEngine.layoutContainer(
            input: root,
            frame: LayoutFrame(width: 10, height: 10),
            context: cancelled
        )
    }
}

@Test
func test_measureContainer_cancelledContextThrowsAtFlexLineBoundary() {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(10), height: .points(10))
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [child])
    let cancelled = LayoutContext(cancellationCheck: { true })

    #expect(throws: LayoutCancellationError.cancelled) {
        try FlexboxEngine.measureContainer(input: root, context: cancelled)
    }
}

@Test
func test_measureContainer_leafWithNoFlexLinesNeverChecksCancellation() throws {
    // A leaf's `resolveLines` call gets an empty `items` array and returns `[]` before the
    // per-line checkpoint ever runs — so an always-cancelled context does not prevent
    // measuring a leaf. This is the documented checkpoint granularity, not a bug: a
    // per-child checkpoint is an explicit non-goal until C31 measures an actual need.
    let leaf = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(10), height: .points(10))
    )
    let cancelled = LayoutContext(cancellationCheck: { true })

    let result = try FlexboxEngine.measureContainer(input: leaf, context: cancelled)

    #expect(result.parentSize == MeasuredSize(width: 10, height: 10))
}

@Test
func test_layoutContainer_nonCancelledContextCompletesNormally() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(10), height: .points(10))
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [child])

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 20, height: 20),
        context: .noCancellation
    )

    #expect(result.placement(for: flexID(2)) != nil)
}
