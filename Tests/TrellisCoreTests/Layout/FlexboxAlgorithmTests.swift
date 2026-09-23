import Testing

@testable import TrellisCore

// Ported from Weave's FlexSolverAlgorithmTests.swift. Geometric expectations are unchanged.

private func algorithmChild(
    _ raw: UInt64,
    width: SizeValue = .auto,
    height: SizeValue = .points(10),
    style: LayoutStyle? = nil,
    content: LayoutContentMetrics = LayoutContentMetrics()
) -> LayoutInputSnapshot {
    LayoutInputSnapshot(
        identity: flexID(raw),
        style: style ?? flexStyle(width: width, height: height),
        content: content
    )
}

@Test
func test_flexboxEngine_grow_distributesFreeMainSpace() throws {
    let child = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(flexGrow: 1))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(200)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(200))
    )

    #expect(result.lines[0].items[0].mainSize == 200)
}

@Test
func test_flexboxEngine_shrink_respectsMinimumAndRedistributes() throws {
    let first = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(80), minWidth: .points(60))
    )
    let second = LayoutInputSnapshot(identity: flexID(3), style: flexStyle(width: .points(80)))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(100)),
        children: [first, second]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(100))
    )
    let items = result.lines[0].items

    #expect(items[0].mainSize == 60)
    #expect(items[1].mainSize == 40)
}

@Test
func test_flexboxEngine_wrap_preservesLineAssignment() throws {
    let child = { (raw: UInt64) in
        LayoutInputSnapshot(
            identity: flexID(raw),
            style: flexStyle(width: .points(60), height: .points(10))
        )
    }
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexWrap: .wrap, width: .points(100)),
        children: [child(2), child(3), child(4)]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(100))
    )

    #expect(result.lines.count == 3)
    #expect(result.lines.allSatisfy { $0.items.count == 1 })
}

@Test
func test_flexboxEngine_absoluteChildIsExcludedFromFlexLines() throws {
    let relative = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(flexGrow: 1))
    let absolute = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(positionType: .absolute)
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(200)),
        children: [relative, absolute]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(200))
    )

    #expect(result.lines.count == 1)
    #expect(result.lines[0].items.map(\.identity) == [flexID(2)])
}

@Test
func test_flexboxEngine_weightedGrow_usesPreRoundingGeometry() throws {
    let children = [2, 3, 4].enumerated().map { index, raw in
        LayoutInputSnapshot(
            identity: flexID(UInt64(raw)),
            style: flexStyle(
                flexGrow: index == 1 ? 2 : 1,
                width: .points(30),
                height: .points(10)
            )
        )
    }
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(300)),
        children: children
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(300))
    )
    let sizes = result.lines[0].items.map(\.mainSize)

    #expect(abs(sizes[0] - 82.5) < 0.0001)
    #expect(abs(sizes[1] - 135.0) < 0.0001)
    #expect(abs(sizes[2] - 82.5) < 0.0001)
}

@Test
func test_flexboxEngine_proportionalShrink_usesFlexBasis() throws {
    let first = algorithmChild(
        2,
        style: flexStyle(flexBasis: .points(150), width: .points(50), height: .points(10))
    )
    let second = algorithmChild(
        3,
        style: flexStyle(flexBasis: .points(100), width: .points(50), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(200)),
        children: [first, second]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(200))
    )

    #expect(abs(result.lines[0].items[0].mainSize - 120) < 0.0001)
    #expect(abs(result.lines[0].items[1].mainSize - 80) < 0.0001)
}

@Test
func test_flexboxEngine_shrinkZero_preventsCompression() throws {
    let child = algorithmChild(
        2,
        style: flexStyle(flexShrink: 0, width: .points(150), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(100)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(100))
    )

    #expect(result.lines[0].items[0].mainSize == 150)
}

