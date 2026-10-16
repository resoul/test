import FlexEngine
import LayoutCore
import ThemeCore

/// A theme of the app: the standard one with its own accent and a roomier spacing scale.
public func appTheme() -> Theme {
    var theme = Theme.standard
    theme.palette.accent = ThemeColor(
        light: Color(red: 0.1, green: 0.4, blue: 0.9),
        dark: Color(red: 0.4, green: 0.6, blue: 1)
    )
    theme.spacing = SpacingScale(steps: [4, 8, 12, 16, 20, 28, 40, 56, 72])
    return theme
}

/// What a screen needs from the theme under the reader's settings: colors for the scheme and
/// contrast, fonts at the reader's text size, motion only when it is not reduced.
public func themedValues(dark: Bool, textScale: Double) -> (
    accent: Color, bodySize: Double, gap: Double
) {
    let conditions = DisplayConditions(colorScheme: dark ? .dark : .light, textScale: textScale)
    let resolved = appTheme().resolved(for: conditions)
    return (resolved.color(.accent), resolved.font(.body).size, resolved.points(.s4))
}

/// The card laid out with the theme's spacing and breakpoints instead of the standard ones.
@MainActor
public func layoutThemedCard(_ card: Card, in rect: LayoutRect) {
    let theme = appTheme()
    card.spec().apply(in: rect, spacing: theme.spacing, breakpoints: theme.breakpoints)
}
