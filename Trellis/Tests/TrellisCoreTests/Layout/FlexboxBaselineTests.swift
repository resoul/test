import Testing

@testable import TrellisCore

// Ported from Weave's FlexSolverBaselineTests.swift. Its fourth test,
// `test_snapshotBuilder_usesMeasurableNodeIntrinsicAndConstraint`, exercises `TextNode` and a
// `TextLayoutBackend` — no text/content-measurement system exists yet (N01) — so it is not
// ported here.

@Test
func test_baselineAlignment_twoItemsShareTheLargestBaseline() throws {
    let first = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(height: .points(20)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 20),
            firstBaseline: 12
        )
    )
    let second = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(height: .points(30)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 30),
            firstBaseline: 20
        )
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .baseline, width: .points(100), height: .points(40)),
        children: [first, second]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 40)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 8)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 0)
}

@Test
func test_baselineAlignment_itemWithoutBaselineFallsBackToStart() throws {
    let text = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(height: .points(20)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 20),
            firstBaseline: 12
        )
    )
    let image = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(height: .points(30)),
        content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 40, height: 30))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .baseline, width: .points(100), height: .points(40)),
        children: [text, image]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 40)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 0)
}

@Test
func test_baselineAlignment_alignSelfOverridesParentAlignment() throws {
    let baselineChild = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(alignSelf: .baseline, height: .points(20)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 20),
            firstBaseline: 12
        )
    )
    let sibling = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(height: .points(30)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 30),
            firstBaseline: 20
        )
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .end, width: .points(100), height: .points(40)),
        children: [baselineChild, sibling]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 40)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 8)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 10)
}
