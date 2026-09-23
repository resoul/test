import Testing

@testable import TrellisCore

// Ported from Weave's FlexSolverTests.swift (docs/weave-analysis.md flags this file as missing
// from the original transfer table; C12 explicitly reviews it anyway). Geometric expectations
// are unchanged from Weave — only identity (`NodeID` vs raw `UInt64`), style construction
// (`flexStyle(...)` vs an all-fields initializer Trellis's `LayoutStyle` does not have), and
// throwing call sites (D09) differ.

@Test
func test_flexboxEngine_nestedRowMeasuresChildrenAndGapDeterministically() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(40), height: .points(20))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            flexDirection: .row,
            padding: DirectionalEdgeInsets(leading: 5, trailing: 5),
            gap: 10
        ),
        children: [child, child],
        environmentRevision: 7,
        contentRevision: 3
    )

    let first = try FlexboxEngine.measureContainer(input: root)
    let second = try FlexboxEngine.measureContainer(input: root)

    #expect(first == second)
    #expect(first.size == MeasuredSize(width: 100, height: 20))
    #expect(first.cacheKey.environmentRevision == 7)
}

@Test
func test_flexboxEngine_wrapUsesCrossGapAndAtMostConstraint() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(60), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .row, flexWrap: .wrap, crossGap: 4),
        children: [child, child, child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .atMost(130), height: .unspecified)
    )

    #expect(result.size == MeasuredSize(width: 120, height: 24))
}

@Test
func test_flexboxEngine_usesSnapshotDirectionWithoutCapturingNode() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(20), height: .points(8))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .row),
        children: [child],
        direction: .rightToLeft
    )

    let result = try FlexboxEngine.measureContainer(input: root)

    #expect(result.size == MeasuredSize(width: 20, height: 8))
}
