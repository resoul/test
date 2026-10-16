import LayoutCore

/// Light or dark.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ColorScheme: Sendable, Hashable {
    case light
    case dark
}

/// How the interface is shown: what the system (or the app, for a part of it) asks for.
/// The theme gives the values; the conditions choose among them. The adapters fill them in
/// from the system's settings.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct DisplayConditions: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var colorScheme: ColorScheme
    /// More contrast between colors (Increase Contrast).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var highContrast: Bool
    /// How much larger than standard the reader wants text: 1 is the standard size.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var textScale: Double
    /// Less motion on the screen (Reduce Motion).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var reducesMotion: Bool

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        colorScheme: ColorScheme = .light,
        highContrast: Bool = false,
        textScale: Double = 1,
        reducesMotion: Bool = false
    ) {
        self.colorScheme = colorScheme
        self.highContrast = highContrast
        self.textScale = textScale
        self.reducesMotion = reducesMotion
    }

    /// Light, standard contrast, standard text, full motion.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = DisplayConditions()
}

/// A theme's values for the conditions the interface is shown in: the colors chosen, the
/// fonts at the reader's text size, motion off where it is reduced.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ResolvedTheme: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let theme: Theme
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let conditions: DisplayConditions

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(theme: Theme, conditions: DisplayConditions) {
        self.theme = theme
        self.conditions = conditions
    }

    /// The color for `role` in these conditions.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func color(_ role: ColorRole) -> Color {
        theme.palette[role].resolved(for: conditions)
    }

    /// The font for `role` at the reader's text size.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func font(_ role: FontRole) -> ThemeFont {
        theme.typography[role].scaled(by: conditions.textScale)
    }

    /// The corner radius for `role`, in points.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func radius(_ role: RadiusRole) -> Double {
        theme.radii[role]
    }

    /// The move for `role`, or `nil` where motion is reduced: the change then shows at once.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func motion(_ role: MotionRole) -> Motion? {
        conditions.reducesMotion ? nil : theme.motion[role]
    }

    /// The points of a spacing step, or of `spacing` itself.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func points(_ spacing: Spacing) -> Double {
        theme.spacing.points(spacing)
    }

    /// The points of a named breakpoint, or of `width` itself.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func points(_ width: BreakpointWidth) -> Double {
        theme.breakpoints.points(width)
    }
}

/// A change of the theme for a part of the interface: its color scheme, its contrast, and
/// any values of the theme. What it does not change comes from around it — also when that
/// changes later.
///
///     card.themeOverride = ThemeOverride(colorScheme: .dark)
///     banner.themeOverride = ThemeOverride { $0.palette.accent = ThemeColor(.orange) }
///
/// Ownership: value holding the closure. Isolation: none. Errors: none. Cancellation: not
/// applicable.
public struct ThemeOverride: Sendable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var colorScheme: ColorScheme?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var highContrast: Bool?
    /// Changes the theme from around; `nil` keeps it.
    ///
    /// Ownership: value holding the closure. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var changes: (@Sendable (inout Theme) -> Void)?

    /// Ownership: value holding `changes`. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        colorScheme: ColorScheme? = nil,
        highContrast: Bool? = nil,
        changes: (@Sendable (inout Theme) -> Void)? = nil
    ) {
        self.colorScheme = colorScheme
        self.highContrast = highContrast
        self.changes = changes
    }

    /// `theme` in `conditions` from around, changed by this override.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func applied(to theme: ResolvedTheme) -> ResolvedTheme {
        var values = theme.theme
        changes?(&values)
        var conditions = theme.conditions
        if let colorScheme {
            conditions.colorScheme = colorScheme
        }
        if let highContrast {
            conditions.highContrast = highContrast
        }
        return ResolvedTheme(theme: values, conditions: conditions)
    }
}

/// A view that lays out its subviews with a spec, and takes its spacing steps and
/// breakpoints from a theme it is given.
///
///     final class ProfileView: UIView, ThemedLayout {
///         var layoutTheme = Theme.standard
///     }
///
/// Ownership: the provider owns the elements its spec mentions. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public protocol ThemedLayout: LayoutSpecProviding {
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    var layoutTheme: Theme { get }
}

extension ThemedLayout {
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public var layoutSpacing: SpacingScale { layoutTheme.spacing }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public var layoutBreakpoints: BreakpointScale { layoutTheme.breakpoints }
}
