import Foundation
import Testing

@testable import LocalizationCore

@Test
func theChainGoesFromTheMostSpecificIdentifierToTheLanguage() {
    #expect(LanguageChain.candidates(for: Locale(identifier: "pt_BR")) == ["pt-br", "pt"])
    #expect(LanguageChain.candidates(for: Locale(identifier: "en")) == ["en"])
    #expect(
        LanguageChain.candidates(for: Locale(identifier: "zh-Hans-CN"))
            == ["zh-hans-cn", "zh-hans", "zh-cn", "zh"]
    )
    #expect(LanguageChain.candidates(for: Locale(identifier: "sr-Latn")) == ["sr-latn", "sr"])
    // Keywords after the @ are not part of the language.
    #expect(
        LanguageChain.candidates(for: Locale(identifier: "en_US@calendar=buddhist")) == [
            "en-us", "en",
        ]
    )
}

@Test
func identifiersAreComparedWithoutRegardToCaseOrSeparator() {
    #expect(LanguageChain.normalize("pt_BR") == "pt-br")
    #expect(LanguageChain.normalize("zh-Hans") == "zh-hans")
}

@Test
func arabicHebrewPersianAndUrduReadFromRightToLeft() {
    for identifier in ["ar", "he", "fa", "ur", "ar_EG", "he_IL"] {
        #expect(Locale(identifier: identifier).isRightToLeft, "\(identifier)")
    }
    for identifier in ["en", "ru", "ja", "de_DE", "zh-Hans"] {
        #expect(!Locale(identifier: identifier).isRightToLeft, "\(identifier)")
    }
}