@Test
func test_flexboxEngine_growZero_doesNotExpand() throws {
    let child = algorithmChild(
        2,
        style: flexStyle(flexGrow: 0, width: .points(50), height: .points(10))
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

    #expect(result.lines[0].items[0].mainSize == 50)
}

@Test
func test_flexboxEngine_wrap_placesLinesAfterPreviousCrossSize() throws {
    let first = algorithmChild(2, width: .points(80), height: .points(40))
    let second = algorithmChild(3, width: .points(80), height: .points(30))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexWrap: .wrap, alignContent: .start, width: .points(100)),
        children: [first, second]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(3))?.frame.origin.y == 40)
}

@Test
func test_flexboxEngine_wrap_twoItemsFitOnOneLine() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexWrap: .wrap, alignContent: .start, width: .points(120)),
        children: [algorithmChild(2, width: .points(60)), algorithmChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 120, height: 30)
    )

    #expect(result.placement(for: flexID(3))?.frame.origin.x == 60)
}

@Test
func test_flexboxEngine_crossGap_appliesBetweenLines() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            flexWrap: .wrap,
            alignContent: .start,
            width: .points(100),
            crossGap: 5
        ),
        children: [algorithmChild(2, width: .points(60)), algorithmChild(3, width: .points(60))]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 40)
    )

    #expect(result.placement(for: flexID(3))?.frame.origin.y == 15)
}

@Test
func test_flexboxEngine_alignItems_centerAndEndPositionCrossAxis() throws {
    let centered = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .center, width: .points(100), height: .points(100)),
        children: [algorithmChild(2, width: .points(20), height: .points(40))]
    )
    let trailing = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(alignItems: .end, width: .points(100), height: .points(100)),
        children: [algorithmChild(4, width: .points(20), height: .points(40))]
    )

    let centeredResult = try FlexboxEngine.layoutContainer(
        input: centered,
        frame: LayoutFrame(width: 100, height: 100)
    )
    let trailingResult = try FlexboxEngine.layoutContainer(
        input: trailing,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(centeredResult.placement(for: flexID(2))?.frame.origin.y == 30)
    #expect(trailingResult.placement(for: flexID(4))?.frame.origin.y == 60)
}

@Test
func test_flexboxEngine_alignItems_stretchExpandsAutoCrossSize() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(100), height: .points(100)),
        children: [algorithmChild(2, width: .points(20), height: .auto)]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.height == 100)
}

@Test
func test_flexboxEngine_alignSelfOverridesParentCrossAlignment() throws {
    let child = algorithmChild(
        2,
        style: flexStyle(alignSelf: .center, width: .points(20), height: .points(40))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .end, width: .points(100), height: .points(100)),
        children: [child]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.y == 30)
}

@Test
func test_flexboxEngine_aspectRatio_resolvesAutoDimension() throws {
    let child = algorithmChild(
        2,
        style: flexStyle(width: .points(100), height: .auto, aspectRatio: 2)
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [child])

    let result = try FlexboxEngine.measureContainer(input: root)

    #expect(result.lines[0].items[0].crossSize == 50)
}

@Test
func test_flexboxEngine_absoluteOffsetsUsePaddingBox() throws {
    let child = algorithmChild(
        2,
        style: flexStyle(
            width: .points(20),
            height: .points(20),
            positionType: .absolute,
            offsets: DirectionalEdgeOffsets(top: 5, leading: 20)
        )
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(
            width: .points(100),
            height: .points(100),
            padding: DirectionalEdgeInsets(top: 10, leading: 10)
        ),
        children: [child]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.x == 30)
    #expect(result.placement(for: flexID(2))?.frame.origin.y == 15)
}

@Test
func test_flexboxEngine_absoluteChildDoesNotContributeToShrinkToFitSize() throws {
    let relative = algorithmChild(2, width: .points(50))
    let absolute = algorithmChild(
        3,
        style: flexStyle(width: .points(200), height: .points(10), positionType: .absolute)
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [relative, absolute])

    let result = try FlexboxEngine.measureContainer(input: root)

    #expect(result.parentSize.width == 50)
}

