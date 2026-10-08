import Testing

@testable import TrellisCore

// Ported from Weave's LayoutResultTests.swift — placement-algorithm tests exercising
// `FlexboxEngine.layoutContainer`, as distinct from `Tests/TrellisCoreTests/Layout/
// LayoutResultTests.swift`'s C11 tests of the `LayoutResult` value type itself.

@Test
func test_layoutContainer_placesRowChildrenAndKeepsRevisions() throws {
    let childStyle = flexStyle(width: .points(30), height: .points(10))
    let child = LayoutInputSnapshot(identity: flexID(2), style: childStyle)
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .row, gap: 10),
        children: [child, LayoutInputSnapshot(identity: flexID(3), style: childStyle)],
        environmentRevision: 4,
        contentRevision: 5
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 20)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.x == 0)
    #expect(result.placement(for: flexID(3))?.frame.origin.x == 40)
    #expect(result.environmentRevision == 4)
    #expect(result.contentRevision == 5)
}

@Test
func test_layoutContainer_mirrorsRowForRTLAndRoundsAtScale() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(10), height: .points(5))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .row),
        children: [child],
        direction: .rightToLeft
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 20, height: 10),
        roundingPolicy: PixelRoundingPolicy(scale: 2)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.x == 10)
}

@Test
func test_layoutContainer_snapsFramesAtSupportedScalesWithoutNegativeSizes() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(3.2), height: .points(2.7))
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [child])

    for scale in [1.0, 2.0, 3.0] {
        let result = try FlexboxEngine.layoutContainer(
            input: root,
            frame: LayoutFrame(width: 10, height: 10),
            roundingPolicy: PixelRoundingPolicy(scale: scale)
        )
        let frame = result.placement(for: flexID(2))?.frame

        #expect(frame?.width ?? -1 >= 0)
        #expect(frame?.height ?? -1 >= 0)
    }
}

// R07 (`docs/adr/0026-scroll-node-viewport.md`): a `.scroll` container's children keep their
// natural main-axis size through to placement too, not just measurement — the placed frames
// stack past the container's own committed frame, exactly what makes the content scrollable
// (clipping is `LayerRenderer`'s job at render time, not the layout result's).
@Test
func test_layoutContainer_scrollOverflowStacksChildrenPastTheContainersOwnFrame() throws {
    var style = flexStyle(flexDirection: .column, height: .points(200))
    style.visual = LayoutVisualProperties(overflow: .scroll)
    let first = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(height: .points(300)))
    let second = LayoutInputSnapshot(identity: flexID(3), style: flexStyle(height: .points(300)))
    let root = LayoutInputSnapshot(identity: flexID(1), style: style, children: [first, second])

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 300, height: 200)
    )

    // Both children keep their natural 300pt height — the second is placed entirely outside
    // the container's own 200pt committed frame (origin.y 300, past the 0...200 viewport).
    #expect(result.placement(for: flexID(2))?.frame.height == 300)
    #expect(result.placement(for: flexID(2))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(3))?.frame.height == 300)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 300)
    // The container's own placed frame is unaffected — still the definite 200pt it was given.
    #expect(result.placement(for: flexID(1))?.frame.height == 200)
}
