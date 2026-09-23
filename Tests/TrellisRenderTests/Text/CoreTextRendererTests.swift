import CoreText
import Foundation
import Testing
import TrellisCore

@testable import TrellisRender

// T05 — real CoreText measurement, closing defects #36-#39 (implementation-plan-4.md).
// PortableTextMeasurer stays untouched and is never compared against these results (D51/#40).

private func input(
    text: String,
    style: TextStyle = TextStyle(),
    direction: LayoutDirection = .leftToRight,
    localeIdentifier: String = "en",
    maxLines: Int? = nil,
    truncation: TextTruncation = .tail
) -> TextLayoutInput {
    TextLayoutInput(
        document: TextDocument(text),
        style: style,
        direction: direction,
        localeIdentifier: localeIdentifier,
        maxLines: maxLines,
        truncation: truncation
    )
}

@Test
func t05_emptyStringIsOneLineAtNaturalLineHeight() throws {
    let renderer = CoreTextRenderer()
    let metrics = try renderer.measure(
        input(text: ""),
        constraint: SizeConstraint(width: .exact(200)),
        context: .noCancellation
    )
    #expect(metrics.lineCount == 1)
    #expect(metrics.size.width == 200)
    #expect(metrics.size.height > 0)
    #expect(metrics.didTruncate == false)
}

@Test
func t05_narrowerWidthWrapsIntoMoreRealLines() throws {
    let renderer = CoreTextRenderer()
    let text = String(
        repeating: "Trellis measures content against the width the solver actually gave it. ",
        count: 10
    )
    let narrow = try renderer.measure(
        input(text: text),
        constraint: SizeConstraint(width: .atMost(160)),
        context: .noCancellation
    )
    let wide = try renderer.measure(
        input(text: text),
        constraint: SizeConstraint(width: .atMost(900)),
        context: .noCancellation
    )
    // Defect #36: real CTLine count, not `ceil(height / lineHeight)` — a narrower width must
    // produce strictly more wrapped lines from the same framesetter pass.
    #expect(narrow.lineCount > wide.lineCount)
    #expect(narrow.size.height > wide.size.height)
    #expect(narrow.size.width <= 160.5)
}

@Test
func t05_firstBaselineIsRealAscentNotAConstant() throws {
    let renderer = CoreTextRenderer()
    let style = TextStyle(pointSize: 17)
    let metrics = try renderer.measure(
        input(text: "Hello, Trellis", style: style),
        constraint: SizeConstraint(width: .atMost(400)),
        context: .noCancellation
    )
    // Defect #38: the Weave constant this replaces was `lineHeight * 0.8`, `lineHeight` taken as
    // `pointSize` when natural — demonstrate divergence, not a tolerance match.
    let weaveConstant = 17.0 * 0.8
    #expect(abs(metrics.firstBaseline - weaveConstant) > 1.0)
    #expect(metrics.firstBaseline > 0)
    #expect(metrics.firstBaseline < style.pointSize * 1.5)
}

@Test
func t05_exactWidthReportsConstraintNotNaturalWidth() throws {
    let renderer = CoreTextRenderer()
    let exact = try renderer.measure(
        input(text: "Short"),
        constraint: SizeConstraint(width: .exact(500)),
        context: .noCancellation
    )
    let atMost = try renderer.measure(
        input(text: "Short"),
        constraint: SizeConstraint(width: .atMost(500)),
        context: .noCancellation
    )
    // Defect #39: `.exact` and `.atMost` used to be handled identically (both `min(natural,
    // max)`); `.exact` must report the constraint itself even though the text is much narrower.
    #expect(exact.size.width == 500)
    #expect(atMost.size.width < 500)
    #expect(atMost.size.width > 0)
}

@Test
func t05_localeIsNotSilentlyDropped() throws {
    let renderer = CoreTextRenderer()
    // Defect #39: `localeIdentifier` used to be accepted and explicitly discarded
    // (`_ = localeIdentifier`). This does not assert a specific wrapping difference (locale's
    // effect on line-breaking is font/script dependent) — it asserts the call succeeds for a
    // non-English locale and does not silently no-op on an unreachable code path.
    let metrics = try renderer.measure(
        input(text: "Trennung von Wörtern", localeIdentifier: "de"),
        constraint: SizeConstraint(width: .atMost(60)),
        context: .noCancellation
    )
    #expect(metrics.lineCount >= 1)
    #expect(metrics.size.width <= 60.5)
}

