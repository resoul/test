/// Measures a leaf node's content against a real constraint from inside the solver (D49),
/// instead of the single fixed value `Node.layoutContentMetrics(for:)` bakes into a snapshot
/// at capture time. A future `TextNode` (T04) is the first real implementer — CoreText
/// wrapping depends on the width the solver actually resolved, not the width available when
/// the snapshot was captured (§3.3 of implementation-plan-4.md, the W04 mine).
///
/// Ownership: not applicable — implementers are typically small value types or references
/// owned by whoever built the `LayoutContentMetrics` that carries them; the solver only
/// borrows one for the duration of one `measure(_:context:)` call. Isolation: none — Sendable
/// so the solver can call it from background work. Errors: `measure(_:context:)` throws
/// `LayoutCancellationError.cancelled` when `context` reports cancellation; it does not throw
/// for a measurement it merely dislikes (an unmeasurable input still returns some metrics).
/// Cancellation: implementers check `context.checkCancellation()` at least once per line for
/// multi-line content (D58) — a single call has no smaller unit to check between.
public protocol ContentMeasurer: Sendable {
    /// Stable identity for this measurer, for `LayoutContentMetrics`'s `Hashable`/`Equatable`
    /// and the solver's measurement cache key (D49). Two `ContentMeasurer` values are
    /// considered the same measurer exactly when both `identity` and `revision` match — a
    /// type that manufactures a new `identity` on every snapshot breaks the cache contract
    /// (every constraint then misses) rather than merely slowing it down.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    var identity: ObjectIdentifier { get }

    /// Advances whenever this measurer's future results for the *same* constraint would
    /// differ from its past ones (the content or style it measures changed) — the other half
    /// of the cache key alongside `identity`. Equal `(identity, revision)` pairs must mean
    /// equal `measure(_:context:)` results for equal constraints (D49); this is a correctness
    /// requirement of the cache, not an optimization hint.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    var revision: UInt64 { get }

    /// Computes content metrics for `constraint`, the actual space the solver resolved this
    /// leaf's content area to at this point in the pass — not the width available when the
    /// enclosing snapshot was captured.
    ///
    /// Ownership: the result is a value, owned by the caller. Isolation: none — called from
    /// background solver work; implementers must be safe to call from any thread the solver
    /// runs on. Errors: throws `LayoutCancellationError.cancelled` if `context` reports
    /// cancellation before or during the measurement. Cancellation: checked cooperatively
    /// inside multi-unit content (D58); a cancelled call must not return a partial result.
    func measure(_ constraint: SizeConstraint, context: LayoutContext) throws
        -> LayoutContentMetrics
}
