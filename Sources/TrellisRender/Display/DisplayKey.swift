import TrellisCore

/// Everything that must match for a committed `DisplayArtifact` to still be valid for a node
/// (D52/D53) — deliberately independent of `HitTestSnapshot`/`SemanticSnapshot`, which key by
/// `mountEpoch` instead: a `DisplayScheduler` is recreated per mount (`NodeHostBridge.attach`),
/// so a stale mount's artifacts cannot outlive it, the same reasoning `RenderCoordinator` and
/// `LayoutScheduler` already apply to their own per-mount state.
///
/// `contentRevision`/`displayRevision` already capture every `TextNode` field that can change
/// (T04: geometry-affecting fields bump the former, color-only changes bump the latter) —
/// `environmentRevision` extends that to the one input those two miss: a theme, locale, or
/// text-renderer change inherited from `EnvironmentValues` with no `TextNode` field of its own
/// changing.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct DisplayKey: Sendable, Hashable {
    /// The node's `geometryRevision` at the moment this key was computed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let contentRevision: UInt64

    /// The node's `displayRevision` (paint-only changes, T04) at the moment this key was computed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let displayRevision: UInt64

    /// The node's inherited `EnvironmentSnapshot.revision` — covers theme/locale/renderer
    /// changes that touch neither revision above.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let environmentRevision: UInt64

    /// The node's final committed content-box size — a resize with no content change still
    /// needs a new bitmap at the new size.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let size: MeasuredSize

    /// The host's pixel scale at commit time.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scale: Double

    /// Creates a display key, clamping an invalid `scale` to `1`.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        contentRevision: UInt64,
        displayRevision: UInt64,
        environmentRevision: UInt64,
        size: MeasuredSize,
        scale: Double
    ) {
        self.contentRevision = contentRevision
        self.displayRevision = displayRevision
        self.environmentRevision = environmentRevision
        self.size = size
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    /// Whether `self` and `other` agree on every field that means the *content* to draw is the
    /// same — text, style, and inherited theme/locale — ignoring `size`/`scale` (T07, D65).
    ///
    /// D65 draws a hard line between the two ways a committed bitmap can go stale: a pure
    /// resize/rescale keeps showing the old bitmap, clipped or not yet filling the new box,
    /// until a fresh one arrives; a text/style/locale change must not — a stale bitmap of the
    /// *previous* content is never acceptable as "current" even briefly, so the caller clears
    /// it immediately instead of waiting for the next raster to land. This method is how a
    /// caller tells the two cases apart before deciding whether to clear.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func hasEqualContent(to other: DisplayKey) -> Bool {
        contentRevision == other.contentRevision && displayRevision == other.displayRevision
            && environmentRevision == other.environmentRevision
    }
}

/// Everything a `TextRasterizer` needs for one raster pass, captured as a value at schedule
/// time so the job never reads a live `Node` (D49/D58's own pattern, applied here to raster
/// instead of measure). Reuses `TextLayoutInput` verbatim rather than duplicating its fields —
/// a raster pass measures the same document/style/limits `TextRenderer.measure` did, just
/// against the box the solver actually settled on.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none — `Sendable` so it
/// crosses into `DisplayScheduler`'s background workers. Errors: none. Cancellation: not
/// applicable.
public struct TextDisplayRequest: Sendable {
    /// The same measurement input `TextRenderer.measure` would have received.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let input: TextLayoutInput

    /// The final content-box size the solver committed for this node — not a constraint to
    /// measure against, but the exact box to fill.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let size: MeasuredSize

    /// The resolved paragraph-level text color — `TextStyle.color` if set, else the caller's
    /// resolved `theme.colors.text` (D55: color resolution happens at render time, not measure
    /// time, so it is not part of `TextLayoutInput`).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let resolvedColor: ThemeColor

    /// The host's pixel scale to rasterize at.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scale: Double

    /// Creates a display request, clamping an invalid `scale` to `1`.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        input: TextLayoutInput,
        size: MeasuredSize,
        resolvedColor: ThemeColor,
        scale: Double
    ) {
        self.input = input
        self.size = size
        self.resolvedColor = resolvedColor
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}
