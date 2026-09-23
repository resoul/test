/// Platform-neutral RGBA color token.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: color
/// channels normalize to `0...1`; non-finite channels become zero. Cancellation: not applicable.
public struct ThemeColor: Sendable, Hashable {
    /// Red channel in `0...1`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let red: Double

    /// Green channel in `0...1`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let green: Double

    /// Blue channel in `0...1`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let blue: Double

    /// Alpha channel in `0...1`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let alpha: Double

    /// Creates a normalized color token.
    ///
    /// Ownership: the returned token is owned by the caller. Isolation: none. Errors: invalid
    /// channels become zero. Cancellation: not applicable.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.channel(red)
        self.green = Self.channel(green)
        self.blue = Self.channel(blue)
        self.alpha = Self.channel(alpha)
    }

    private static func channel(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// Semantic colors needed to resolve theme-backed fills.
///
/// Ownership: the value owns all color tokens. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public struct ThemeColors: Sendable, Hashable {
    /// Background color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let background: ThemeColor
    /// Surface color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let surface: ThemeColor
    /// Primary brand color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let primary: ThemeColor
    /// Secondary brand color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let secondary: ThemeColor
    /// Accent color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let accent: ThemeColor
    /// Primary text color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let text: ThemeColor
    /// Secondary text color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let textSecondary: ThemeColor
    /// Border color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let border: ThemeColor
    /// Error color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let error: ThemeColor
    /// Success color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let success: ThemeColor
    /// Warning color.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let warning: ThemeColor

    /// Creates a complete semantic color set.
    ///
    /// Ownership: the returned value owns copies of every color. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        background: ThemeColor,
        surface: ThemeColor,
        primary: ThemeColor,
        secondary: ThemeColor,
        accent: ThemeColor,
        text: ThemeColor,
        textSecondary: ThemeColor,
        border: ThemeColor,
        error: ThemeColor,
        success: ThemeColor,
        warning: ThemeColor
    ) {
        self.background = background
        self.surface = surface
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.text = text
        self.textSecondary = textSecondary
        self.border = border
        self.error = error
        self.success = success
        self.warning = warning
    }
}

/// Minimal immutable theme snapshot used by theme-backed fills.
///
/// Ownership: the theme owns its identifier and color set. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct Theme: Sendable, Hashable {
    /// Stable application-defined theme identifier.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: String

    /// Semantic colors in this theme.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let colors: ThemeColors

    /// Creates a minimal theme snapshot.
    ///
    /// Ownership: the returned theme owns copied values. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(id: String, colors: ThemeColors) {
        self.id = id
        self.colors = colors
    }

    /// Stable neutral theme used when a node's environment has no explicit theme.
    ///
    /// Ownership: immutable shared value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static let defaultValue = Theme(
        id: "default",
        colors: ThemeColors(
            background: ThemeColor(red: 1, green: 1, blue: 1),
            surface: ThemeColor(red: 0.96, green: 0.96, blue: 0.98),
            primary: ThemeColor(red: 0.1, green: 0.2, blue: 0.8),
            secondary: ThemeColor(red: 0.3, green: 0.3, blue: 0.35),
            accent: ThemeColor(red: 0.2, green: 0.5, blue: 1),
            text: ThemeColor(red: 0, green: 0, blue: 0),
            textSecondary: ThemeColor(red: 0.3, green: 0.3, blue: 0.3),
            border: ThemeColor(red: 0.8, green: 0.8, blue: 0.8),
            error: ThemeColor(red: 0.8, green: 0.1, blue: 0.1),
            success: ThemeColor(red: 0.1, green: 0.6, blue: 0.2),
            warning: ThemeColor(red: 0.8, green: 0.5, blue: 0.1)
        )
    )
}
