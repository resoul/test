import Testing

@testable import TrellisCore

// R07 (`implementation-plan-6.md` plan 6): pure value-type contract tests for `ScrollState`,
// ported in spirit from Weave's `Tests/WeaveBootstrapTests/ScrollTests.swift` (2 `@Test`,
// `docs/weave-scroll-analysis.md` §6) and adapted to the new contract
// (`docs/validation/r06-scroll-api-sketch.md`) — no `CALayer`/host bridge/adapter involved,
// matching R07's checklist bullet "core state/commands/measurement/clamp/coordinate mapping".

@Test
func test_scrollState_clampsOffsetToContentMinusViewportOnBothAxesIndependently() {
    let state = ScrollState(
        offset: LayoutPoint(x: 900, y: 500),
        contentSize: MeasuredSize(width: 1000, height: 400),
        viewportSize: MeasuredSize(width: 300, height: 200)
    )

    #expect(state.offset == LayoutPoint(x: 700, y: 200))
}

@Test
func test_scrollState_clampsNegativeOffsetToZero() {
    let state = ScrollState(
        offset: LayoutPoint(x: -50, y: -1),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 300, height: 300)
    )

    #expect(state.offset == LayoutPoint(x: 0, y: 0))
}

@Test
func test_scrollState_emptyContentClampsOffsetToZero() {
    let state = ScrollState(
        offset: LayoutPoint(x: 40, y: 40),
        contentSize: MeasuredSize(width: 0, height: 0),
        viewportSize: MeasuredSize(width: 0, height: 0)
    )

    #expect(state.offset == LayoutPoint(x: 0, y: 0))
}

@Test
func test_scrollState_shortContentSmallerThanViewportClampsOffsetToZero() {
    // Content shorter than the viewport (R07 checklist: "пустого/короткого... контента"):
    // `contentSize - viewportSize` is negative on that axis, `clamp` floors the upper bound at
    // zero rather than letting a negative bound invert `min`/`max`.
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 30),
        contentSize: MeasuredSize(width: 300, height: 120),
        viewportSize: MeasuredSize(width: 300, height: 400)
    )

    #expect(state.offset == LayoutPoint(x: 0, y: 0))
}

@Test
func test_scrollState_reclampingAnAlreadyClampedOffsetIsIdempotent() {
    let first = ScrollState(
        offset: LayoutPoint(x: 900, y: 900),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 300, height: 300)
    )
    let reclamped = ScrollState(
        offset: first.offset,
        contentSize: first.contentSize,
        viewportSize: first.viewportSize
    )

    #expect(reclamped.offset == first.offset)
}

@Test
func test_scrollState_viewportAndContentPointConversionRoundTrip() {
    let state = ScrollState(
        offset: LayoutPoint(x: 40, y: 15),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 300, height: 300)
    )
    let contentPoint = LayoutPoint(x: 120, y: 80)

    let viewportPoint = state.viewportPoint(fromContent: contentPoint)
    #expect(viewportPoint == LayoutPoint(x: 80, y: 65))

    let roundTripped = state.contentPoint(fromViewport: viewportPoint)
    #expect(roundTripped == contentPoint)
}

@Test
func test_scrollState_visibleContentFrameIsOffsetAndViewportSizeWithNoChildWalk() {
    let state = ScrollState(
        offset: LayoutPoint(x: 25, y: 50),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 300, height: 400)
    )

    let frame = state.visibleContentFrame
    #expect(frame.origin == LayoutPoint(x: 25, y: 50))
    #expect(frame.width == 300)
    #expect(frame.height == 400)
}

// MARK: - reveal(frame:alignment:)

@Test
func test_scrollState_revealOffset_startAlignmentPlacesFrameOriginAtOffset() {
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    // `width: 200` equals the viewport width, so `.start` leaves x-offset at 0 — these three
    // tests isolate the y-axis math each asserts on; x-axis symmetry is covered separately by
    // `test_scrollState_revealOffsetMathIsAxisNumericAndDirectionAgnostic`.
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 500), width: 200, height: 40)

    let offset = state.revealOffset(for: target, alignment: .start)
    #expect(offset == LayoutPoint(x: 0, y: 500))
}

