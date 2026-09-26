/// Everything a text measurer needs for one measurement, captured as a value so the measurer
/// never reads a live `Node` (D49, §3.1 of implementation-plan-4.md): document, style,
/// direction and locale as of snapshot capture, plus the two independent overflow limiters
/// (D56). Deliberately no `scale`: line-breaking and reported sizes are in points, independent
/// of pixel density — `rasterize` (T05/T06) takes `scale` as its own separate parameter, the
/// same way `CTFramesetterSuggestFrameSizeWithConstraints` never sees a scale factor either.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none — `Sendable` so
/// it crosses into background solver/renderer work. Errors: none. Cancellation: not applicable.
public struct TextLayoutInput: Sendable, Hashable {
    /// The text and its run overrides.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let document: TextDocument

    /// The paragraph-level base style runs inherit from.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let style: TextStyle

    /// Resolved layout direction at capture time — alignment's physical edge follows this.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let direction: LayoutDirection

    /// BCP-47-ish locale identifier from `LocaleKey`, for line-breaking and font fallback.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let localeIdentifier: String

    /// Maximum visible lines, or `nil` for no line-count limit (D56 — independent from a
    /// height limiter the caller applies separately).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let maxLines: Int?

    /// How overflow past `maxLines` (or a separately-applied height limit) is handled.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let truncation: TextTruncation

    /// Creates a text layout input.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        document: TextDocument,
        style: TextStyle,
        direction: LayoutDirection,
        localeIdentifier: String,
        maxLines: Int?,
        truncation: TextTruncation
    ) {
        self.document = document
        self.style = style
        self.direction = direction
        self.localeIdentifier = localeIdentifier
        self.maxLines = maxLines
        self.truncation = truncation
    }
}

/// The result of measuring a `TextLayoutInput` — richer than `LayoutContentMetrics` (D49) with
/// line count and truncation, which the solver does not need but a rasterizer (T05/T06) does to
/// draw the same wrapped lines it measured.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct TextMetrics: Sendable, Hashable {
    /// Resolved size: `.exact` constraints report back exactly that width; `.atMost` reports
    /// `min(natural, max)` (D56, closing defect #39).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let size: MeasuredSize

    /// Distance from the top to the first line's real ascent (D55, closing defect #38) — never
    /// a fixed multiple of `lineHeight`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let firstBaseline: Double

    /// Number of visible lines, at least `1` even for an empty string (D56).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let lineCount: Int

    /// `true` when content was cut by `maxLines`, by the height limit, or both (D56 — either
    /// limiter alone is sufficient; this is never `false` just because `maxLines` was `nil`).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let didTruncate: Bool

    /// Creates text metrics, clamping `lineCount` to at least `1`.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(size: MeasuredSize, firstBaseline: Double, lineCount: Int, didTruncate: Bool) {
        self.size = size
        self.firstBaseline = firstBaseline.isFinite ? max(0, firstBaseline) : 0
        self.lineCount = max(1, lineCount)
        self.didTruncate = didTruncate
    }
}