@Test
func test_flexboxEngine_fractionWidth_resolvesAgainstParent() throws {
    let child = algorithmChild(2, width: .fraction(0.5))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(400)),
        children: [child]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 400, height: 30)
    )

    #expect(result.placement(for: flexID(2))?.frame.width == 200)
}

@Test
func test_flexboxEngine_fractionWithoutParentUsesIntrinsicContent() throws {
    let child = algorithmChild(
        2,
        width: .fraction(0.5),
        content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 37, height: 10))
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [child])

    let result = try FlexboxEngine.measureContainer(input: root)

    #expect(result.lines[0].items[0].mainSize == 37)
}

@Test
func test_flexboxEngine_rtlRowReversesMainAxis() throws {
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(100)),
        children: [algorithmChild(2, width: .points(50)), algorithmChild(3, width: .points(50))],
        direction: .rightToLeft
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 20)
    )

    #expect(result.placement(for: flexID(2))?.frame.origin.x == 50)
    #expect(result.placement(for: flexID(3))?.frame.origin.x == 0)
}

@Test
func test_flexboxEngine_grow_clampsToMaximumWidth() throws {
    // Not a Weave port: none of the ported suites exercised maxWidth/maxHeight clamping,
    // even though `resolveLines`' final per-item resolution has always clamped against it
    // (both here and in Weave). Added for the C12 acceptance line "min/max" coverage.
    let child = algorithmChild(
        2,
        style: flexStyle(flexGrow: 1, width: .points(50), maxWidth: .points(120))
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

    #expect(result.lines[0].items[0].mainSize == 120)
}

// R07 (`docs/adr/0026-scroll-node-viewport.md`, `docs/validation/r07-scroll-node.md`):
// `overflow == .scroll` on a flex container makes its own main axis behave as `.unspecified`
// for child grow/shrink distribution (`r06-scroll-api-sketch.md` §2), so `ScrollNode`'s
// children keep their natural (max-content) main size instead of being compressed to the
// container's own definite size — the fix for `ScrollState.contentSize` never exceeding the
// viewport for a default `flexShrink == 1` child, previously worked around in
// `ScrollNodeHitTestTests.swift` with an explicit `flexShrink = 0` on every child.

private func scrollStyle(
    flexDirection: FlexDirection = .column,
    width: SizeValue = .auto,
    height: SizeValue = .auto,
    flexGrow: Double = 0,
    flexShrink: Double = 1
) -> LayoutStyle {
    var style = flexStyle(
        flexDirection: flexDirection,
        flexGrow: flexGrow,
        flexShrink: flexShrink,
        width: width,
        height: height
    )
    style.visual = LayoutVisualProperties(overflow: .scroll)
    return style
}

@Test
func test_flexboxEngine_scrollOverflowMainAxisChildKeepsNaturalSizeInsteadOfShrinking() throws {
    // A single child taller (900) than the definite scroll viewport (200), default
    // `flexShrink == 1`: an ordinary column container would compress it to 200 (see the
    // regression test just below); a `.scroll` container must not.
    let child = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(height: .points(900)))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: scrollStyle(height: .points(200)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )

    #expect(result.lines[0].items[0].mainSize == 900)
    // The container's own measured size is still its definite, constrained viewport size —
    // only the child's distribution changed, not the scroll node's own frame.
    #expect(result.size.height == 200)
}

@Test
func test_flexboxEngine_scrollOverflowMainAxisMultipleChildrenAllKeepNaturalSize() throws {
    let first = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(height: .points(300)))
    let second = LayoutInputSnapshot(identity: flexID(3), style: flexStyle(height: .points(300)))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: scrollStyle(height: .points(200)),
        children: [first, second]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )
    let items = result.lines[0].items

    #expect(items[0].mainSize == 300)
    #expect(items[1].mainSize == 300)
}

