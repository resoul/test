/// Describes the logical direction used to resolve leading and trailing edges.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum LayoutDirection: Sendable, Hashable {
    case leftToRight
    case rightToLeft
}

/// A point in Trellis's platform-neutral layout coordinate space.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutPoint: Sendable, Hashable {
    /// Horizontal coordinate, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let x: Double

    /// Vertical coordinate, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let y: Double

    /// Creates a point, replacing non-finite coordinates with zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }
}

/// The measured size returned by a layout node.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct MeasuredSize: Sendable, Hashable {
    /// Non-negative width, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let width: Double

    /// Non-negative height, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let height: Double

    /// Creates a non-negative measured size, clamping negative and non-finite inputs to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(width: Double, height: Double) {
        self.width = width.isFinite ? max(0, width) : 0
        self.height = height.isFinite ? max(0, height) : 0
    }
}

/// A rectangle in Trellis's platform-neutral layout coordinate space.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutFrame: Sendable, Hashable {
    /// Top-left corner of the rectangle.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let origin: LayoutPoint

    /// Non-negative width, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let width: Double

    /// Non-negative height, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let height: Double

    /// Creates a non-negative frame, clamping negative and non-finite dimensions to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(origin: LayoutPoint = LayoutPoint(x: 0, y: 0), width: Double, height: Double) {
        self.origin = origin
        self.width = width.isFinite ? max(0, width) : 0
        self.height = height.isFinite ? max(0, height) : 0
    }
}
