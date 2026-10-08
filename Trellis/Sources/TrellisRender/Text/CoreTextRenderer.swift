import CoreText
import Foundation
import TrellisCore

/// Real CoreText-backed `TextRenderer` (T05) — replaces `PortableTextMeasurer`'s deterministic
/// approximation with `CTFramesetter`/`CTLine` line-breaking, wherever a host installs this via
/// `TextRendererKey` (T09). Closes defects #36–#39: line count and height come from the actual
/// wrapped `CTLine`s the framesetter produces (not `ceil(height / lineHeight)`), the first
/// baseline is the first line's real ascent (not `lineHeight * 0.8`), `localeIdentifier` reaches
/// `kCTLanguageAttributeName` for line-breaking/font-fallback, and `.exact`/`.atMost` are
/// resolved differently (D56).
///
/// Ownership: stateless value type. Isolation: none — `Sendable`; every `CTFont`/`CTFrame`/
/// `CTLine` created here is used synchronously within one `measure` call and never escapes or is
/// shared across threads (T02's Sendable probe, which covers types that do cross threads, does
/// not apply). Errors: throws `LayoutCancellationError.cancelled` per the `TextRenderer`
/// contract. Cancellation: checked once at entry and at least once per produced line (D58).
public struct CoreTextRenderer: TextRenderer, TextRasterizer {
    /// Creates the CoreText renderer. Stateless — every instance behaves identically.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Ownership: the result is a value, owned by the caller. Isolation: none — safe to call
    /// from any thread the solver runs on. Errors: throws `LayoutCancellationError.cancelled`
    /// if `context` reports cancellation before or during measurement. Cancellation: checked
    /// cooperatively inside multi-line content; a cancelled call returns no partial result.
    public func measure(
        _ input: TextLayoutInput,
        constraint: SizeConstraint,
        context: LayoutContext
    ) throws -> TextMetrics {
        try context.checkCancellation()
        return try CoreTextTypesetter.measure(
            input: input,
            constraint: constraint,
            context: context
        )
    }

    /// Ownership: the result is a value, owned by the caller. Isolation: none — safe to call
    /// from any thread `DisplayScheduler` runs its workers on. Errors: throws
    /// `LayoutCancellationError.cancelled` if `context` reports cancellation. Cancellation:
    /// checked before drawing begins.
    public func rasterize(
        _ request: TextDisplayRequest,
        context: LayoutContext
    ) throws -> DisplayArtifact {
        try context.checkCancellation()
        return try CoreTextTypesetter.rasterize(request: request, context: context)
    }
}
