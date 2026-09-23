/// Logical edge insets — `leading`/`trailing`, not `left`/`right` — that resolve to physical
/// edges only once a `LayoutDirection` is known.
///
/// Values are authored once, independent of direction; `resolved(for:)` is the single place
/// leading/trailing turns into left/right, so that decision is never duplicated or guessed
/// at another call site.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// values are clamped to zero. Cancellation: not applicable.
public struct DirectionalEdgeInsets: Sendable, Hashable {
    /// Non-negative top inset, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let top: Double

    /// Non-negative leading inset — left in LTR, right in RTL — finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let leading: Double

    /// Non-negative bottom inset, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bottom: Double

    /// Non-negative trailing inset — right in LTR, left in RTL — finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let trailing: Double

    /// Creates logical edge insets, clamping negative and non-finite values to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = Self.sanitize(top)
        self.leading = Self.sanitize(leading)
        self.bottom = Self.sanitize(bottom)
        self.trailing = Self.sanitize(trailing)
    }

    /// Resolves logical edges without guessing a direction at construction time.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func resolved(for direction: LayoutDirection) -> PhysicalEdgeInsets {
        switch direction {
        case .leftToRight:
            return PhysicalEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing)
        case .rightToLeft:
            return PhysicalEdgeInsets(top: top, left: trailing, bottom: bottom, right: leading)
        }
    }

    private static func sanitize(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}

/// Physical edge insets — `left`/`right` — used only after direction resolution.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct PhysicalEdgeInsets: Sendable, Hashable {
    /// Non-negative top inset, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let top: Double

    /// Non-negative left inset, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let left: Double

    /// Non-negative bottom inset, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bottom: Double

    /// Non-negative right inset, finite by construction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let right: Double

    /// Creates physical edge insets, clamping negative and non-finite values to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = max(0, top.isFinite ? top : 0)
        self.left = max(0, left.isFinite ? left : 0)
        self.bottom = max(0, bottom.isFinite ? bottom : 0)
        self.right = max(0, right.isFinite ? right : 0)
    }
}

/// Logical, optional absolute-position offsets, resolved to physical edges during a layout pass.
///
/// Each edge is optional because an absolutely positioned node may pin only some edges; an
/// unset edge is `nil`, not zero — zero and "not specified" are different intents here.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// values become `nil`. Cancellation: not applicable.
public struct DirectionalEdgeOffsets: Sendable, Hashable {
    /// Top offset, or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let top: Double?

    /// Leading offset — left in LTR, right in RTL — or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let leading: Double?

    /// Bottom offset, or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bottom: Double?

    /// Trailing offset — right in LTR, left in RTL — or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let trailing: Double?

    /// Creates logical offsets; non-finite values become `nil` rather than a fabricated zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: non-finite
    /// values become `nil`. Cancellation: not applicable.
    public init(
        top: Double? = nil,
        leading: Double? = nil,
        bottom: Double? = nil,
        trailing: Double? = nil
    ) {
        self.top = Self.sanitize(top)
        self.leading = Self.sanitize(leading)
        self.bottom = Self.sanitize(bottom)
        self.trailing = Self.sanitize(trailing)
    }

    /// Resolves logical offsets using the supplied direction.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func resolved(for direction: LayoutDirection) -> PhysicalEdgeOffsets {
        switch direction {
        case .leftToRight:
            return PhysicalEdgeOffsets(top: top, left: leading, bottom: bottom, right: trailing)
        case .rightToLeft:
            return PhysicalEdgeOffsets(top: top, left: trailing, bottom: bottom, right: leading)
        }
    }

    private static func sanitize(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

/// Physical, optional absolute-position offsets used only after direction resolution.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct PhysicalEdgeOffsets: Sendable, Hashable {
    /// Top offset, or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let top: Double?

    /// Left offset, or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let left: Double?

    /// Bottom offset, or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let bottom: Double?

    /// Right offset, or `nil` if this edge is not pinned.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let right: Double?

    /// Creates physical optional offsets.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(top: Double?, left: Double?, bottom: Double?, right: Double?) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}
