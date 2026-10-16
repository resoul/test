import LayoutCore

/// The named values an interface is built from — colors, text, corner radii, motion,
/// spacing and breakpoints — for every way it is shown: light and dark, with more contrast,
/// with larger text. `standard` is the theme a tree has by default; an app makes its own by
/// changing it.
///
///     var theme = Theme.standard
///     theme.palette.accent = ThemeColor(light: brand, dark: brandOnDark)
///     host.theme = theme
///
/// The values are descriptions: a color is chosen for the conditions it is shown in when
/// the theme is resolved (`resolved(for:)`), and fonts and animations are made from them by
/// the renderer and the adapters.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Theme: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var palette: Palette
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var typography: Typography
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var radii: Radii
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var motion: MotionSet
    /// The points of the spacing steps `.s1` … `.s9`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var spacing: SpacingScale
    /// The points of the named breakpoints `.sm` … `.xxl`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var breakpoints: BreakpointScale

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        palette: Palette = .standard,
        typography: Typography = .standard,
        radii: Radii = .standard,
        motion: MotionSet = .standard,
        spacing: SpacingScale = .standard,
        breakpoints: BreakpointScale = .standard
    ) {
        self.palette = palette
        self.typography = typography
        self.radii = radii
        self.motion = motion
        self.spacing = spacing
        self.breakpoints = breakpoints
    }

    /// The library's theme.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = Theme()

    /// The theme's values for `conditions`: colors for the color scheme and contrast, text
    /// scaled, motion off where it is reduced.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func resolved(for conditions: DisplayConditions) -> ResolvedTheme {
        ResolvedTheme(theme: self, conditions: conditions)
    }
}

// MARK: - Colors

/// What a color of the theme is for.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ColorRole: Sendable, Hashable, CaseIterable {
    /// Behind everything on the screen.
    case background
    /// A card, a list, a panel over the background.
    case surface
    /// Text and icons that matter most.
    case primaryText
    /// Text that explains or adds detail.
    case secondaryText
    /// What can be pressed, and what is chosen.
    case accent
    /// Text and icons on the accent.
    case onAccent
    /// Lines between items.
    case separator
    /// An action that removes or destroys.
    case destructive
}

/// A color of the theme for each way it is shown: light, dark, and each with more contrast.
/// Without a contrast value, the plain one serves.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ThemeColor: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var light: Color
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var dark: Color
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var lightHighContrast: Color?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var darkHighContrast: Color?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        light: Color,
        dark: Color,
        lightHighContrast: Color? = nil,
        darkHighContrast: Color? = nil
    ) {
        self.light = light
        self.dark = dark
        self.lightHighContrast = lightHighContrast
        self.darkHighContrast = darkHighContrast
    }

    /// The same color whatever the conditions.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ color: Color) {
        self.init(light: color, dark: color)
    }

    /// The color for `conditions`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func resolved(for conditions: DisplayConditions) -> Color {
        switch (conditions.colorScheme, conditions.highContrast) {
        case (.light, false): light
        case (.light, true): lightHighContrast ?? light
        case (.dark, false): dark
        case (.dark, true): darkHighContrast ?? dark
        }
    }
}

