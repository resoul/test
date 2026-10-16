import Foundation
import Testing

@testable import LocalizationCore

private func format(
    _ template: String,
    _ arguments: [LocalizedArgument] = [],
    locale: String = "en_US"
) -> String {
    Interpolation.format(template, arguments, locale: Locale(identifier: locale))
}

@Test
func numberedPlaceholdersTakeTheArgumentOfTheirNumberInAnyOrder() {
    #expect(format("%2$@ before %1$@", ["a", "b"]) == "b before a")
    #expect(format("%1$@ and %1$@", ["a"]) == "a and a")
}

@Test
func unnumberedPlaceholdersTakeTheArgumentsInOrder() {
    #expect(format("%@ then %@", ["a", "b"]) == "a then b")
    #expect(format("%lld of %ld, %d%%", [3, 10, 50]) == "3 of 10, 50%")
}

@Test
func aPercentSignIsWrittenDoubled() {
    #expect(format("100%% sure") == "100% sure")
    #expect(format("%%1$@", ["x"]) == "%1$@")
}

@Test
func aPlaceholderWithoutAnArgumentOrAnythingElseThatLooksLikeOneIsLeftAsItIs() {
    #expect(format("%1$@ %2$@", ["only"]) == "only %2$@")
    #expect(format("50% off") == "50% off")
    #expect(format("rate %q") == "rate %q")
    #expect(format("ends with %") == "ends with %")
}

@Test
func numbersAreWrittenInTheLocalesFormat() {
    #expect(format("%1$@", [1_234_567], locale: "en_US") == "1,234,567")
    #expect(format("%1$@", [1_234_567], locale: "de_DE") == "1.234.567")
    #expect(format("%1$@", [1234.5], locale: "de_DE") == "1.234,5")
}

@Test
func aPrecisionSetsTheFractionDigits() {
    #expect(format("%.2f", [3.14159]) == "3.14")
    #expect(format("%1$.1f", [2.0], locale: "de_DE") == "2,0")
}

@Test
func aDateIsWrittenForTheLocale() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    for identifier in ["en_US", "ru_RU", "ja_JP"] {
        let locale = Locale(identifier: identifier)
        #expect(
            format("%1$@", [.date(date)], locale: identifier)
                == date.formatted(.dateTime.year().month().day().locale(locale))
        )
    }
}

@Test
func aTemplateWithoutAPercentSignIsReturnedAsIs() {
    #expect(format("plain text") == "plain text")
    #expect(format("") == "")
}