@Test
func t05_maxLinesAndHeightAreIndependentLimiters() throws {
    let renderer = CoreTextRenderer()
    let text = String(repeating: "wrap this line please ", count: 30)

    let byMaxLines = try renderer.measure(
        input(text: text, maxLines: 2),
        constraint: SizeConstraint(width: .atMost(160)),
        context: .noCancellation
    )
    #expect(byMaxLines.lineCount == 2)
    #expect(byMaxLines.didTruncate)

    let unrestricted = try renderer.measure(
        input(text: text),
        constraint: SizeConstraint(width: .atMost(160)),
        context: .noCancellation
    )
    let byHeight = try renderer.measure(
        input(text: text),
        constraint: SizeConstraint(
            width: .atMost(160),
            height: .atMost(unrestricted.size.height / 3)
        ),
        context: .noCancellation
    )
    #expect(byHeight.lineCount >= 1)
    #expect(byHeight.lineCount < unrestricted.lineCount)
    #expect(byHeight.didTruncate)
}

@Test
func t05_clipAndTailTruncationReportTheSameMeasuredBox() throws {
    let renderer = CoreTextRenderer()
    let text = String(repeating: "same measured box either way ", count: 20)
    let clipped = try renderer.measure(
        input(text: text, maxLines: 2, truncation: .clip),
        constraint: SizeConstraint(width: .atMost(160)),
        context: .noCancellation
    )
    let tailed = try renderer.measure(
        input(text: text, maxLines: 2, truncation: .tail),
        constraint: SizeConstraint(width: .atMost(160)),
        context: .noCancellation
    )
    // D56: truncation style changes what a rasterizer draws (T06), never the measured size.
    #expect(clipped.size == tailed.size)
    #expect(clipped.lineCount == tailed.lineCount)
    #expect(clipped.didTruncate && tailed.didTruncate)
}

@Test
func t05_rightToLeftDirectionMeasuresWithoutFailing() throws {
    let renderer = CoreTextRenderer()
    let metrics = try renderer.measure(
        input(text: "שלום עולם", direction: .rightToLeft, localeIdentifier: "he"),
        constraint: SizeConstraint(width: .atMost(300)),
        context: .noCancellation
    )
    #expect(metrics.lineCount == 1)
    #expect(metrics.size.width > 0)
    #expect(metrics.size.width <= 300.5)
}

@Test
func t05_runLevelOverrideWidensBeyondBaseStyleAlone() throws {
    let renderer = CoreTextRenderer()
    var document = TextDocument("small ")
    var big = AttributedString("BIG")
    big.trellisText.pointSize = 40
    document.append(big)

    let mixed = try renderer.measure(
        TextLayoutInput(
            document: document,
            style: TextStyle(pointSize: 12),
            direction: .leftToRight,
            localeIdentifier: "en",
            maxLines: nil,
            truncation: .tail
        ),
        constraint: SizeConstraint(width: .unspecified),
        context: .noCancellation
    )
    let uniform = try renderer.measure(
        input(text: "small BIG", style: TextStyle(pointSize: 12)),
        constraint: SizeConstraint(width: .unspecified),
        context: .noCancellation
    )
    // A run-level `pointSize` override must actually reach CoreText's attributed string, not
    // just the base `TextStyle` — the mixed-run line is measurably wider than an all-12pt line
    // with the same characters.
    #expect(mixed.size.width > uniform.size.width)
}

@Test
func t05_cancelledContextThrowsBeforeMeasuring() {
    let renderer = CoreTextRenderer()
    let cancelled = LayoutContext(cancellationCheck: { true })
    #expect(throws: LayoutCancellationError.self) {
        try renderer.measure(
            input(text: "irrelevant"),
            constraint: SizeConstraint(width: .atMost(100)),
            context: cancelled
        )
    }
}

@Test
func t05_measurementIsDeterministicAcrossOneHundredRepeats() throws {
    let renderer = CoreTextRenderer()
    let paragraph = String(
        repeating: "Determinism across repeated CoreText passes must hold exactly. ",
        count: 12
    )
    let text = input(text: paragraph, style: TextStyle(pointSize: 15))
    let constraint = SizeConstraint(width: .atMost(220))

    let first = try renderer.measure(text, constraint: constraint, context: .noCancellation)
    for _ in 0..<99 {
        let repeated = try renderer.measure(text, constraint: constraint, context: .noCancellation)
        #expect(repeated == first)
    }
}

@Test
func t05_measurementIsSafeFromAWorkerThread() async throws {
    let renderer = CoreTextRenderer()
    let text = input(text: "Measured off the main thread", style: TextStyle(pointSize: 18))
    let constraint = SizeConstraint(width: .atMost(150))

    let result = try await Task.detached {
        try renderer.measure(text, constraint: constraint, context: .noCancellation)
    }.value

    let expected = try renderer.measure(text, constraint: constraint, context: .noCancellation)
    #expect(result == expected)
}
