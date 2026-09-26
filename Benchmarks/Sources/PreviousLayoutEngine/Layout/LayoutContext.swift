/// Failure thrown when layout math observes cancellation mid-pass.
///
/// Ownership: the value is copied. Isolation: none. Errors: represents cancellation only — it
/// is not a general layout failure. Cancellation: this value *is* the cancellation signal (D09).
public enum LayoutCancellationError: Error, Sendable, Hashable {
    case cancelled
}

/// Sendable execution context threaded through solver math, carrying only cancellation.
///
/// This is not an Arrangement context and not a container holding a `Node` reference (D10):
/// it exists so measure/place passes can check for cancellation without knowing whether they
/// run under a `Task`, a plain synchronous test, or something else entirely. C06 owns this
/// type and its contract; C12 threads it through the math passes; C13 is the first caller
/// that builds one bound to the scheduler's current `Task`.
///
/// Ownership: no owned state beyond an immutable closure. Isolation: none — Sendable so it
/// crosses into background solver work. Errors: `checkCancellation()` throws
/// `LayoutCancellationError.cancelled`. Cancellation: this type *is* the cancellation channel;
/// per D09, a cancelled pass throws instead of returning an empty or partial `LayoutResult`.
public struct LayoutContext: Sendable {
    private let cancellationCheck: @Sendable () -> Bool

    /// A context that never reports cancellation, for synchronous math tests with no `Task`.
    ///
    /// Ownership: shared immutable value. Isolation: none. Errors: none. Cancellation: never.
    public static let noCancellation = LayoutContext(cancellationCheck: { false })

    /// Creates a context backed by an arbitrary cancellation predicate.
    ///
    /// Ownership: the closure is retained. Isolation: none — the closure itself must be safe
    /// to call from background solver work. Errors: none. Cancellation: not applicable.
    public init(cancellationCheck: @escaping @Sendable () -> Bool) {
        self.cancellationCheck = cancellationCheck
    }

    /// A context bound to whichever `Task` calls into the solver, for real scheduler use.
    ///
    /// Ownership: shared factory; the returned value holds no reference to the `Task` itself.
    /// Isolation: none — reads `Task.isCancelled` at each check, not at construction time.
    /// Errors: none. Cancellation: reflects that `Task`'s cancellation state per call.
    public static func currentTask() -> LayoutContext {
        LayoutContext(cancellationCheck: { Task.isCancelled })
    }

    /// Whether the bound predicate currently reports cancellation.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isCancelled: Bool { cancellationCheck() }

    /// Throws if the bound predicate currently reports cancellation.
    ///
    /// Ownership: no owned state. Isolation: none. Errors: throws
    /// `LayoutCancellationError.cancelled`. Cancellation: this is the cooperative checkpoint
    /// solver passes call between units of work (D09) — an empty or partial `LayoutResult`
    /// never encodes cancellation.
    public func checkCancellation() throws {
        if isCancelled { throw LayoutCancellationError.cancelled }
    }
}
