import Testing

@testable import TrellisCore

// D51/D56/#40: PortableTextMeasurer is TextNode's fallback `TextRenderer` when no host has
// installed one — deterministic and explicitly not typography, but still contractually bound
// by D56 (two independent truncation limiters, .exact vs .atMost width reporting, one line for
// an empty string).

private func input(
    _ text: String,
    maxLines: Int? = nil,
    truncation: TextTruncation = .tail,
    pointSize: Double = 17
) -> TextLayoutInput {
    TextLayoutInput(
        document: TextDocument(text),
        style: TextStyle(pointSize: pointSize),
        direction: .leftToRight,
        localeIdentifier: "en",
        maxLines: maxLines,
        truncation: truncation
    )
}

@Test @MainActor
func t04_portableTextMeasurer_emptyStringIsOneLineAtLineHeight() throws {
    let metrics = try PortableTextMeasurer().measure(
        input(""),
        constraint: SizeConstraint(),
        context: .noCancellation
    )

    #expect(metrics.lineCount == 1)
    #expect(metrics.size.width == 0)
    #expect(metrics.size.height > 0)
    #expect(metrics.didTruncate == false)
}

@Test @MainActor
func t04_portableTextMeasurer_exactWidthReportsExactlyTheConstraintNotTheNaturalWidth() throws {
    let short = try PortableTextMeasurer().measure(
        input("Hi"),
        constraint: SizeConstraint(width: .exact(200)),
        context: .noCancellation
    )
    let atMost = try PortableTextMeasurer().measure(
        input("Hi"),
        constraint: SizeConstraint(width: .atMost(200)),
        context: .noCancellation
    )

    // D56: .exact reports back exactly the constraint; .atMost reports min(natural, max) — for
    // short content that means .atMost is narrower than the bound it was given.
    #expect(short.size.width == 200)
    #expect(atMost.size.width < 200)
}

@Test @MainActor
func t04_portableTextMeasurer_maxLinesTruncatesIndependentlyOfHeight() throws {
    let text = String(repeating: "word ", count: 60)
    let metrics = try PortableTextMeasurer().measure(
        input(text, maxLines: 2),
        constraint: SizeConstraint(width: .exact(100), height: .unspecified),
        context: .noCancellation
    )

    #expect(metrics.lineCount == 2)
    #expect(metrics.didTruncate)
}

@Test @MainActor
func t04_portableTextMeasurer_heightLimitTruncatesEvenWithoutMaxLines() throws {
    let text = String(repeating: "word ", count: 60)
    let unbounded = try PortableTextMeasurer().measure(
        input(text),
        constraint: SizeConstraint(width: .exact(100), height: .unspecified),
        context: .noCancellation
    )
    #expect(unbounded.lineCount > 2, "need enough natural lines for the height limit to bite")

    let heightLimited = try PortableTextMeasurer().measure(
        input(text),
        constraint: SizeConstraint(width: .exact(100), height: .atMost(unbounded.size.height / 2)),
        context: .noCancellation
    )

    // No maxLines set — didTruncate must still be true (W09-class defect this avoids: a nil
    // maxLines does not mean "never truncated").
    #expect(heightLimited.lineCount < unbounded.lineCount)
    #expect(heightLimited.didTruncate)
}

@Test @MainActor
func t04_portableTextMeasurer_widthDrivesLineCountAtTheSameText() throws {
    let text = String(repeating: "word ", count: 40)
    let narrow = try PortableTextMeasurer().measure(
        input(text),
        constraint: SizeConstraint(width: .exact(100), height: .unspecified),
        context: .noCancellation
    )
    let wide = try PortableTextMeasurer().measure(
        input(text),
        constraint: SizeConstraint(width: .exact(3000), height: .unspecified),
        context: .noCancellation
    )

    #expect(narrow.lineCount > wide.lineCount)
    #expect(wide.lineCount == 1)
}

@Test @MainActor
func t04_portableTextMeasurer_cancelledContextThrowsBeforeMeasuring() {
    let cancelled = LayoutContext(cancellationCheck: { true })

    #expect(throws: LayoutCancellationError.cancelled) {
        try PortableTextMeasurer().measure(
            input("Hello"),
            constraint: SizeConstraint(),
            context: cancelled
        )
    }
}
