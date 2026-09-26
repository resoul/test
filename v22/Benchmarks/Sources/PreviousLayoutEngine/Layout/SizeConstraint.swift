/// A constraint applied to one layout axis during measurement.
///
/// `.unspecified` means the axis is free — the child may report any size on it, and an
/// unspecified parent size later shows up as `nil` from `SizeValue.resolved(parent:)`, not
/// as a fabricated zero. `.atMost` and `.exact` bound the resolved size on that axis alone.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// numeric payloads are treated as unspecified by `normalized()`. Cancellation: not applicable.
public enum SizeConstraintAxis: Sendable, Hashable {
    case unspecified
    case atMost(Double)
    case exact(Double)

    /// Returns a safe constraint, clamping negative values and ignoring non-finite values.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func normalized() -> Self {
        switch self {
        case .unspecified: return .unspecified
        case let .atMost(value): return value.isFinite && value >= 0 ? .atMost(value) : .unspecified
        case let .exact(value): return value.isFinite && value >= 0 ? .exact(value) : .unspecified
        }
    }

    /// The bound this axis already carries, if any — `.atMost`'s limit or `.exact`'s value.
    /// This is a known *upper bound or fixed value*, not a promise of the final resolved size:
    /// callers narrowing a child's constraint from it should not treat it as final (F03).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var knownValue: Double? {
        switch self {
        case .unspecified: return nil
        case let .atMost(value), let .exact(value): return value
        }
    }
}

/// Independent width and height constraints for a measurement pass.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct SizeConstraint: Sendable, Hashable {
    /// Width axis constraint, already normalized.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let width: SizeConstraintAxis

    /// Height axis constraint, already normalized.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let height: SizeConstraintAxis

    /// Creates width and height constraints, normalizing each axis independently.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(width: SizeConstraintAxis = .unspecified, height: SizeConstraintAxis = .unspecified)
    {
        self.width = width.normalized()
        self.height = height.normalized()
    }
}
