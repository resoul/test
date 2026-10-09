import Testing

@testable import LocalizationCore

private func forms(_ language: String, _ numbers: [Int]) -> [PluralCategory] {
    numbers.map { PluralRules.category(for: $0, language: language) }
}

@Test
func englishHasOneFormForOneAndAnotherForTheRest() {
    #expect(
        forms("en", [0, 1, 2, 5, 11, 21, 100]) == [
            .other, .one, .other, .other, .other, .other, .other,
        ]
    )
    // The sibling languages count the same way.
    #expect(forms("de", [1, 2]) == [.one, .other])
    #expect(forms("es", [1, 2]) == [.one, .other])
}

@Test
func russianSeparatesOneFewAndMany() {
    #expect(
        forms("ru", [0, 1, 2, 3, 4, 5, 11, 12, 14, 19, 20, 21, 22, 25, 101, 102, 111, 112, 121])
            == [
                .many, .one, .few, .few, .few, .many, .many, .many, .many, .many, .many, .one, .few,
                .many, .one, .few, .many, .many, .one,
            ]
    )
    #expect(forms("uk", [1, 2, 5, 21]) == [.one, .few, .many, .one])
}

@Test
func polishTakesOneOnlyForExactlyOne() {
    #expect(
        forms("pl", [1, 2, 4, 5, 12, 22, 21, 112, 0]) == [
            .one, .few, .few, .many, .many, .few, .many, .many, .many,
        ]
    )
}

@Test
func arabicHasAllSixForms() {
    #expect(
        forms("ar", [0, 1, 2, 3, 10, 11, 99, 100, 102, 103, 111, 200])
            == [.zero, .one, .two, .few, .few, .many, .many, .other, .other, .few, .many, .other]
    )
}

@Test
func frenchCountsZeroAsOneAndJapaneseDoesNotCount() {
    #expect(forms("fr", [0, 1, 2]) == [.one, .one, .other])
    #expect(forms("pt", [0, 1, 2]) == [.one, .one, .other])
    #expect(forms("ja", [0, 1, 2, 100]) == Array(repeating: .other, count: 4))
    #expect(forms("zh", [1, 2]) == [.other, .other])
}

@Test
func czechSlovenianHebrewLithuanianAndRomanianFollowTheirOwnRules() {
    #expect(forms("cs", [1, 2, 4, 5, 0]) == [.one, .few, .few, .other, .other])
    #expect(
        forms("sl", [1, 2, 3, 4, 5, 101, 102, 103]) == [
            .one, .two, .few, .few, .other, .one, .two, .few,
        ]
    )
    #expect(forms("he", [1, 2, 3]) == [.one, .two, .other])
    #expect(
        forms("lt", [1, 2, 9, 10, 11, 21, 22]) == [.one, .few, .few, .other, .other, .one, .few]
    )
    #expect(
        forms("ro", [0, 1, 2, 19, 20, 101, 102]) == [.few, .one, .few, .few, .other, .other, .few]
    )
    #expect(forms("hr", [1, 2, 5, 21, 12]) == [.one, .few, .other, .one, .other])
    #expect(forms("lv", [0, 1, 2, 10, 11, 21]) == [.zero, .one, .other, .zero, .zero, .one])
}

@Test
func anUnknownLanguageCountsLikeEnglish() {
    #expect(forms("xx", [1, 2]) == [.one, .other])
    #expect(forms("", [1, 2]) == [.one, .other])
}

@Test
func theLanguageIsTakenFromAnIdentifierInAnyCaseAndSeparator() {
    #expect(PluralRules.category(for: 5, language: "ru-RU") == .many)
    #expect(PluralRules.category(for: 5, language: "RU") == .many)
    #expect(PluralRules.category(for: 0, language: "pt_BR") == .one)
    #expect(PluralRules.category(for: 3, language: "zh-Hans-CN") == .other)
}

@Test
func aNegativeNumberCountsBySize() {
    #expect(PluralRules.category(for: -1, language: "en") == .one)
    #expect(PluralRules.category(for: -2, language: "ru") == .few)
}
