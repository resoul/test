import TrellisCore

/// Rasterizes a `TextDisplayRequest` into a `DisplayArtifact` — `TrellisRender`'s own protocol,
/// separate from `TrellisCore`'s `TextRenderer` (measure-only, D51/T04). `DisplayArtifact` holds
/// a `CGImage`, and `TrellisCore` may import only Foundation (D50's `CORE_IMPORT` policy rule) —
/// widening `TextRenderer` itself to add `rasterize` was the T01/D51 sketch's original plan, but
/// it cannot cross that module boundary, so this is a sibling protocol `CoreTextRenderer` (T05)
/// also conforms to, not an extension of `TextRenderer`.
///
/// Ownership: implementers are typically stateless value types owned by whichever scheduler
/// calls them. Isolation: none — `Sendable`, called from `DisplayScheduler`'s background
/// workers. Errors: `rasterize(_:context:)` throws `LayoutCancellationError.cancelled` when
/// `context` reports cancellation. Cancellation: implementers check cooperatively at least once
/// before drawing (D58).
public protocol TextRasterizer: Sendable {
    /// Rasterizes `request` at its own `size`/`scale` — the same line-breaking decision
    /// `TextRenderer.measure` made for this box, so what is drawn never diverges from what was
    /// measured (closing the class of defect #37 for the draw side).
    ///
    /// Ownership: the result is a value, owned by the caller. Isolation: none — safe to call
    /// from any thread `DisplayScheduler` runs its workers on. Errors: throws
    /// `LayoutCancellationError.cancelled` if `context` reports cancellation. Cancellation:
    /// checked before drawing begins.
    func rasterize(_ request: TextDisplayRequest, context: LayoutContext) throws -> DisplayArtifact
}
