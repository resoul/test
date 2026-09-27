import LayoutCore
import Testing

@testable import ThemeCore

private let red = Color(red: 1, green: 0, blue: 0)
private let darkRed = Color(red: 0.5, green: 0, blue: 0)
private let pink = Color(red: 1, green: 0.5, blue: 0.5)

@Test
func aThemeColorIsChosenForTheSchemeAndTheContrast() {
    let color = ThemeColor(light: red, dark: darkRed, lightHighContrast: pink)

    #expect(color.resolved(for: DisplayConditions()) == red)
    #expect(color.resolved(for: DisplayConditions(colorScheme: .dark)) == darkRed)
    #expect(color.resolved(for: DisplayConditions(highContrast: true)) == pink)
    // Without a value for more contrast, the plain one serves.
    #expect(
        color.resolved(for: DisplayConditions(colorScheme: .dark, highContrast: true)) == darkRed
    )
}

@Test
func aResolvedThemeScalesItsTextAndDropsMotionWhereItIsReduced() {
    let conditions = DisplayConditions(textScale: 1.5, reducesMotion: true)
    let theme = Theme.standard.resolved(for: conditions)

    #expect(theme.font(.body).size == 17 * 1.5)
    #expect(theme.font(.button).weight == .semibold)
    #expect(theme.motion(.standard) == nil)
    #expect(Theme.standard.resolved(for: .standard).motion(.standard)?.duration == 0.25)
    #expect(theme.radius(.large) == 12)
    #expect(theme.points(Spacing.s5) == 16)
    #expect(theme.points(BreakpointWidth.md) == 600)
    #expect(theme.color(.surface) == .white)
    #expect(
        Theme.standard.resolved(for: DisplayConditions(colorScheme: .dark)).color(.primaryText)
            == .white
    )
}

@Test
func everyRoleReadsAndWritesItsOwnValue() {
    var palette = Palette.standard
    for role in ColorRole.allCases {
        palette[role] = ThemeColor(red)
        #expect(palette[role] == ThemeColor(red))
    }
    var typography = Typography.standard
    for (index, role) in FontRole.allCases.enumerated() {
        typography[role] = ThemeFont(size: Double(index))
    }
    #expect(FontRole.allCases.enumerated().allSatisfy { typography[$1].size == Double($0) })
    var radii = Radii.standard
    for (index, role) in RadiusRole.allCases.enumerated() {
        radii[role] = Double(index)
    }
    #expect(RadiusRole.allCases.enumerated().allSatisfy { radii[$1] == Double($0) })
    var motion = MotionSet.standard
    for (index, role) in MotionRole.allCases.enumerated() {
        motion[role] = Motion(duration: Double(index), curve: .linear)
    }
    #expect(MotionRole.allCases.enumerated().allSatisfy { motion[$1].duration == Double($0) })
}

@Test
func anOverrideChangesWhatItSaysAndKeepsWhatComesFromAround() {
    let override = ThemeOverride(colorScheme: .dark) { $0.palette.accent = ThemeColor(red) }
    var around = Theme.standard
    around.radii.large = 20

    let theme = override.applied(to: around.resolved(for: .standard))

    #expect(theme.color(.accent) == red)
    #expect(theme.conditions.colorScheme == .dark)
    #expect(theme.color(.surface) == Palette.standard.surface.dark)
    // A change around after it was made still reaches through it.
    #expect(theme.radius(.large) == 20)
    #expect(theme.conditions.textScale == 1)
}

@Test
func aColorMixesTowardAnother() {
    let mixed = Color.white.mixed(with: .black, amount: 0.25)

    #expect(mixed == Color(red: 0.75, green: 0.75, blue: 0.75))
    #expect(Color.white.mixed(with: .black, amount: 2) == .black)
    #expect(Color.white.mixed(with: .black, amount: -1) == .white)
}

@Test
func aFontScalesItsLineSpacingWithItsSize() {
    let font = ThemeFont(size: 10, lineSpacing: 2).scaled(by: 2)

    #expect(font.size == 20)
    #expect(font.lineSpacing == 4)
}

@Test
func anOverrideCanAskForMoreContrast() {
    let theme = ThemeOverride(highContrast: true).applied(
        to: Theme.standard.resolved(for: .standard)
    )

    #expect(theme.conditions.highContrast)
    #expect(theme.color(.accent) == Palette.standard.accent.lightHighContrast)
}
