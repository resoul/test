/// Main-axis direction used to arrange a node's children.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum FlexDirection: Sendable, Hashable {
    case row
    case column
    case rowReverse
    case columnReverse
}

/// Line-wrapping behavior for a flex container.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum FlexWrap: Sendable, Hashable {
    case noWrap
    case wrap
    case wrapReverse
}

/// Main-axis distribution for a flex container.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum JustifyContent: Sendable, Hashable {
    case start
    case end
    case center
    case spaceBetween
    case spaceAround
    case spaceEvenly
}

/// Cross-axis distribution for wrapped flex lines.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum AlignContent: Sendable, Hashable {
    case start
    case end
    case center
    case stretch
    case spaceBetween
    case spaceAround
    case spaceEvenly
}

/// Default cross-axis alignment for a container's children.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum AlignItems: Sendable, Hashable {
    case stretch
    case start
    case end
    case center
    case baseline
}

/// Per-node override of its parent's cross-axis alignment.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum AlignSelf: Sendable, Hashable {
    case auto
    case stretch
    case start
    case end
    case center
    case baseline
}

/// Positioning mode used by the layout engine.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum PositionType: Sendable, Hashable {
    case relative
    case absolute
}

/// Clipping and overflow behavior for a node.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum OverflowPolicy: Sendable, Hashable {
    case visible
    case hidden
    case scroll
}

/// Platform-neutral presentation values that affect placement or hit testing.
///
/// Ownership: the value is copied with its layout style. Isolation: none. Errors: invalid opacity
/// is normalized. Cancellation: not applicable.
public struct LayoutVisualProperties: Sendable, Hashable {
    /// Stacking order among siblings.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let zIndex: Int

    /// Overflow behavior applied after layout.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let overflow: OverflowPolicy

    /// Presentation opacity in the closed interval `0...1`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let opacity: Double

    /// Presentation transform around the node frame origin.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let transform: LayoutTransform

    /// Creates normalized platform-neutral presentation values.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: non-finite
    /// opacity becomes one and finite opacity is clamped. Cancellation: not applicable.
    public init(
        zIndex: Int = 0,
        overflow: OverflowPolicy = .visible,
        opacity: Double = 1,
        transform: LayoutTransform = .identity
    ) {
        self.zIndex = zIndex
        self.overflow = overflow
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
        self.transform = transform
    }
}

/// Mutable base layout style authored by a node owner.
///
/// Each property can be assigned directly. Numeric fields whose valid domain is non-negative
/// normalize on every assignment, so reading the style always returns the value the engine will
/// use. A future Arrangement resolver derives a separate effective copy for snapshots and never
/// overwrites this base value (D04).
///
/// Ownership: the style is a value owned by its caller and copied into snapshots. Isolation:
/// none. Errors: invalid flex, gap, and ratio values normalize immediately; invalid dimensions
/// resolve to `nil`. Cancellation: not applicable.
public struct LayoutStyle: Sendable, Hashable {
    /// Main-axis direction for children.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var flexDirection: FlexDirection = .row

    /// Wrapping behavior for flex lines.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var flexWrap: FlexWrap = .noWrap

    /// Distribution along the main axis.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var justifyContent: JustifyContent = .start

    /// Distribution of wrapped lines along the cross axis.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var alignContent: AlignContent = .stretch

    /// Default alignment of children along the cross axis.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var alignItems: AlignItems = .stretch

    /// This node's cross-axis alignment override.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var alignSelf: AlignSelf = .auto

    /// Non-negative flex growth factor.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values become zero.
    /// Cancellation: not applicable.
    public var flexGrow: Double = 0 {
        didSet { flexGrow = Self.nonNegative(flexGrow) }
    }

    /// Non-negative flex shrink factor.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values become zero.
    /// Cancellation: not applicable.
    public var flexShrink: Double = 1 {
        didSet { flexShrink = Self.nonNegative(flexShrink) }
    }

    /// Preferred flex size on the main axis.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var flexBasis: SizeValue = .auto