@Test
func test_flexboxEngine_scrollOverflowMainAxisChildDoesNotGrowToFillContainer() throws {
    // Short content (child main size 50) inside a taller scroll viewport (200), with
    // `flexGrow: 1`: an ordinary container would grow the child to fill 200 (see the
    // regression test below); a `.scroll` container's main axis has no bound to grow into,
    // so the child keeps its own natural size — `ScrollState.contentSize` for short content
    // comes from `LayerRenderer`'s own `max(viewport, union)` floor (`LayerRenderer.swift`),
    // not from an artificially stretched child.
    let child = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexGrow: 1, height: .points(50))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: scrollStyle(height: .points(200)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )

    #expect(result.lines[0].items[0].mainSize == 50)
}

@Test
func test_flexboxEngine_scrollOverflowCrossAxisIsStillBoundByTheContainer() throws {
    // Only the main axis changes; the cross axis (width, for a column) still stretches to the
    // container's own size exactly as for any other container (`alignItems: .stretch`
    // default) — checked through placement (`layoutContainer`), the pass that actually
    // resolves stretch, the same way `test_flexboxEngine_alignItems_stretchExpandsAutoCrossSize`
    // above does for an ordinary container.
    let child = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(height: .points(900)))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: scrollStyle(width: .points(300), height: .points(200)),
        children: [child]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 300, height: 200)
    )

    #expect(result.placement(for: flexID(2))?.frame.width == 300)
    // ...and the main axis (height) kept the child's natural size, not the container's 200.
    #expect(result.placement(for: flexID(2))?.frame.height == 900)
}

@Test
func test_flexboxEngine_nonScrollOverflowStillShrinksToFitContainer_regression() throws {
    // Same shape as `test_flexboxEngine_scrollOverflowMainAxisChildKeepsNaturalSizeInsteadOfShrinking`,
    // but `overflow: .hidden` (not `.scroll`) — proves the `.scroll`-only special case does not
    // leak into ordinary flex layout: a definite-height column still compresses a taller child
    // to fit it, exactly as before this card (`test_flexboxEngine_shrink_respectsMinimumAndRedistributes`
    // above already covers the plain-`overflow` shrink path generally; this test is specifically
    // about `.hidden` staying unaffected by the new `.scroll` branch).
    var style = flexStyle(flexDirection: .column, height: .points(200))
    style.visual = LayoutVisualProperties(overflow: .hidden)
    let child = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(height: .points(900)))
    let root = LayoutInputSnapshot(identity: flexID(1), style: style, children: [child])

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )

    #expect(result.lines[0].items[0].mainSize == 200)
}

@Test
func test_flexboxEngine_defaultOverflowVisibleStillShrinksAndGrowsAsToday_regression() throws {
    // `overflow: .visible` (the default `LayoutStyle` never sets `.scroll`) — same shrink
    // scenario, and a grow scenario, both unaffected.
    let shrinkChild = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(height: .points(900))
    )
    let shrinkRoot = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column, height: .points(200)),
        children: [shrinkChild]
    )
    let shrinkResult = try FlexboxEngine.measureContainer(
        input: shrinkRoot,
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )
    #expect(shrinkResult.lines[0].items[0].mainSize == 200)

    let growChild = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(flexDirection: .column, flexGrow: 1, height: .points(50))
    )
    let growRoot = LayoutInputSnapshot(
        identity: flexID(4),
        style: flexStyle(flexDirection: .column, height: .points(200)),
        children: [growChild]
    )
    let growResult = try FlexboxEngine.measureContainer(
        input: growRoot,
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )
    #expect(growResult.lines[0].items[0].mainSize == 200)
}

@Test
func test_flexboxEngine_scrollOverflowRowDirectionAlsoKeepsNaturalWidth() throws {
    // The scrollable axis follows `flexDirection`, not a hardcoded vertical assumption — a
    // `.row` `.scroll` container (horizontal scrolling) keeps a wide child's natural width.
    let child = LayoutInputSnapshot(identity: flexID(2), style: flexStyle(width: .points(900)))
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: scrollStyle(flexDirection: .row, width: .points(200)),
        children: [child]
    )

    let result = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(200), height: .unspecified)
    )

    #expect(result.lines[0].items[0].mainSize == 900)
}