@Test
func test_scrollState_revealOffset_centerAlignmentCentersFrameInViewport() {
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 500), width: 200, height: 40)

    let offset = state.revealOffset(for: target, alignment: .center)
    // frameCenterY (520) - viewport/2 (100) = 420.
    #expect(offset == LayoutPoint(x: 0, y: 420))
}

@Test
func test_scrollState_revealOffset_endAlignmentAlignsFrameTrailingEdgeToViewport() {
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 500), width: 200, height: 40)

    let offset = state.revealOffset(for: target, alignment: .end)
    // frameEndY (540) - viewportHeight (200) = 340.
    #expect(offset.y == 340)
}

@Test
func test_scrollState_revealOffset_nearestAlignmentIsANoOpWhenAlreadyFullyVisible() {
    // Scenario 6, `r06-scroll-api-sketch.md` §10: reveal on a node already visible in the
    // viewport does not move the offset.
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 100),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 150), width: 0, height: 40)

    let offset = state.revealOffset(for: target, alignment: .nearest)
    #expect(offset == state.offset)
}

@Test
func test_scrollState_revealOffset_nearestAlignmentMovesMinimumDistanceWhenPartiallyBelowViewport()
{
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    // The frame's trailing edge (340) is past the viewport's trailing edge (200).
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 300), width: 0, height: 40)

    let offset = state.revealOffset(for: target, alignment: .nearest)
    #expect(offset.y == 140)
}

@Test
func test_scrollState_revealOffset_nearestAlignmentMovesMinimumDistanceWhenPartiallyAboveViewport()
{
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 300),
        contentSize: MeasuredSize(width: 1000, height: 1000),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    // The frame's leading edge (250) is above the viewport's leading edge (300).
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 250), width: 0, height: 40)

    let offset = state.revealOffset(for: target, alignment: .nearest)
    #expect(offset.y == 250)
}

