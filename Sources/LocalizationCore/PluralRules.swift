import Foundation

/// The forms a language gives a counted noun: "1 message", "2 messages" is two forms in English
/// and four in Russian, six in Arabic.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PluralCategory: String, Sendable, Hashable, CaseIterable {
    case zero, one, two, few, many, other
}

/// Which plural form a whole number takes in a language, by the cardinal rules of the Unicode
/// CLDR for the languages below.
///
/// - **One form** (`other`): Chinese, Japanese, Korean, Vietnamese, Thai, Indonesian, Malay,
///   Burmese, Lao, Khmer.
/// - **`one` for 1:** English, German, Dutch, Swedish, Norwegian, Danish, Finnish, Estonian,
///   Italian, Spanish, Catalan, Greek, Hungarian, Turkish, Bulgarian.
/// - **`one` for 0 and 1:** French, Portuguese, Hindi, Bengali.
/// - **`one`, `few`, `many`:** Russian, Ukrainian, Belarusian, Polish.
/// - **`one`, `few`, `other`:** Czech, Slovak, Croatian, Serbian, Bosnian, Lithuanian, Romanian.
/// - **`one`, `two`, `few`, `other`:** Slovenian. **`one`, `two`, `other`:** Hebrew.
/// - **`zero`, `one`, `two`, `few`, `many`, `other`:** Arabic. **`zero`, `one`, `other`:** Latvian.
///
/// The `many` form that French, Portuguese, Spanish and Italian give to exact millions is not
/// modelled: those take `other`. Any other language is taken to be like English. Whole numbers only: a fraction takes `other`
/// in most of these languages, and the text a program counts is whole.
///
/// Ownership: none. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PluralRules {
    /// - Parameters:
    ///   - count: The number; a negative one is taken by its size.
    ///   - language: A language code (`"ru"`) or an identifier (`"ru-RU"`, `"pt_BR"`); only the
    ///     language part matters.
    public static func category(for count: Int, language: String) -> PluralCategory {
        let n = abs(count)
        let mod10 = n % 10
        let mod100 = n % 100
        switch languageCode(of: language) {
        case "zh", "ja", "ko", "vi", "th", "id", "ms", "my", "lo", "km":
            return .other
        case "fr", "pt", "hi", "bn":
            return n <= 1 ? .one : .other
        case "ru", "uk", "be":
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case "pl":
            if n == 1 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case "cs", "sk":
            if n == 1 { return .one }
            return (2...4).contains(n) ? .few : .other
        case "hr", "sr", "bs":
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .other
        case "lt":
            if mod10 == 1 && !(11...19).contains(mod100) { return .one }
            if (2...9).contains(mod10) && !(11...19).contains(mod100) { return .few }
            return .other
        case "ro":
            if n == 1 { return .one }
            if n == 0 || (2...19).contains(mod100) { return .few }
            return .other
        case "sl":
            if mod100 == 1 { return .one }
            if mod100 == 2 { return .two }
            return (3...4).contains(mod100) ? .few : .other
        case "he", "iw":
            if n == 1 { return .one }
            return n == 2 ? .two : .other
        case "ar":
            if n == 0 { return .zero }
            if n == 1 { return .one }
            if n == 2 { return .two }
            if (3...10).contains(mod100) { return .few }
            return (11...99).contains(mod100) ? .many : .other
        case "lv":
            if mod10 == 0 || (11...19).contains(mod100) { return .zero }
            return mod10 == 1 && mod100 != 11 ? .one : .other
        default:
            return n == 1 ? .one : .other
        }
    }

    static func languageCode(of identifier: String) -> String {
        let end = identifier.firstIndex { $0 == "-" || $0 == "_" } ?? identifier.endIndex
        return identifier[..<end].lowercased()
    }
}
