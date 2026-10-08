import Testing

@testable import TrellisCore

@Test
func test_visualStyle_hasDocumentedDefaultsAndSupportsDirectMutation() {
    var appearance = VisualStyle()
    let color = ThemeColor(red: 0.25, green: 0.5, blue: 0.75)

    appearance.background = .color(color)
    appearance.cornerRadius = 12
    appearance.border = Border(color: color, width: 2)
    appearance.shadow = Shadow(
        color: color,
        opacity: 0.5,
        radius: 4,
        offset: LayoutPoint(x: 1, y: 2)
    )

    #expect(appearance.background == .color(color))
    #expect(appearance.cornerRadius == 12)
    #expect(appearance.border?.width == 2)
    #expect(appearance.shadow?.opacity == 0.5)
}

@Test
func test_visualValues_normalizeInvalidNumbers() {
    var appearance = VisualStyle(cornerRadius: .infinity)
    #expect(appearance.cornerRadius == 0)

    appearance.cornerRadius = .nan

    let color = ThemeColor(red: -1, green: 2, blue: .nan, alpha: .infinity)
    let border = Border(color: color, width: -.infinity)
    let shadow = Shadow(
        color: color,
        opacity: .infinity,
        radius: -.infinity,
        offset: LayoutPoint(x: 0, y: 0)
    )

    #expect(appearance.cornerRadius == 0)
    #expect(color == ThemeColor(red: 0, green: 1, blue: 0, alpha: 0))
    #expect(border.width == 0)
    #expect(shadow.opacity == 0)
    #expect(shadow.radius == 0)
}

@Test
func test_themeStoresCompleteSemanticColorSet() {
    let black = ThemeColor(red: 0, green: 0, blue: 0)
    let white = ThemeColor(red: 1, green: 1, blue: 1)
    let colors = ThemeColors(
        background: white,
        surface: white,
        primary: black,
        secondary: black,
        accent: black,
        text: black,
        textSecondary: black,
        border: black,
        error: black,
        success: black,
        warning: black
    )
    let theme = Theme(id: "test", colors: colors)

    #expect(theme.id == "test")
    #expect(theme.colors.background == white)
    #expect(theme.colors.text == black)
}

@Test
func test_visualStyle_normalizationIsIdempotent() {
    var appearance = VisualStyle()
    appearance.cornerRadius = -.infinity

    let normalized = appearance
    appearance.cornerRadius = -.infinity

    #expect(appearance == normalized)
}
