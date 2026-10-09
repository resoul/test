import Foundation
import Testing

@testable import LocalizationCore

/// A bundle in a folder of its own, with the files of two languages.
private func makeBundle() throws -> (bundle: Bundle, remove: () -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("strings-" + UUID().uuidString + ".bundle")
    let contents = root.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    for language in ["en", "ru"] {
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent(language + ".lproj"),
            withIntermediateDirectories: true
        )
    }
    let info: [String: Any] = [
        "CFBundleIdentifier": "test.strings",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleName": "strings",
        "CFBundlePackageType": "BNDL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    // The text format, as written by hand.
    try Data(
        """
        /* the title */
        "inbox.title" = "Inbox";
        "greeting" = "Hello, %@!";
        """.utf8
    ).write(to: resources.appendingPathComponent("en.lproj/Localizable.strings"))
    // A property list, as the build makes of a string catalog.
    try PropertyListSerialization.data(
        fromPropertyList: ["inbox.title": "Входящие"],
        format: .binary,
        options: 0
    ).write(to: resources.appendingPathComponent("ru.lproj/Localizable.strings"))
    let plurals: [String: Any] = [
        "inbox.unread": [
            "NSStringLocalizedFormatKey": "%#@count@ в папке",
            "count": [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": "lld",
                "one": "%lld письмо",
                "few": "%lld письма",
                "many": "%lld писем",
                "other": "%lld письма",
            ],
        ],
        "two.variables": [
            "NSStringLocalizedFormatKey": "%#@a@ and %#@b@",
            "a": ["one": "x", "other": "x"],
            "b": ["one": "y", "other": "y"],
        ],
    ]
    try PropertyListSerialization.data(fromPropertyList: plurals, format: .xml, options: 0)
        .write(to: resources.appendingPathComponent("ru.lproj/Localizable.stringsdict"))
    let bundle = try #require(Bundle(url: root))
    return (bundle, { try? FileManager.default.removeItem(at: root) })
}

@Test
func theCatalogReadsStringsFilesInTheTextFormatAndAsPropertyLists() throws {
    let (bundle, remove) = try makeBundle()
    defer { remove() }

    let catalog = LocalizationCatalog.loading(from: bundle)

    #expect(catalog.entry(for: "inbox.title", language: "en") == .text("Inbox"))
    #expect(catalog.entry(for: "greeting", language: "en") == .text("Hello, %@!"))
    #expect(catalog.entry(for: "inbox.title", language: "ru") == .text("Входящие"))
}

@Test
func aStringsdictKeyBecomesAPluralEntryWithItsTextAroundTheVariable() throws {
    let (bundle, remove) = try makeBundle()
    defer { remove() }

    let catalog = LocalizationCatalog.loading(from: bundle)

    guard case .plural(let forms)? = catalog.entry(for: "inbox.unread", language: "ru") else {
        Issue.record("not a plural entry")
        return
    }

    #expect(forms[.one] == "%lld письмо в папке")
    #expect(forms[.many] == "%lld писем в папке")
    #expect(forms[.other] == "%lld письма в папке")
    // A key with two variables is not read, rather than read wrong.
    #expect(catalog.entry(for: "two.variables", language: "ru") == nil)
}

@Test
func aLocalizerAnswersFromAGrabbedBundleWithPlurals() throws {
    let (bundle, remove) = try makeBundle()
    defer { remove() }
    let localizer = CatalogLocalizer(catalog: .loading(from: bundle))
    let russian = Locale(identifier: "ru_RU")

    #expect(
        localizer.resolve(LocalizedText("inbox.unread", count: 1), locale: russian).text
            == "1 письмо в папке"
    )
    #expect(
        localizer.resolve(LocalizedText("inbox.unread", count: 7), locale: russian).text
            == "7 писем в папке"
    )
    #expect(
        localizer.resolve(
            LocalizedText("greeting", arguments: ["Ana"]),
            locale: Locale(identifier: "en")
        ).text == "Hello, Ana!"
    )
}

@Test
func aBundleWithNoStringsGivesAnEmptyCatalog() throws {
    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("empty-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    let catalog = LocalizationCatalog.loading(from: Bundle(url: empty) ?? .main, tables: ["Nope"])

    #expect(catalog.languageIdentifiers.isEmpty)
}
