/// A color in sRGB, components from 0 to 1.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Color: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var red: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var green: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var blue: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var alpha: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let black = Color(red: 0, green: 0, blue: 0)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let white = Color(red: 1, green: 1, blue: 1)
}

/// How a node's box looks. Changing it redraws the node without laying anything out.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Appearance: Sendable, Hashable {
    /// Fill of the box; `nil` for none.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var background: Color?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var cornerRadius: Double = 0

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var borderWidth: Double = 0

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var borderColor: Color?

    /// From 0 (invisible) to 1.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var opacity: Double = 1

    /// Subnodes are cut to the box (and its corner radius).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var clipsContent = false

    /// Size of the drawn box relative to its frame, around its center: 1.1 is a tenth
    /// bigger. Layout, taps and focus see the frame, not the scaled box.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var scale: Double = 1

    /// A shadow under the box; `nil` for none.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var shadow: Shadow?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}
}

/// A shadow cast by a node's box.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Shadow: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var color: Color
    /// From 0 to 1.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var opacity: Double
    /// Blur radius in points.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var radius: Double
    /// Offset in points, rightward.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var x: Double
    /// Offset in points, downward.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var y: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        color: Color = .black,
        opacity: Double = 0.3,
        radius: Double = 12,
        x: Double = 0,
        y: Double = 8
    ) {
        self.color = color
        self.opacity = opacity
        self.radius = radius
        self.x = x
        self.y = y
    }
}