/// The theme's colors, one for each role.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Palette: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var background: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var surface: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var primaryText: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var secondaryText: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var accent: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var onAccent: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var separator: ThemeColor
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var destructive: ThemeColor

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        background: ThemeColor,
        surface: ThemeColor,
        primaryText: ThemeColor,
        secondaryText: ThemeColor,
        accent: ThemeColor,
        onAccent: ThemeColor,
        separator: ThemeColor,
        destructive: ThemeColor
    ) {
        self.background = background
        self.surface = surface
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.accent = accent
        self.onAccent = onAccent
        self.separator = separator
        self.destructive = destructive
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public subscript(role: ColorRole) -> ThemeColor {
        get {
            switch role {
            case .background: background
            case .surface: surface
            case .primaryText: primaryText
            case .secondaryText: secondaryText
            case .accent: accent
            case .onAccent: onAccent
            case .separator: separator
            case .destructive: destructive
            }
        }
        set {
            switch role {
            case .background: background = newValue
            case .surface: surface = newValue
            case .primaryText: primaryText = newValue
            case .secondaryText: secondaryText = newValue
            case .accent: accent = newValue
            case .onAccent: onAccent = newValue
            case .separator: separator = newValue
            case .destructive: destructive = newValue
            }
        }
    }

    /// Light gray and white in light, black and near-black in dark; a blue accent.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = Palette(
        background: ThemeColor(
            light: Color(red: 0.95, green: 0.95, blue: 0.97),
            dark: Color(red: 0, green: 0, blue: 0)
        ),
        surface: ThemeColor(
            light: .white,
            dark: Color(red: 0.11, green: 0.11, blue: 0.12),
            darkHighContrast: Color(red: 0.17, green: 0.17, blue: 0.18)
        ),
        primaryText: ThemeColor(
            light: Color(red: 0.11, green: 0.12, blue: 0.14),
            dark: .white,
            lightHighContrast: .black
        ),
        secondaryText: ThemeColor(
            light: Color(red: 0.45, green: 0.47, blue: 0.52),
            dark: Color(red: 0.62, green: 0.63, blue: 0.67),
            lightHighContrast: Color(red: 0.29, green: 0.30, blue: 0.34),
            darkHighContrast: Color(red: 0.80, green: 0.81, blue: 0.84)
        ),
        accent: ThemeColor(
            light: Color(red: 0, green: 0.48, blue: 1),
            dark: Color(red: 0.04, green: 0.52, blue: 1),
            lightHighContrast: Color(red: 0, green: 0.25, blue: 0.87),
            darkHighContrast: Color(red: 0.25, green: 0.61, blue: 1)
        ),
        onAccent: ThemeColor(.white),
        separator: ThemeColor(
            light: Color(red: 0.85, green: 0.86, blue: 0.88),
            dark: Color(red: 0.23, green: 0.23, blue: 0.25),
            lightHighContrast: Color(red: 0.62, green: 0.63, blue: 0.66),
            darkHighContrast: Color(red: 0.42, green: 0.42, blue: 0.45)
        ),
        destructive: ThemeColor(
            light: Color(red: 0.92, green: 0.26, blue: 0.24),
            dark: Color(red: 1, green: 0.27, blue: 0.23),
            lightHighContrast: Color(red: 0.78, green: 0.10, blue: 0.10),
            darkHighContrast: Color(red: 1, green: 0.41, blue: 0.38)
        )
    )
}

// MARK: - Text

/// Stroke weight of a font.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FontWeight: Sendable, Hashable {
    case regular
    case medium
    case semibold
    case bold
}

/// A font of the theme, as a description: the renderer and the adapters make the platform's
/// font from it.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ThemeFont: Sendable, Hashable {
    /// A font by its PostScript name; `nil` for the system font in `weight`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var name: String?
    /// Points, at the standard text size.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var size: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var weight: FontWeight
    /// Extra space between lines, in points at the standard text size.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var lineSpacing: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        name: String? = nil,
        size: Double,
        weight: FontWeight = .regular,
        lineSpacing: Double = 0
    ) {
        self.name = name
        self.size = size
        self.weight = weight
        self.lineSpacing = lineSpacing
    }

    /// The font at `scale` times its size — the reader's text size.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public func scaled(by scale: Double) -> ThemeFont {
        var font = self
        font.size = size * scale
        font.lineSpacing = lineSpacing * scale
        return font
    }
}

/// What a font of the theme is for.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FontRole: Sendable, Hashable, CaseIterable {
    /// The title of a screen.
    case largeTitle
    /// The title of a section or a card.
    case title
    /// Running text.
    case body
    /// Small text under or beside something.
    case caption
    /// The title of a button.
    case button
}

