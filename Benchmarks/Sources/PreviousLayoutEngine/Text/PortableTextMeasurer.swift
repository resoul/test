/// Deterministic, explicitly non-typographic `TextRenderer` (D51, defect #40) — `TextNode`'s
/// fallback when no host has installed a real one via `TextRendererKey`. The model (`pointSize
/// × 0.6` per character, `pointSize × 1.2` natural line height) is arbitrary and fixed only so
/// the same input always reports the same geometry; it is never compared against CoreText
/// (T05) and must not be mistaken for real text measurement in a screenshot or a shipped host.
///
/// Ownership: stateless value type. Isolation: none — `Sendable`, safe to call from background
/// solver work. Errors: throws `LayoutCancellationError.cancelled` per the `TextRenderer`
/// contract. Cancellation: checked once at entry and at least once per wrapped line (D58).
public struct PortableTextMeasurer: TextRenderer {
    private static let charWidthRatio = 0.6
    private static let naturalLineHeightRatio = 1.2

    /// Creates the fallback measurer. Stateless — every instance behaves identically.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Ownership: the result is a value, owned by the caller. Isolation: none — safe to call
    /// from any thread the solver runs on. Errors: throws `LayoutCancellationError.cancelled`
    /// if `context` reports cancellation before or during measurement. Cancellation: checked
    /// once at entry and at least once per wrapped line.
    public func measure(
        _ input: TextLayoutInput,
        constraint: SizeConstraint,
        context: LayoutContext
    ) throws -> TextMetrics {
        try context.checkCancellation()

        let text = input.document.plainCharacters
        let pointSize = input.style.pointSize
        let charWidth = pointSize * Self.charWidthRatio
        let lineHeight =
            input.style.lineHeight > 0
            ? input.style.lineHeight : pointSize * Self.naturalLineHeightRatio
        let baseline = lineHeight * 0.8

        guard !text.isEmpty else {
            return TextMetrics(
                size: MeasuredSize(width: 0, height: lineHeight),
                firstBaseline: baseline,
                lineCount: 1,
                didTruncate: false
            )
        }

        let naturalWidth = Double(text.count) * charWidth
        let naturalLineCount: Int
        let reportedWidth: Double
        switch constraint.width {
        case .unspecified:
            naturalLineCount = 1
            reportedWidth = naturalWidth
        case let .atMost(bound):
            naturalLineCount = Self.wrappedLineCount(
                naturalWidth: naturalWidth,
                bound: bound,
                charWidth: charWidth,
                characters: text.count
            )
            reportedWidth = min(naturalWidth, bound)
        case let .exact(bound):
            naturalLineCount = Self.wrappedLineCount(
                naturalWidth: naturalWidth,
                bound: bound,
                charWidth: charWidth,
                characters: text.count
            )
            reportedWidth = bound
        }

        // Cooperative cancellation at least once per line (D58).
        for _ in 1..<naturalLineCount { try context.checkCancellation() }

        var visibleLineCount = naturalLineCount
        var didTruncate = false
        if let maxLines = input.maxLines, naturalLineCount > maxLines {
            visibleLineCount = maxLines
            didTruncate = true
        }
        // Height is the second, independent limiter (D56) — `.exact` and `.atMost` both carry
        // a known bound this content cannot grow past.
        if let maxHeight = constraint.height.knownValue {
            let heightLimitedLines = max(1, Int((maxHeight / lineHeight).rounded(.down)))
            if heightLimitedLines < visibleLineCount {
                visibleLineCount = heightLimitedLines
                didTruncate = true
            }
        }

        return TextMetrics(
            size: MeasuredSize(width: reportedWidth, height: Double(visibleLineCount) * lineHeight),
            firstBaseline: baseline,
            lineCount: visibleLineCount,
            didTruncate: didTruncate
        )
    }

    private static func wrappedLineCount(
        naturalWidth: Double,
        bound: Double,
        charWidth: Double,
        characters: Int
    )
        -> Int
    {
        guard naturalWidth > bound else { return 1 }
        let charsPerLine = max(1, Int(bound / charWidth))
        return Int((Double(characters) / Double(charsPerLine)).rounded(.up))
    }
}