    /// Preferred width.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var width: SizeValue = .auto

    /// Preferred height.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var height: SizeValue = .auto

    /// Minimum width.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var minWidth: SizeValue = .auto

    /// Maximum width.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var maxWidth: SizeValue = .auto

    /// Minimum height.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var minHeight: SizeValue = .auto

    /// Maximum height.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values resolve to `nil`.
    /// Cancellation: not applicable.
    public var maxHeight: SizeValue = .auto

    /// Positive width-to-height ratio, or `nil` when no ratio is specified.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values become `nil`.
    /// Cancellation: not applicable.
    public var aspectRatio: Double? = nil {
        didSet { aspectRatio = Self.positive(aspectRatio) }
    }

    /// Logical padding inside the node.
    /// Ownership: returns a value. Isolation: none. Errors: values are normalized by the type.
    /// Cancellation: not applicable.
    public var padding = DirectionalEdgeInsets()

    /// Logical margin outside the node.
    /// Ownership: returns a value. Isolation: none. Errors: values are normalized by the type.
    /// Cancellation: not applicable.
    public var margin = DirectionalEdgeInsets()

    /// Non-negative spacing between items on the main axis.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values become zero.
    /// Cancellation: not applicable.
    public var gap: Double = 0 {
        didSet { gap = Self.nonNegative(gap) }
    }

    /// Non-negative spacing between wrapped lines on the cross axis.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values become zero.
    /// Cancellation: not applicable.
    public var crossGap: Double = 0 {
        didSet { crossGap = Self.nonNegative(crossGap) }
    }

    /// Relative or absolute positioning mode.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var positionType: PositionType = .relative

    /// Optional logical offsets used for absolute positioning.
    /// Ownership: returns a value. Isolation: none. Errors: values are normalized by the type.
    /// Cancellation: not applicable.
    public var offsets = DirectionalEdgeOffsets()

    /// Placement and hit-test presentation values carried with layout.
    /// Ownership: returns a value. Isolation: none. Errors: values are normalized by the type.
    /// Cancellation: not applicable.
    public var visual = LayoutVisualProperties()

    /// Creates a mutable layout style with documented defaults.
    ///
    /// Ownership: the returned style is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Measures explicit dimensions under parent dimensions and axis constraints.
    ///
    /// Ownership: the returned measurement is owned by the caller. Isolation: none. Errors:
    /// unresolved or invalid dimensions resolve to zero. Cancellation: not applicable.
    public func measured(
        parentSize: MeasuredSize? = nil,
        constraint: SizeConstraint = SizeConstraint()
    ) -> MeasuredSize {
        var resolvedWidth = width.resolved(parent: parentSize?.width)
        var resolvedHeight = height.resolved(parent: parentSize?.height)

        if resolvedWidth == nil, let aspectRatio, let resolvedHeight {
            resolvedWidth = resolvedHeight * aspectRatio
        }
        if resolvedHeight == nil, let aspectRatio, let resolvedWidth {
            resolvedHeight = resolvedWidth / aspectRatio
        }

        let measuredWidth = apply(
            resolvedWidth ?? 0,
            minimum: minWidth,
            maximum: maxWidth,
            parent: parentSize?.width,
            axis: constraint.width
        )
        let measuredHeight = apply(
            resolvedHeight ?? 0,
            minimum: minHeight,
            maximum: maxHeight,
            parent: parentSize?.height,
            axis: constraint.height
        )

        return MeasuredSize(width: measuredWidth, height: measuredHeight)
    }

    private func apply(
        _ value: Double,
        minimum: SizeValue,
        maximum: SizeValue,
        parent: Double?,
        axis: SizeConstraintAxis
    ) -> Double {
        var result = value
        if let lower = minimum.resolved(parent: parent) { result = max(result, lower) }
        if let upper = maximum.resolved(parent: parent) { result = min(result, upper) }
        switch axis {
        case .unspecified:
            break
        case let .atMost(limit):
            result = min(result, limit)
        case let .exact(exact):
            result = exact
        }

        return result
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
