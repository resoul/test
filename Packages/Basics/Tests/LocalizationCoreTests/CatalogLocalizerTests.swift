import Foundation
import Testing
import os

@testable import LocalizationCore

private func catalog() -> LocalizationCatalog {
    var catalog = LocalizationCatalog()
    catalog.insert(.text("Inbox"), for: "inbox.title", language: "en")
    catalog.insert(.text("Входящие"), for: "inbox.title", language: "ru")
    catalog.insert(.text("Caixa de entrada"), for: "inbox.title", language: "pt")
    catalog.insert(.text("Caixa de entrada (BR)"), for: "inbox.title", language: "pt_BR")
    catalog.insert(
        .plural([.one: "%1$@ unread message", .other: "%1$@ unread messages"]),
        for: "inbox.unread",
        language: "en"
    )
    catalog.insert(
        .plural([
            .one: "%1$@ непрочитанное", .few: "%1$@ непрочитанных (few)",
            .many: "%1$@ непрочитанных", .other: "%1$@ непрочитанного",
        ]),
        for: "inbox.unread",
        language: "ru"
    )
    catalog.insert(
        .plural([.one: "%1$@ message in %2$@", .other: "%1$@ messages in %2$@"]),
        for: "folder.count",
        language: "en"
    )
    catalog.insert(.text("Hello, %1$@!"), for: "greeting", table: "Welcome", language: "en")
    catalog.insert(.text("Привет, %1$@!"), for: "greeting", table: "Welcome", language: "ru")
    return catalog
}

private func resolve(
    _ text: LocalizedText,
    _ identifier: String,
    fallback: [String] = ["en"]
) -> ResolvedText {
    CatalogLocalizer(catalog: catalog(), fallbackLanguages: fallback)
        .resolve(text, locale: Locale(identifier: identifier))
}

@Test
func aTextIsFoundForTheLocalesOwnLanguage() {
    let resolved = resolve("inbox.title", "ru_RU")

    #expect(resolved.text == "Входящие")
    #expect(resolved.language == "ru")
    #expect(resolved.missing == nil)
}

@Test
func theRegionsStringsWinOverTheLanguagesAndTheLanguageIsTheFallbackOfTheRegion() {
    #expect(resolve("inbox.title", "pt_BR").text == "Caixa de entrada (BR)")
    // Portugal has none of its own: the language's.
    let portugal = resolve("inbox.title", "pt_PT")
    #expect(portugal.text == "Caixa de entrada")
    #expect(portugal.language == "pt")
}

@Test
func aLanguageTheAppLacksFallsBackToTheFallbackLanguage() {
    let resolved = resolve("inbox.title", "ja_JP")

    #expect(resolved.text == "Inbox")
    #expect(resolved.language == "en")
    #expect(resolved.missing == nil, "found, in the fallback language")
}

@Test
func aKeyNoCatalogHasShowsItsDefaultValueAndSaysSo() {
    let reported = OSAllocatedUnfairLock(initialState: [LocalizationDiagnostic]())
    let localizer = CatalogLocalizer(
        catalog: catalog(),
        onMissing: { diagnostic in reported.withLock { $0.append(diagnostic) } }
    )

    let resolved = localizer.resolve(
        LocalizedText("settings.title", defaultValue: "Settings"),
        locale: Locale(identifier: "ru_RU")
    )
    let bare = localizer.resolve("unknown.key", locale: Locale(identifier: "en_US"))

    #expect(resolved.text == "Settings")
    #expect(resolved.language == nil)
    #expect(
        resolved.missing
            == LocalizationDiagnostic(
                key: "settings.title",
                table: "Localizable",
                localeIdentifier: "ru_RU"
            )
    )
    #expect(bare.text == "unknown.key", "the key is the default default")
    #expect(reported.withLock { $0.map(\.key) } == ["settings.title", "unknown.key"])
}

@Test
func aTableIsLookedUpOnItsOwn() {
    let welcome = resolve(
        LocalizedText("greeting", table: "Welcome", arguments: ["Ana"]),
        "ru"
    )
    let wrongTable = resolve(LocalizedText("greeting", arguments: ["Ana"]), "ru")

    #expect(welcome.text == "Привет, Ana!")
    #expect(wrongTable.missing != nil)
}

@Test
func thePluralFormIsPickedByTheRulesOfTheLanguageThatAnswered() {
    func unread(_ count: Int, _ locale: String) -> String {
        resolve(LocalizedText("inbox.unread", count: count), locale).text
    }

    #expect(unread(1, "ru") == "1 непрочитанное")
    #expect(unread(3, "ru") == "3 непрочитанных (few)")
    #expect(unread(5, "ru") == "5 непрочитанных")
    #expect(unread(21, "ru") == "21 непрочитанное")
    // Ukrainian has no strings: English answers and counts as English, not as Ukrainian — where
    // Ukrainian would call 21 `one`, English calls it `other`.
    #expect(unread(21, "uk") == "21 unread messages")
    #expect(unread(1, "uk") == "1 unread message")
}

@Test
func thePluralFormTheEntryLacksFallsBackToOther() {
    var small = LocalizationCatalog()
    small.insert(.plural([.one: "one thing", .other: "%1$@ things"]), for: "k", language: "ru")
    let localizer = CatalogLocalizer(catalog: small)

    // Russian asks for `few` for 3; the entry has no `few`.
    let text = localizer.resolve(LocalizedText("k", count: 3), locale: Locale(identifier: "ru"))

    #expect(text.text == "3 things")
}

@Test
func aPluralEntryWithoutACountTakesOtherAndATextEntryIgnoresTheCount() {
    #expect(resolve("inbox.unread", "ru").text == "%1$@ непрочитанного")
    #expect(resolve(LocalizedText("inbox.title", count: 3), "en").text == "Inbox")
}

@Test
func theCountIsTheFirstArgumentAndTheOthersFollow() {
    let one = resolve(LocalizedText("folder.count", count: 1, arguments: ["Work"]), "en")
    let many = resolve(LocalizedText("folder.count", count: 2000, arguments: ["Work"]), "en")

    #expect(one.text == "1 message in Work")
    #expect(many.text == "2,000 messages in Work")
}

@Test
func aCatalogKeyIsFoundWhateverTheSeparatorAndCaseOfTheLanguage() {
    var catalog = LocalizationCatalog()
    catalog.insert(.text("x"), for: "k", language: "PT_br")

    #expect(catalog.entry(for: "k", language: "pt-BR") == .text("x"))
    #expect(catalog.languageIdentifiers == ["pt-br"])
}

@Test
func aCatalogOfPlainStringsIsBuiltFromDictionaries() {
    let catalog = LocalizationCatalog(strings: ["en": ["a": "A"], "ru": ["a": "Я"]], table: "T")

    #expect(catalog.entry(for: "a", table: "T", language: "ru") == .text("Я"))
    #expect(catalog.entry(for: "a", language: "ru") == nil, "another table")
}

@Test
func aTextIsWrittenAsALiteralWithItsKeyForDefaultValue() {
    let text: LocalizedText = "inbox.title"

    #expect(text.key == "inbox.title")
    #expect(text.defaultValue == "inbox.title")
    #expect(text.count == nil)
}
