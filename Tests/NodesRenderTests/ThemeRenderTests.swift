#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import Testing
    import ThemeCore

    @testable import NodesRender

    /// A text and a button in a column 300 points wide.
    @MainActor
    private final class Card: Node {
        let body = Text(
            "Some words to read, enough to wrap onto more lines.",
            style: TextStyle(.body)
        )
        let button = Button("Go") {}

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                body
                FlexContainer(.row) { button }
            }
        }
    }

    @MainActor
    private func host(_ root: Node) -> NodeHost {
        let host = NodeHost(root: root, size: LayoutSize(width: 300, height: 400))
        host.layoutIfNeeded()
        return host
    }

    @Test @MainActor
    func textInAFontOfTheThemeGrowsWithTheReadersTextSize() {
        let card = Card()
        let host = host(card)
        defer { host.detach() }
        let height = card.body.frame.size.height

        host.conditions.textScale = 1.5
        host.layoutIfNeeded()

        #expect(card.body.frame.size.height > height * 1.3)
        #expect(card.body.style.role == .body)
    }

    @Test @MainActor
    func textWithoutAColorOfItsOwnTakesTheThemesAndAColorChangeDoesNotLayItOut() {
        let card = Card()
        let host = host(card)
        defer { host.detach() }
        #expect(card.body.shown.color == Palette.standard.primaryText.light)
        let passes = host.passes
        let revision = card.body.drawingRevision

        host.conditions.colorScheme = .dark
        host.layoutIfNeeded()

        // Drawn again in white, without a new layout.
        #expect(card.body.drawingRevision != revision)
        #expect(host.passes == passes)
        #expect(card.body.shown.color == .white)
    }

    @Test @MainActor
    func textWithoutAColorTakesTheThemesColorForItsRole() {
        let note = Text("Note", style: TextStyle(size: 13, colorRole: .secondaryText))
        let host = host(note)
        defer { host.detach() }

        #expect(note.shown.color == Palette.standard.secondaryText.light)
    }

    @Test @MainActor
    func aButtonTakesTheThemesAccentUnlessItHasAFillOfItsOwn() {
        let card = Card()
        let host = host(card)
        defer { host.detach() }
        #expect(card.button.appearance.background == Palette.standard.accent.light)
        #expect(card.button.appearance.cornerRadius == 8)
        #expect(card.button.label.style.color == .white)

        card.themeOverride = ThemeOverride { $0.palette.accent = ThemeColor(.black) }
        host.layoutIfNeeded()
        #expect(card.button.appearance.background == .black)

        card.button.fill = Color(red: 0, green: 1, blue: 0)
        host.layoutIfNeeded()
        #expect(card.button.appearance.background == Color(red: 0, green: 1, blue: 0))
    }

    @Test @MainActor
    func aButtonWithATitleColorOfItsOwnKeepsIt() {
        let button = Button("Go", style: TextStyle(size: 15, color: .black)) {}
        let host = host(button)
        defer { host.detach() }

        host.conditions.colorScheme = .dark
        host.layoutIfNeeded()

        #expect(button.label.style.color == .black)
    }

    private struct Row: Identifiable {
        let id: Int
    }

    @Test @MainActor
    func aTableIsDrawnInTheThemesColorsLightAndDark() throws {
        let labels = NodeCache<Int, Text> { id in Text("Row \(id)") }
        let table = Table<Row> { labels[$0.id] }
        table.sections = [TableSection(id: "all", title: "All", items: (0..<3).map(Row.init))]
        table.trailingActions = { _ in [SwipeAction("Delete", role: .destructive) {}] }
        let host = NodeHost(root: table, size: LayoutSize(width: 320, height: 400))
        host.layoutIfNeeded()
        defer { host.detach() }
        let row = try #require(labels[1].supernode?.supernode as? TableRow)
        #expect(row.cell.appearance.background == .white)
        #expect(row.trailing.first?.appearance.background == Palette.standard.destructive.light)

        host.conditions.colorScheme = .dark
        host.layoutIfNeeded()

        #expect(row.cell.appearance.background == Palette.standard.surface.dark)
        #expect(row.trailing.first?.appearance.background == Palette.standard.destructive.dark)
        #expect(labels[1].style.color == nil)
    }

    @Test @MainActor
    func theSpinnerTakesTheThemesSecondaryTextColorUnlessGivenOne() {
        let spinner = RefreshSpinner()
        let host = host(spinner)
        defer { host.detach() }
        #expect(spinner.shownColor == Palette.standard.secondaryText.light)

        spinner.color = .black
        #expect(spinner.shownColor == .black)
    }
#endif

#if canImport(UIKit)
    import UIKit

    @testable import NodesUIKit
    import LayoutUIKit

    @Test @MainActor
    func aNodeViewTakesTheInterfaceStyleOfItsWindowAndFollowsItsChanges() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = NodeView(root: Node())
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        #expect(view.host.conditions.colorScheme == .light)

        window.overrideUserInterfaceStyle = .dark
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(view.host.conditions.colorScheme == .dark)
        window.isHidden = true
        view.host.detach()
    }

    @Test @MainActor
    func aThemeColorForAPlainViewFollowsTheTraitsItIsDrawnWith() {
        let color = UIColor(ThemeColor(light: .white, dark: .black))
        let dark = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let light = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

        var red: CGFloat = -1
        dark.getRed(&red, green: nil, blue: nil, alpha: nil)
        #expect(red == 0)
        light.getRed(&red, green: nil, blue: nil, alpha: nil)
        #expect(red == 1)
        #expect(UIFont.themed(ThemeFont(size: 20, weight: .bold)).pointSize == 20)
    }
#endif

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    @testable import NodesAppKit
    import LayoutAppKit

    @Test @MainActor
    func aNodeViewOnTheMacTakesTheAppearanceItIsShownIn() {
        let view = NodeNSView(root: Node())
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layout()

        #expect(view.host.conditions.colorScheme == .dark)

        view.appearance = NSAppearance(named: .aqua)
        view.layout()
        #expect(view.host.conditions.colorScheme == .light)
        view.host.detach()
    }

    @Test @MainActor
    func aThemeColorForAPlainViewOnTheMacFollowsTheAppearance() {
        let color = NSColor(ThemeColor(light: .white, dark: .black))
        var components: (CGFloat, CGFloat) = (0, 0)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            components.0 = color.usingColorSpace(.sRGB)?.redComponent ?? -1
        }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            components.1 = color.usingColorSpace(.sRGB)?.redComponent ?? -1
        }
        #expect(components.0 == 0)
        #expect(components.1 == 1)
        #expect(NSFont.themed(ThemeFont(size: 20, weight: .bold)).pointSize == 20)
    }
#endif
