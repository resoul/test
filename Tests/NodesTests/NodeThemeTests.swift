import LayoutCore
import StateCore
import Testing
import ThemeCore

@testable import Nodes

/// A box that paints itself in the theme's surface, and remembers each color it painted.
@MainActor
private final class Swatch: Node {
    var painted: [Color] = []

    override func update() {
        let color = theme.color(.surface)
        appearance.background = color
        painted.append(color)
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 10, height: 10)) }
}

/// A column holding a swatch, and — when `showsLate` — a second one made after the first
/// layout.
@MainActor
private final class Column: Node {
    let swatch = Swatch()
    lazy var late = Swatch()
    let showsLate = State(false)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            swatch
            if showsLate.value { late }
        }
    }
}

@MainActor
private func host(_ root: Node) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: 100, height: 100))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func aNodeFollowsTheThemeAndTheConditionsOfItsHost() {
    let column = Column()
    let host = host(column)
    defer { host.detach() }
    #expect(column.swatch.appearance.background == .white)

    host.conditions.colorScheme = .dark
    host.layoutIfNeeded()
    #expect(column.swatch.appearance.background == Palette.standard.surface.dark)

    var theme = Theme.standard
    theme.palette.surface = ThemeColor(Color(red: 1, green: 0, blue: 0))
    host.theme = theme
    host.layoutIfNeeded()
    #expect(column.swatch.appearance.background == Color(red: 1, green: 0, blue: 0))
}

@Test @MainActor
func anOverrideChangesItsPartOfTheTreeAndTheRestStillFollowsTheHost() {
    let column = Column()
    let host = host(column)
    defer { host.detach() }

    column.themeOverride = ThemeOverride(colorScheme: .dark)
    host.layoutIfNeeded()
    #expect(column.swatch.appearance.background == Palette.standard.surface.dark)
    #expect(column.swatch.theme.conditions.textScale == 1)

    // A change of the host's theme reaches through the override.
    var theme = Theme.standard
    theme.palette.surface = ThemeColor(light: .white, dark: Color(red: 0, green: 0, blue: 1))
    host.theme = theme
    host.layoutIfNeeded()
    #expect(column.swatch.appearance.background == Color(red: 0, green: 0, blue: 1))

    column.themeOverride = nil
    host.layoutIfNeeded()
    #expect(column.swatch.appearance.background == .white)
}

@Test @MainActor
func aNodeMadeUnderAnOverrideTakesItOnceItIsInTheTree() {
    let column = Column()
    let host = host(column)
    defer { host.detach() }
    column.themeOverride = ThemeOverride(colorScheme: .dark)
    host.layoutIfNeeded()

    // Made and first updated before it is in the tree, where the override is not seen.
    column.showsLate.value = true
    host.layoutIfNeeded()
    host.layoutIfNeeded()

    #expect(column.late.appearance.background == Palette.standard.surface.dark)
    #expect(column.late.painted.first == .white)
}

@Test @MainActor
func theThemesSpacingLaysTheTreeOutAgain() {
    let first = Swatch()
    let second = Swatch()
    let root = Pair(first, second)
    let host = host(root)
    defer { host.detach() }
    #expect(second.frame.origin.y == 10 + 16)

    var theme = Theme.standard
    theme.spacing = SpacingScale(steps: [1, 2, 3, 4, 5, 6, 7, 8, 9])
    host.theme = theme
    host.layoutIfNeeded()

    #expect(second.frame.origin.y == 10 + 5)
    #expect(host.spacing == theme.spacing)
}

/// Two nodes a spacing step `.s5` apart.
@MainActor
private final class Pair: Node {
    let first: Node
    let second: Node

    init(_ first: Node, _ second: Node) {
        self.first = first
        self.second = second
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            first
            second
        }
        .gap(.s5)
    }
}

@Test @MainActor
func aMoveOfTheThemeBecomesAnAnimationUnlessMotionIsReduced() {
    let theme = Theme.standard.resolved(for: .standard)

    #expect(theme.animation(.standard) == .easeInOut(duration: 0.25))
    #expect(theme.animation(.quick) == .easeOut(duration: 0.15))
    #expect(theme.animation(.transition) == .spring(response: 0.4, dampingRatio: 1))
    #expect(Animation(Motion(duration: 1, curve: .linear)) == .linear(duration: 1))
    #expect(Animation(Motion(duration: 1, curve: .easeIn)) == .easeIn(duration: 1))
    let reduced = Theme.standard.resolved(for: DisplayConditions(reducesMotion: true))
    #expect(reduced.animation(.standard) == nil)
}

@Test @MainActor
func aThemeChangedInsideAnAnimationIsDrawnWithItAndTheSystemsChangeWithout() {
    let column = Column()
    let host = host(column)
    defer { host.detach() }
    host.didRender()

    var theme = Theme.standard
    theme.palette.surface = ThemeColor(Color(red: 1, green: 0, blue: 0))
    withAnimation(.easeInOut(duration: 0.5)) {
        host.theme = theme
    }
    host.layoutIfNeeded()
    #expect(column.swatch.appearance.background == Color(red: 1, green: 0, blue: 0))
    #expect(host.renderAnimation == .easeInOut(duration: 0.5))
    host.didRender()

    // What the adapters do when the system switches.
    withAnimation(nil) {
        host.conditions.colorScheme = .dark
    }
    host.layoutIfNeeded()
    #expect(host.renderAnimation == nil)
}

@Test @MainActor
func anOverrideInsideAnotherHasTheLastWordAndKeepsTheRest() {
    let column = Column()
    let host = host(column)
    defer { host.detach() }
    let red = Color(red: 1, green: 0, blue: 0)
    let blue = Color(red: 0, green: 0, blue: 1)

    column.themeOverride = ThemeOverride(colorScheme: .dark) {
        $0.palette.surface = ThemeColor(red)
        $0.radii.large = 30
    }
    column.swatch.themeOverride = ThemeOverride(colorScheme: .light) {
        $0.palette.surface = ThemeColor(light: blue, dark: red)
    }
    host.layoutIfNeeded()

    #expect(column.swatch.appearance.background == blue)
    #expect(column.swatch.theme.radius(.large) == 30)
    #expect(column.theme.color(.surface) == red)
}
