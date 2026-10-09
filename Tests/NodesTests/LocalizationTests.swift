import Foundation
import LayoutCore
import LocalizationCore
import Testing
import os

@testable import Nodes

private func catalog() -> LocalizationCatalog {
    var catalog = LocalizationCatalog()
    catalog.insert(.text("Inbox"), for: "title", language: "en")
    catalog.insert(.text("Входящие"), for: "title", language: "ru")
    catalog.insert(
        .plural([.one: "%1$@ unread", .other: "%1$@ unread"]),
        for: "unread",
        language: "en"
    )
    catalog.insert(
        .plural([
            .one: "%1$@ новое", .few: "%1$@ новых", .many: "%1$@ новых", .other: "%1$@ нового",
        ]),
        for: "unread",
        language: "ru"
    )
    return catalog
}

/// A node that shows a localized text, resolved where the host updates it.
@MainActor
private final class Label: Node {
    var key: LocalizedText
    private(set) var shown = ""
    private(set) var updates = 0

    init(_ key: LocalizedText) {
        self.key = key
        super.init()
    }

    override func update() {
        updates += 1
        shown = localized(key)
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 20)) }
}

@MainActor
private func host(
    _ label: Label,
    locale: String,
    localizer: (any Localizer)? = nil
) -> NodeHost {
    let host = NodeHost(root: label, size: LayoutSize(width: 200, height: 100))
    host.localizer = localizer ?? CatalogLocalizer(catalog: catalog())
    host.locale = Locale(identifier: locale)
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func aNodeShowsItsTextInTheHostsLanguage() {
    let label = Label("title")
    let host = host(label, locale: "ru_RU")

    #expect(label.shown == "Входящие")
    #expect(label.locale.identifier == "ru_RU")
    host.detach()
}

@Test @MainActor
func aChangeOfLanguageUpdatesTheNodesThatResolvedATextAndLaysTheTreeOutAgain() {
    let label = Label("title")
    let host = host(label, locale: "en_US")
    #expect(label.shown == "Inbox")
    let updates = label.updates

    host.locale = Locale(identifier: "ru_RU")
    #expect(host.needsLayout)
    host.layoutIfNeeded()

    #expect(label.shown == "Входящие")
    #expect(label.updates == updates + 1)
    host.detach()
}

@Test @MainActor
func settingTheSameLocaleAgainChangesNothing() {
    let label = Label("title")
    let host = host(label, locale: "en_US")

    host.locale = Locale(identifier: "en_US")

    #expect(!host.needsLayout)
    host.detach()
}

@Test @MainActor
func aNewLocalizerUpdatesTheTextsToo() {
    let label = Label("title")
    let host = host(label, locale: "en_US")

    host.localizer = PseudoLocalizer(wrapping: CatalogLocalizer(catalog: catalog()), expansion: 0)
    host.layoutIfNeeded()

    #expect(label.shown == "［Îñƀöx］")
    host.detach()
}

@Test @MainActor
func aCountedTextTakesTheFormOfTheHostsLanguage() {
    let label = Label(LocalizedText("unread", count: 3))
    let host = host(label, locale: "ru_RU")
    #expect(label.shown == "3 новых")

    label.key = LocalizedText("unread", count: 21)
    host.locale = Locale(identifier: "en_US")
    host.layoutIfNeeded()

    #expect(label.shown == "21 unread")
    host.detach()
}

@Test @MainActor
func aMissingKeyShowsItsDefaultValueAndIsReported() {
    let reported = Reported()
    let label = Label(LocalizedText("settings", defaultValue: "Settings"))
    let host = host(
        label,
        locale: "ru_RU",
        localizer: CatalogLocalizer(catalog: catalog(), onMissing: { reported.add($0.key) })
    )

    #expect(label.shown == "Settings")
    #expect(reported.keys == ["settings"])
    host.detach()
}

@Test @MainActor
func aNodeOutsideAnyTreeStillResolvesFromTheMainBundle() {
    let label = Label(LocalizedText("no.such.key", defaultValue: "Fallback"))

    #expect(label.localized(LocalizedText("no.such.key", defaultValue: "Fallback")) == "Fallback")
}

private final class Reported: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())

    func add(_ key: String) { storage.withLock { $0.append(key) } }

    var keys: [String] { storage.withLock { $0 } }
}
