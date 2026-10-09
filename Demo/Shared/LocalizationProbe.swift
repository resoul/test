import AppShell
import Foundation
import LayoutCore
import LocalizationCore
import Nodes
import NodesRender
import StateCore

/// `LOCALIZATION_PROBE=1`: texts in the language the system gives the app. A catalog in code has
/// English and Russian; the title and a counted text are resolved for the host's locale, so the
/// launch arguments `-AppleLanguages (ru) -AppleLocale ru_RU` show Russian. Buttons set the count
/// the counted text shows, to see the plural form change. A line says which locale the tree has.
@MainActor
enum LocalizationProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Localization")
    }

    static let catalog: LocalizationCatalog = {
        var catalog = LocalizationCatalog()
        catalog.insert(.text("Inbox"), for: "title", language: "en")
        catalog.insert(.text("Входящие"), for: "title", language: "ru")
        catalog.insert(
            .plural([.one: "%1$@ unread message", .other: "%1$@ unread messages"]),
            for: "unread",
            language: "en"
        )
        catalog.insert(
            .plural([
                .one: "%1$@ непрочитанное письмо", .few: "%1$@ непрочитанных письма",
                .many: "%1$@ непрочитанных писем", .other: "%1$@ непрочитанного письма",
            ]),
            for: "unread",
            language: "ru"
        )
        return catalog
    }()

    private final class Page: Node {
        private let count = State(1)
        private let title = Text(localized: LocalizedText("title"), style: TextStyle(size: 22))
        private let unread = Text("", style: TextStyle(size: 17))
        private let localeLine = Text("", style: TextStyle(size: 15))
        private let buttons = [1, 3, 5, 21].map { number in Button("Count \(number)") {} }

        override init() {
            super.init()
            for (button, number) in zip(buttons, [1, 3, 5, 21]) {
                button.onTap = { [count] in count.value = number }
            }
        }

        override func mountedChanged(_ isMounted: Bool) {
            if isMounted { host?.localizer = CatalogLocalizer(catalog: LocalizationProbe.catalog) }
        }

        override func update() {
            unread.text = localized(LocalizedText("unread", count: count.value))
            localeLine.text = "locale: \(locale.identifier)"
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                title
                unread
                localeLine
                for button in buttons { button }
            }
            .gap(12)
            .padding(24)
            .alignItems(.start)
        }
    }
}