/// The theme's fonts, one for each role.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Typography: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var largeTitle: ThemeFont
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var title: ThemeFont
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var body: ThemeFont
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var caption: ThemeFont
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var button: ThemeFont

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        largeTitle: ThemeFont,
        title: ThemeFont,
        body: ThemeFont,
        caption: ThemeFont,
        button: ThemeFont
    ) {
        self.largeTitle = largeTitle
        self.title = title
        self.body = body
        self.caption = caption
        self.button = button
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public subscript(role: FontRole) -> ThemeFont {
        get {
            switch role {
            case .largeTitle: largeTitle
            case .title: title
            case .body: body
            case .caption: caption
            case .button: button
            }
        }
        set {
            switch role {
            case .largeTitle: largeTitle = newValue
            case .title: title = newValue
            case .body: body = newValue
            case .caption: caption = newValue
            case .button: button = newValue
            }
        }
    }

    /// The system font: 34 bold, 22 bold, 17, 13, 15 semibold.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = Typography(
        largeTitle: ThemeFont(size: 34, weight: .bold),
        title: ThemeFont(size: 22, weight: .bold),
        body: ThemeFont(size: 17),
        caption: ThemeFont(size: 13),
        button: ThemeFont(size: 15, weight: .semibold)
    )
}

// MARK: - Corners

/// What a corner radius of the theme is for.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RadiusRole: Sendable, Hashable, CaseIterable {
    /// Square corners.
    case none
    /// A tag, a small control.
    case small
    /// A button, a field.
    case medium
    /// A card, a panel.
    case large
}

/// The theme's corner radii, in points.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Radii: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var none: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var small: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var medium: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var large: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(none: Double, small: Double, medium: Double, large: Double) {
        self.none = none
        self.small = small
        self.medium = medium
        self.large = large
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public subscript(role: RadiusRole) -> Double {
        get {
            switch role {
            case .none: none
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
        set {
            switch role {
            case .none: none = newValue
            case .small: small = newValue
            case .medium: medium = newValue
            case .large: large = newValue
            }
        }
    }

    /// 0, 4, 8, 12.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = Radii(none: 0, small: 4, medium: 8, large: 12)
}

// MARK: - Motion

/// How a move of the theme goes over time.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum MotionCurve: Sendable, Hashable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// `response` is the seconds one swing would take without damping; `dampingRatio` 1
    /// comes to rest without overshooting.
    case spring(response: Double, dampingRatio: Double)
}

/// A move of the theme: how long, and how it goes. The renderer's animation is made from it.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Motion: Sendable, Hashable {
    /// Seconds; for a spring, `response` sets the pace and this is ignored.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var duration: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var curve: MotionCurve

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(duration: Double, curve: MotionCurve) {
        self.duration = duration
        self.curve = curve
    }
}

/// What a move of the theme is for.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum MotionRole: Sendable, Hashable, CaseIterable {
    /// The answer to a touch: a press, a toggle.
    case quick
    /// A change of what shows.
    case standard
    /// Going from one screen or state to another.
    case transition
}

/// The theme's moves, one for each role.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct MotionSet: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var quick: Motion
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var standard: Motion
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var transition: Motion

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(quick: Motion, standard: Motion, transition: Motion) {
        self.quick = quick
        self.standard = standard
        self.transition = transition
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public subscript(role: MotionRole) -> Motion {
        get {
            switch role {
            case .quick: quick
            case .standard: standard
            case .transition: transition
            }
        }
        set {
            switch role {
            case .quick: quick = newValue
            case .standard: standard = newValue
            case .transition: transition = newValue
            }
        }
    }

    /// 0.15 s easing out, 0.25 s easing in and out, a 0.4 s spring without overshoot.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = MotionSet(
        quick: Motion(duration: 0.15, curve: .easeOut),
        standard: Motion(duration: 0.25, curve: .easeInOut),
        transition: Motion(duration: 0.4, curve: .spring(response: 0.4, dampingRatio: 1))
    )
}
