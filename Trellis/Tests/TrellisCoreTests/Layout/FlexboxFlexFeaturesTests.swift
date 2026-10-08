import Testing

@testable import TrellisCore

// Ported from Weave's FlexSolverFlexFeaturesTests.swift. Geometric expectations are unchanged.

private func featureChild(
    _ raw: UInt64,
    width: SizeValue = .points(20),
    height: SizeValue = .points(10)
) -> LayoutInputSnapshot {
    LayoutInputSnapshot(identity: flexID(raw), style: flexStyle(width: width, height: height))
}

@Test
func test_flexBasis_overridesWidthOnMainAxis() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexBasis: .points(100), width: .points(200), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(300)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(300))
    )

    #expect(result.lines[0].items[0].mainSize == 100)
}

@Test
func test_flexBasis_fraction_resolvesAgainstParentMainSize() throws {
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexBasis: .fraction(0.5), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(200)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(200))
    )

    #expect(result.lines[0].items[0].mainSize == 100)
}

@Test
func test_alignContent_center_centersWrappedLines() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            flexWrap: .wrap,
            alignContent: .center,
            width: .points(100),
            height: .points(100)
        ),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 40)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 50)
}

@Test
func test_alignContent_spaceBetween_distributesWrappedLines() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            flexWrap: .wrap,
            alignContent: .spaceBetween,
            width: .points(100),
            height: .points(100)
        ),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 90)
}

@Test
func test_alignContent_stretch_expandsWrappedLineSlots() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            flexWrap: .wrap,
            alignContent: .stretch,
            width: .points(100),
            height: .points(100)
        ),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 50)
}

@Test
func test_alignContent_stretch_atNaturalCrossSizeBehavesLikeStart() throws {
    // An auto-sized container laid out at exactly its measured size has no free cross space
    // to share, so stretch is a no-op whether or not the size was written explicitly.
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexWrap: .wrap, alignContent: .stretch, width: .points(100)),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 20)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 10)
    #expect(result.placement(for: flexID(2))?.frame.origin.y.isFinite == true)
}

@Test
func test_alignContent_stretch_sharesFrameCrossSpaceWithoutExplicitCrossSize() throws {
    // The frame handed to the placement pass is definite even when `height` is `.auto` (the
    // parent stretched this container, or it is the host-sized root), so wrapped lines share
    // it exactly as they would under an explicit `height`.
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexWrap: .wrap, alignContent: .stretch, width: .points(100)),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 50)
}

@Test
func test_alignItems_center_usesWholeFrameCrossSizeWithoutExplicitCrossSize() throws {
    // A single line owns the container's whole inner cross size, so `alignItems: .center`
    // and `alignSelf: .end` have the full frame to align within — not just the tallest item —
    // for a row whose `height` is `.auto` (the case of every `Arrangement` wrapper).
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .center, width: .points(100)),
        children: [
            featureChild(2, width: .points(20), height: .points(40)),
            LayoutInputSnapshot(
                identity: flexID(3),
                style: flexStyle(alignSelf: .end, width: .points(20), height: .points(10))
            ),
            featureChild(4, width: .points(20), height: .auto),
        ]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 30)
    #expect(result.placement(for: flexID(3))?.frame.origin.y == 90)
    // An auto-cross item under `.center` keeps its measured size, it is not stretched.
    #expect(result.placement(for: flexID(4))?.frame.height == 0)
}

@Test
func test_alignSelf_center_inAutoWidthColumnCentersHorizontally() throws {
    // The S16–S19 case: a fixed-width card inside a host-sized column root whose `width`
    // is `.auto`.
    let card = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(alignSelf: .center, width: .points(40), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column),
        children: [card]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 50)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.x == 30)
}

@Test
func test_wrapReverse_reversesLineOrderWithoutReorderingItems() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            flexWrap: .wrapReverse,
            alignContent: .start,
            width: .points(100),
            height: .points(100)
        ),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(3))?.frame.origin.y == 0)
    #expect(result.placement(for: flexID(2))?.frame.origin.y == 10)
}
