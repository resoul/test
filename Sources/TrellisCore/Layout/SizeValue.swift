/// A finite, non-negative size expressed in points, a parent fraction, or intrinsic size.
///
/// `.points` is an absolute length. `.fraction` is relative to a parent dimension that may
/// not be known yet — `resolved(parent:)` returns `nil` rather than guessing when the parent
/// is unspecified, matching D03's constraint-free stage-1 contract: a fraction never invents
/// a parent size that layout has not actually determined. `.auto` always resolves to `nil`,
/// deferring to intrinsic or default sizing decided elsewhere.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// associated values resolve to `nil`. Cancellation: not applicable.
public enum SizeValue: Sendable, Hashable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    case points(Double)
    case fraction(Double)
    case auto

    /// Creates an absolute point size from an integer literal.
    ///
    /// Ownership: the value is owned by the caller. Isolation: none. Errors: invalid point
    /// values remain representable and resolve to `nil`. Cancellation: not applicable.
    public init(integerLiteral value: Int) {
        self = .points(Double(value))
    }

    /// Creates an absolute point size from a floating-point literal.
    ///
    /// A literal always means points; fractions remain explicit as `.fraction(...)`.
    ///
    /// Ownership: the value is owned by the caller. Isolation: none. Errors: invalid point
    /// values remain representable and resolve to `nil`. Cancellation: not applicable.
    public init(floatLiteral value: Double) {
        self = .points(value)
    }

    /// Resolves the value against an optional parent dimension.
    ///
    /// `.fraction` without a known, finite, non-negative `parent` returns `nil` — an
    /// unspecified parent size is not an error, it is the normal state before the first
    /// layout pass measures one.
    ///
    /// Ownership: the returned scalar is owned by the caller. Isolation: none. Errors: invalid
    /// values and fractions without a parent return `nil`. Cancellation: not applicable.
    public func resolved(parent: Double?) -> Double? {
        switch self {
        case let .points(value):
            return value.isFinite && value >= 0 ? value : nil
        case let .fraction(value):
            guard value.isFinite, value >= 0, value <= 1, let parent, parent.isFinite, parent >= 0
            else {
                return nil
            }
            return parent * value
        case .auto:
            return nil
        }
    }
}
