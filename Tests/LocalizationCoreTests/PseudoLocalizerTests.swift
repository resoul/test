import Foundation
import Testing

@testable import LocalizationCore

private func pseudo(_ expansion: Double = 0.3) -> PseudoLocalizer {
    var catalog = LocalizationCatalog()
    catalog.insert(.text("Hello, %1$@! You have 3 messages."), for: "k", language: "en")
    return PseudoLocalizer(wrapping: CatalogLocalizer(catalog: catalog), expansion: expansion)
}

@Test
func pseudoLocalizationAccentsBracketsAndLengthensTheText() {
    let resolved = pseudo().resolve(
        LocalizedText("k", arguments: ["Ana"]),
        locale: Locale(identifier: "en")
    )

    #expect(resolved.text.hasPrefix("［") && resolved.text.hasSuffix("］"))
    #expect(resolved.text.contains("Ĥéļļö"))
    // The digits and what was put in as an argument keep their shape, and the length grows.
    #expect(resolved.text.contains("3"))
    #expect(resolved.text.contains("~"))
    #expect(resolved.text.count > "Hello, Ana! You have 3 messages.".count)
}

@Test
func pseudoLocalizationKeepsWhatTheBaseSaidAboutTheKey() {
    let found = pseudo().resolve(LocalizedText("k"), locale: Locale(identifier: "ru"))
    let missing = pseudo().resolve(LocalizedText("nope"), locale: Locale(identifier: "ru"))

    #expect(found.language == "en")
    #expect(found.missing == nil)
    #expect(missing.language == nil)
    #expect(missing.missing?.key == "nope")
}

@Test
func noExpansionAddsNoFiller() {
    let resolved = pseudo(0).resolve(LocalizedText("k"), locale: Locale(identifier: "en"))

    #expect(!resolved.text.contains("~"))
}
