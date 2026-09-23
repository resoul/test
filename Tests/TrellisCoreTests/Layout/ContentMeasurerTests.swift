import Testing
import os

@testable import TrellisCore

// T03 (implementation-plan-4.md, D49): the solver calls a leaf's `ContentMeasurer` at the
// actual constraint it resolves, instead of relying on the fixed value a snapshot captured
// once. `PortableFallbackMeasurer` (D51/#40) is a deterministic stand-in — not typography —
// used only to prove the plumbing: width-driven height, baseline flow, cache reuse and
// cancellation. Nodes without a measurer are covered by the untouched C12 suite instead of a
// dedicated test here (unaffected by construction: `measuredContent = input.content` when
// `content.measurer == nil`, byte-for-byte the previous code path).

@Test
func test_contentMeasurer_columnWidthDrivesWrappedHeight() throws {
    let text = String(repeating: "word ", count: 40)

    func height(forColumnWidth width: Double) throws -> Double {
        let measurer = PortableFallbackMeasurer(text: text, pointSize: 10)
        let leaf = LayoutInputSnapshot(
            identity: flexID(2),
            content: LayoutContentMetrics(measurer: measurer)
        )
        let root = LayoutInputSnapshot(
            identity: flexID(1),
            style: flexStyle(flexDirection: .column, width: .points(width)),
            children: [leaf]
        )
        return try FlexboxEngine.measureContainer(input: root).parentSize.height
    }

    // Same text, same style, only the column's width differs (§3.3/W04 — this is the mine
    // T01/T03 close): a narrower column must wrap into more, taller lines than a wide one,
    // proving the leaf's height came from the width the solver actually resolved it to.
    let narrow = try height(forColumnWidth: 120)
    let wide = try height(forColumnWidth: 800)

    #expect(narrow > wide)
}

@Test
func test_contentMeasurer_explicitMainSizeOnALeafConstrainsItsOwnContentMeasurement() throws {
    // Defect #46 (docs/defects.md, found building T12's S24_Typography scene): a leaf's own
    // explicit main-axis size (`style.width` in a row) used to never reach its own content
    // measurement at all — only the parent-offered basis constraint did, which is
    // `.unspecified` on the main axis by construction (ADR 0009), regardless of whether this
    // leaf's own style already pins a definite size. A content-dependent leaf (a wrapping
    // `TextNode`, modeled here by `PortableFallbackMeasurer`) then measured its cross-axis
    // size against an effectively unbounded width and never wrapped — and since its basis
    // already equalled its resolved main size (no grow/shrink needed), the later
    // exact-constraint remeasure pass that would normally catch this never triggered either
    // (`FlexboxPlacement.reusableMeasure`'s trigger is "resolved size differs from basis").
    let text = String(repeating: "word ", count: 40)
    let measurer = PortableFallbackMeasurer(text: text, pointSize: 10)
    let leaf = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(120)),
        content: LayoutContentMetrics(measurer: measurer)
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .row, width: .points(800), height: .points(400)),
        children: [leaf]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 800, height: 400)
    )
    let placement = try #require(result.placement(for: flexID(2)))

    // Wrapped at the leaf's own 120pt width, not left as one unbroken natural-width line
    // (which `PortableFallbackMeasurer` would report many hundreds of points wide, and only
    // one line tall) — the same "narrower column wraps taller" shape
    // `test_contentMeasurer_columnWidthDrivesWrappedHeight` already proves for a
    // container-stretched leaf, now proven for a leaf with its own explicit main size instead.
    #expect(placement.frame.width == 120)
    #expect(placement.frame.height > 20)
}

@Test
func test_contentMeasurer_calledOnceForSoleChildOfDefaultStretchColumn() throws {
    // Default `alignItems` is `.stretch` (flexStyle's default) — the common case, not an
    // edge case: a single unconstrained-width child in a column is stretched to the column's
    // width by default. This asserts the solver's cache prevents a second measurer call for
    // that stretch pass on top of the basis pass, for the ordinary single-leaf shape.
    let measurer = PortableFallbackMeasurer(text: "Hello, Trellis", pointSize: 15)
    let leaf = LayoutInputSnapshot(
        identity: flexID(2),
        content: LayoutContentMetrics(measurer: measurer)
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column, width: .points(200)),
        children: [leaf]
    )

    _ = try FlexboxEngine.layoutContainer(input: root, frame: LayoutFrame(width: 200, height: 200))

    #expect(measurer.callCount == 1)
}

@Test
func test_contentMeasurer_baselineAlignmentUsesFreshMeasurerValueNotStaticSnapshot() throws {
    // pointSize 40 → lineHeight 48 → baseline 38.4; pointSize 10 → lineHeight 12 → baseline 9.6.
    // Explicit width/height on both leaves isolate the geometry under test — only the
    // measurer-reported `firstBaseline` should move the smaller leaf's placement.
    let tall = PortableFallbackMeasurer(text: "Big", pointSize: 40)
    let small = PortableFallbackMeasurer(text: "sm", pointSize: 10)
    let tallLeaf = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(40), height: .points(48)),
        content: LayoutContentMetrics(measurer: tall)
    )
    let smallLeaf = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(width: .points(30), height: .points(12)),
        content: LayoutContentMetrics(measurer: small)
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .row, alignItems: .baseline),
        children: [tallLeaf, smallLeaf]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 200, height: 100),
        roundingPolicy: PixelRoundingPolicy(scale: 100)
    )

    let tallPlacement = try #require(result.placement(for: flexID(2)))
    let smallPlacement = try #require(result.placement(for: flexID(3)))

    // Line baseline is max(38.4, 9.6) = 38.4; the shorter leaf offsets down by 38.4 - 9.6.
    #expect(tallPlacement.frame.origin.y == 0)
    #expect(abs(smallPlacement.frame.origin.y - 28.8) < 0.01)
}

