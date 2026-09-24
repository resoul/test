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

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}
}