@Test
func test_scrollState_revealOffset_clampsResultToContentBounds() {
    let state = ScrollState(
        offset: LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize(width: 200, height: 200),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    // A frame beyond content bounds cannot produce an out-of-range offset.
    let target = LayoutFrame(origin: LayoutPoint(x: 0, y: 900), width: 0, height: 40)

    let offset = state.revealOffset(for: target, alignment: .start)
    #expect(offset == LayoutPoint(x: 0, y: 0))
}

@Test
func test_scrollState_revealOffsetMathIsAxisNumericAndDirectionAgnostic() {
    // "incl RTL" (R07 checklist): by the time a frame reaches `ScrollState`, its `origin.x` is
    // already a resolved, physical (post-`DirectionalEdgeInsets.resolved(for:)`) root-absolute
    // coordinate (D17's committed-frame contract) — RTL changes *which* logical edge produced
    // that number upstream (layout), not the reveal formula itself, which is symmetric in x
    // exactly as it is in y. This test demonstrates the symmetry directly: mirroring both the
    // viewport and the target frame around a content width produces the mirrored offset.
    let width = 1000.0
    let ltr = ScrollState(
        offset: LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize(width: width, height: 200),
        viewportSize: MeasuredSize(width: 200, height: 200)
    )
    let rtlMirroredTarget = LayoutFrame(origin: LayoutPoint(x: 700, y: 0), width: 50, height: 0)
    let ltrTarget = LayoutFrame(
        origin: LayoutPoint(x: width - 700 - 50, y: 0),
        width: 50,
        height: 0
    )

    let mirroredOffset = ltr.revealOffset(for: rtlMirroredTarget, alignment: .start)
    let plainOffset = ltr.revealOffset(for: ltrTarget, alignment: .start)
    #expect(mirroredOffset.x == rtlMirroredTarget.origin.x)
    #expect(plainOffset.x == ltrTarget.origin.x)
    #expect(mirroredOffset.x + plainOffset.x == width - 50)
}

// MARK: - ScrollConfiguration defaults (`scroll-configuration.md` §2)

@Test
func test_scrollConfiguration_defaultsMatchSpecification() {
    let configuration = ScrollConfiguration()

    #expect(configuration.axis == .vertical)
    #expect(configuration.userInteractionEnabled == true)
    #expect(configuration.directionalLockEnabled == false)
    #expect(configuration.indicators == .automatic)
    #expect(configuration.contentInsets == DirectionalEdgeInsets())
    #expect(configuration.insetsSafeArea == true)
    #expect(configuration.bounce == .automatic)
    #expect(configuration.keyboardDismissMode == .none)
}

// MARK: - ScrollNode

@MainActor
@Test
func test_scrollNode_defaultsToScrollOverflowAndZeroState() {
    let node = ScrollNode()

    #expect(node.style.visual.overflow == .scroll)
    #expect(node.state == ScrollState())
}

@MainActor
@Test
func test_scrollNode_publishCallsOnScrollStateChangedAndUpdatesState() {
    let node = ScrollNode()
    var received: [ScrollState] = []
    node.onScrollStateChanged = { state in received.append(state) }

    let first = ScrollState(
        offset: LayoutPoint(x: 10, y: 0),
        contentSize: MeasuredSize(width: 500, height: 500),
        viewportSize: MeasuredSize(width: 200, height: 200),
        revision: 1
    )
    node.publish(first)

    #expect(node.state == first)
    #expect(received == [first])
}

// MARK: - ScrollCommand / ScrollCommandOutcome / ScrollCommandToken

@Test
func test_scrollCommandToken_equalityIsByID() {
    #expect(ScrollCommandToken(id: 1) == ScrollCommandToken(id: 1))
    #expect(ScrollCommandToken(id: 1) != ScrollCommandToken(id: 2))
}

@Test
func test_scrollCommandOutcome_completedCarriesTheStateItResolvedWith() {
    let state = ScrollState(revision: 3)
    let outcome = ScrollCommandOutcome.completed(state)

    guard case let .completed(carried) = outcome else {
        Issue.record("expected .completed")
        return
    }
    #expect(carried == state)
}

// Defect #84 / ADR 0026 amendment: the scrollable axis is the flex main axis, so the node's
// direction follows its configured axis.
@MainActor
@Test
func test_scrollNode_defaultDirectionFollowsVerticalAxis() {
    #expect(ScrollNode().style.flexDirection == .column)

    var reversed = LayoutStyle()
    reversed.flexDirection = .rowReverse
    #expect(ScrollNode(style: reversed).style.flexDirection == .columnReverse)
}

@MainActor
@Test
func test_scrollNode_axisChangeRealignsDirectionAndBothLeavesIt() {
    let node = ScrollNode()
    node.configuration.axis = .horizontal
    #expect(node.style.flexDirection == .row)
    #expect(!node.directionMismatchesAxis)

    node.configuration.axis = .both
    #expect(node.style.flexDirection == .row)
    node.configuration.axis = .vertical
    #expect(node.style.flexDirection == .column)
}

@MainActor
@Test
func test_scrollNode_manualMismatchIsKeptButDetected() {
    let node = ScrollNode()
    node.style.flexDirection = .row

    #expect(node.style.flexDirection == .row)
    #expect(node.directionMismatchesAxis)
}

// Defect #86: along its scrollable axis a scroll container is a viewport — a row parent's
// stretch gives it the parent's height, while its child keeps the full content height.
@MainActor
@Test
func test_scrollNode_autoSizedViewportIsBoundedByTheParentNotItsContent() throws {
    let root = Node()
    let scroll = ScrollNode()
    scroll.style.width = 300
    let content = Node()
    content.style.height = 900
    scroll.addSubnode(content)
    root.addSubnode(scroll)
    let input = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(300), height: .exact(250))
    )
    let frame = LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 250)

    _ = root.applyLayoutResult(try FlexboxEngine.layoutContainer(input: input, frame: frame))

    #expect(scroll.calculatedFrame?.height == 250)
    #expect(content.calculatedFrame?.height == 900)
}