@Test
func test_contentMeasurer_alreadyCancelledContextThrowsBeforeCompletingAndDoesNotCount() throws {
    // Contrast with the existing, documented `test_measureContainer_leafWithNoFlexLinesNever
    // ChecksCancellation` (FlexboxCancellationTests.swift): a bare leaf has no checkpoint of
    // its own, but a leaf with a measurer now does, because the measurer checks internally
    // (D58) — this is the new checkpoint T03 adds, not a change to the old one.
    let measurer = PortableFallbackMeasurer(text: "Some text", pointSize: 12)
    let leaf = LayoutInputSnapshot(
        identity: flexID(1),
        content: LayoutContentMetrics(measurer: measurer)
    )
    let cancelled = LayoutContext(cancellationCheck: { true })

    #expect(throws: LayoutCancellationError.cancelled) {
        try FlexboxEngine.measureContainer(input: leaf, context: cancelled)
    }
    #expect(measurer.callCount == 0)
}

@Test
func test_contentMeasurer_cancellationMidParagraphThrowsWithoutPartialResult() throws {
    // A long paragraph wraps into many lines at a narrow width, giving the per-line
    // checkpoint (D58) something to actually interrupt — not just the entry check above.
    // The lock-protected counter (not a captured `var`) is what makes this closure a legal
    // `@Sendable` value without `@unchecked Sendable`/`nonisolated(unsafe)` (AGENTS ban).
    let paragraph = String(repeating: "word ", count: 200)
    let measurer = PortableFallbackMeasurer(text: paragraph, pointSize: 12)
    let leaf = LayoutInputSnapshot(
        identity: flexID(1),
        content: LayoutContentMetrics(measurer: measurer)
    )
    let remainingChecks = OSAllocatedUnfairLock(initialState: 1)
    let cancelAfterFirstCheck = LayoutContext(cancellationCheck: {
        remainingChecks.withLock { count -> Bool in
            guard count > 0 else { return true }
            count -= 1
            return false
        }
    })

    #expect(throws: LayoutCancellationError.cancelled) {
        try FlexboxEngine.measureContainer(
            input: leaf,
            constraint: SizeConstraint(width: .exact(60)),
            context: cancelAfterFirstCheck
        )
    }
    #expect(
        measurer.callCount == 0,
        "a mid-measurement cancellation must not be counted as completed"
    )
}

@Test
func test_contentMeasurer_growingBeyondNaturalSizeRemeasuresAtTheExactGrownConstraint() throws {
    // §3.1 of implementation-plan-4.md names three points the solver measures a leaf at:
    // basis (main `.unspecified`), the exact main size after grow/shrink, and — when that
    // resolved frame no longer matches the basis measurement — placement's own fallback pass
    // with *both* axes `.exact` (`FlexboxPlacement.placeContainer`'s `measureContainer` call,
    // reached because `reusableMeasure` cannot reuse a stretch that also grew). `flexGrow`
    // forces exactly that: the leaf's natural height is smaller than what it grows into.
    var leafStyle = flexStyle(width: .points(100))
    leafStyle.flexGrow = 1
    let measurer = PortableFallbackMeasurer(text: "grows", pointSize: 10)
    let leaf = LayoutInputSnapshot(
        identity: flexID(2),
        style: leafStyle,
        content: LayoutContentMetrics(measurer: measurer)
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column, width: .points(100), height: .points(90)),
        children: [leaf]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 90)
    )

    let placement = try #require(result.placement(for: flexID(2)))
    // Grown to fill the column's full height, not the natural one-line height a plain basis
    // measurement would have reported.
    #expect(placement.frame.height == 90)
    // At least basis + grown-exact-main + placement's exact-both fallback: more than one
    // distinct constraint, each served once — not one constraint served three times.
    #expect(measurer.callCount >= 2)
}

@Test
func test_contentMeasurer_sameConstraintIsServedFromCacheNotFromASecondCall() throws {
    let measurer = PortableFallbackMeasurer(text: "Repeated lookup", pointSize: 14)
    let leaf = LayoutInputSnapshot(
        identity: flexID(1),
        content: LayoutContentMetrics(measurer: measurer)
    )
    var cache = FlexMeasureCache()
    let constraint = SizeConstraint(width: .exact(120), height: .unspecified)

    _ = try FlexboxEngine.measureContainer(input: leaf, constraint: constraint, cache: &cache)
    _ = try FlexboxEngine.measureContainer(input: leaf, constraint: constraint, cache: &cache)

    #expect(measurer.callCount == 1)
    #expect(cache.statistics.hits == 1)
}
