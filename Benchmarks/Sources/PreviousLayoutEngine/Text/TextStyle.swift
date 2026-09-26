/// Font weight, independent of platform weight constants — mapped to `UIFont.Weight`/
/// `NSFont.Weight`/CoreText traits only in `TrellisRender` (D50).
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum TextWeight: Sendable, Hashable, CaseIterable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black
}

/// Paragraph alignment, physical direction resolved against `LayoutDirection` at measure/raster
/// time — `.leading` is left in LTR and right in RTL, matching `LayoutStyle`'s own edges.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum TextAlignment: Sendable, Hashable {
    case leading
    case center
    case trailing
}

/// How a `TextNode` handles content that does not fit `maxLines` or the height it was given
/// (D56 — the two are independent limiters; either can trigger `TextMetrics.didTruncate`).
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum TextTruncation: Sendable, Hashable {
    /// Overflow is cut at the bounds with no ellipsis.
    case clip
    /// The last visible line ends with an ellipsis built from real line metrics, not a
    /// character-count guess (W01 — `renderedText` is not ported, T05 draws this).
    case tail
}

/// A `TextNode`'s base, paragraph-level style — the style every run inherits from unless a run
/// overrides one of the supported fields (D55). `lineHeight`/`alignment` are paragraph-wide by
/// design: mixed paragraph rules within one string are not introduced quietly.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct TextStyle: Sendable, Hashable {
    /// Font family name, or `"system"` to resolve the platform system font
    /// (`CTFontCreateUIFontForLanguage` in `TrellisRender`, never a hardcoded name like
    /// `"Helvetica"` — the W02-class defect this replaces).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var fontName: String

    /// Point size, clamped non-negative.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var pointSize: Double

    /// Font weight.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var weight: TextWeight

    /// Line height in points, or `0` for the font's own natural line height (from `CTLine`
    /// ascent/descent/leading in `TrellisRender`, not a fixed multiple of `pointSize`).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var lineHeight: Double

    /// Paragraph alignment.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var alignment: TextAlignment

    /// Text color, or `nil` to resolve `theme.foreground` at render time — color never affects
    /// measurement, only rasterization (T05/T06).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var color: ThemeColor?

    /// Creates a text style, clamping an invalid `pointSize`/`lineHeight` to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        fontName: String = "system",
        pointSize: Double = 17,
        weight: TextWeight = .regular,
        lineHeight: Double = 0,
        alignment: TextAlignment = .leading,
        color: ThemeColor? = nil
    ) {
        self.fontName = fontName
        self.pointSize = pointSize.isFinite ? max(0, pointSize) : 0
        self.weight = weight
        self.lineHeight = lineHeight.isFinite ? max(0, lineHeight) : 0
        self.alignment = alignment
        self.color = color
    }
}
