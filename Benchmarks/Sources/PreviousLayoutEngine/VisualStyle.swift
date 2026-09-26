/// Immutable border painted around a node's layer bounds.
///
/// Ownership: the value owns copied color and width. Isolation: none. Errors: invalid widths
/// normalize to zero. Cancellation: not applicable.
public struct Border: Sendable, Hashable {
    /// Border color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let color: ThemeColor

    /// Non-negative border width in points.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let width: Double

    /// Creates a normalized border.
    ///
    /// Ownership: the border copies its arguments. Isolation: none. Errors: invalid width becomes
    /// zero. Cancellation: not applicable.
    public init(color: ThemeColor, width: Double) {
        self.color = color
        self.width = width.isFinite ? max(0, width) : 0
    }
}

/// Immutable shadow painted by a node's native layer.
///
/// Ownership: the value owns copied color, metrics, and offset. Isolation: none. Errors: opacity
/// and radius normalize to safe values. Cancellation: not applicable.
public struct Shadow: Sendable, Hashable {
    /// Shadow color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let color: ThemeColor

    /// Shadow opacity in `0...1`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let opacity: Double

    /// Non-negative blur radius.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let radius: Double

    /// Shadow displacement vector in layout coordinates.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let offset: LayoutPoint

    /// Creates a normalized shadow.
    ///
    /// Ownership: the shadow copies its arguments. Isolation: none. Errors: invalid opacity and
    /// radius become zero. Cancellation: not applicable.
    public init(color: ThemeColor, opacity: Double, radius: Double, offset: LayoutPoint) {
        self.color = color
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 0
        self.radius = radius.isFinite ? max(0, radius) : 0
        self.offset = offset
    }
}

/// Paint source supported by the synchronous native-layer path.
///
/// Ownership: the value owns its immutable token. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum Fill: Sendable, Hashable {
    case none
    case color(ThemeColor)
    case theme(ThemeColorRole)
}

/// Semantic color role resolved from the node's environment theme.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum ThemeColorRole: Sendable, Hashable {
    case background
    case surface
    case primary
    case secondary
    case accent
    case text
    case textSecondary
    case border
    case error
    case success
    case warning
}

/// Mutable paint-only presentation properties for a logical node.
///
/// The whole value can be copied, mutated in an `appearance { ... }` closure, and assigned once;
/// no separate Draft type is required.
///
/// Ownership: the value is owned by its caller and copied into render inputs. Isolation: none.
/// Errors: invalid corner radii normalize immediately. Cancellation: not applicable.
public struct VisualStyle: Sendable, Hashable {
    /// Background fill.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var background: Fill = .none

    /// Optional border.
    /// Ownership: returns a value. Isolation: none. Errors: values normalize during construction.
    /// Cancellation: not applicable.
    public var border: Border? = nil

    /// Non-negative corner radius in points.
    /// Ownership: returns a value. Isolation: none. Errors: invalid values become zero.
    /// Cancellation: not applicable.
    public var cornerRadius: Double = 0 {
        didSet { cornerRadius = Self.nonNegative(cornerRadius) }
    }

    /// Optional shadow.
    /// Ownership: returns a value. Isolation: none. Errors: values normalize during construction.
    /// Cancellation: not applicable.
    public var shadow: Shadow? = nil

    /// Creates normalized paint-only presentation properties.
    ///
    /// Ownership: the returned style is owned by the caller. Isolation: none. Errors: invalid
    /// corner radius becomes zero. Cancellation: not applicable.
    public init(
        background: Fill = .none,
        border: Border? = nil,
        cornerRadius: Double = 0,
        shadow: Shadow? = nil
    ) {
        self.background = background
        self.border = border
        self.cornerRadius = Self.nonNegative(cornerRadius)
        self.shadow = shadow
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
