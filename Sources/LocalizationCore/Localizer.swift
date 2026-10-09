import Foundation

/// A key that no catalog in the language chain had.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LocalizationDiagnostic: Sendable, Hashable {
    public var key: String
    public var table: String
    /// The identifier of the locale the text was resolved for.
    public var localeIdentifier: String

    public init(key: String, table: String, localeIdentifier: String) {
        self.key = key
        self.table = table
        self.localeIdentifier = localeIdentifier
    }
}

/// A text resolved for a locale.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ResolvedText: Sendable, Hashable {
    /// What to show.
    public var text: String
    /// The language whose strings it came from, normalized; `nil` when no catalog had the key and
    /// the text is its ``LocalizedText/defaultValue``.
    public var language: String?
    /// Set when no catalog had the key.
    public var missing: LocalizationDiagnostic?

    public init(text: String, language: String?, missing: LocalizationDiagnostic? = nil) {
        self.text = text
        self.language = language
        self.missing = missing
    }
}

/// Turns a ``LocalizedText`` into the string to show, for a locale.
///
/// Resolving is synchronous and does not wait for anything: strings are in memory, so a node can
/// resolve its text where it is laid out.
///
/// Ownership: implementations are values or hold what they read. Isolation: none; they can be
/// used from any thread. Errors: a missing key is not an error: the text falls back to its default
/// value and says so (``ResolvedText/missing``). Cancellation: not applicable.
public protocol Localizer: Sendable {
    func resolve(_ text: LocalizedText, locale: Locale) -> ResolvedText
}

/// A ``Localizer`` over a ``LocalizationCatalog``.
///
/// The language chain of the locale is tried from the most specific identifier to the plain
/// language (`pt-BR`, then `pt`), then the `fallbackLanguages`; the first catalog that has the key
/// answers. The plural form is picked by the rules of the language that answered, not of the
/// locale asked for: Russian text found for a Russian reader counts like Russian, English text
/// shown to a reader of a language the app lacks counts like English. Numbers and dates are
/// written for the locale asked for.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CatalogLocalizer: Localizer {
    public var catalog: LocalizationCatalog
    /// Languages tried after the locale's own, in order. English by default.
    public var fallbackLanguages: [String]
    /// Told of each key that was not found, from whichever thread resolved it. Keep it short.
    public var onMissing: (@Sendable (LocalizationDiagnostic) -> Void)?

    public init(
        catalog: LocalizationCatalog,
        fallbackLanguages: [String] = ["en"],
        onMissing: (@Sendable (LocalizationDiagnostic) -> Void)? = nil
    ) {
        self.catalog = catalog
        self.fallbackLanguages = fallbackLanguages
        self.onMissing = onMissing
    }

    public func resolve(_ text: LocalizedText, locale: Locale) -> ResolvedText {
        let table = text.table ?? LocalizationCatalog.defaultTable
        var chain = LanguageChain.candidates(for: locale)
        for language in fallbackLanguages {
            for candidate in LanguageChain.candidates(for: Locale(identifier: language))
            where !chain.contains(candidate) {
                chain.append(candidate)
            }
        }
        for language in chain {
            guard let entry = catalog.entry(for: text.key, table: table, language: language)
            else { continue }

            let template: String
            switch entry {
            case .text(let string):
                template = string
            case .plural(let forms):
                let category = text.count.map { PluralRules.category(for: $0, language: language) }
                template = category.flatMap { forms[$0] } ?? forms[.other] ?? text.defaultValue
            }
            return ResolvedText(
                text: Interpolation.format(template, text.allArguments, locale: locale),
                language: language
            )
        }
        let diagnostic = LocalizationDiagnostic(
            key: text.key,
            table: table,
            localeIdentifier: locale.identifier
        )
        onMissing?(diagnostic)
        return ResolvedText(
            text: Interpolation.format(text.defaultValue, text.allArguments, locale: locale),
            language: nil,
            missing: diagnostic
        )
    }
}

/// Makes any localizer's text look foreign while staying readable: letters get accents, the text
/// is wrapped in brackets, and it is made longer. Run an app with it to see which strings never
/// went through localization (they come out plain), which are cut off or overflow when a
/// language is longer than English, and which are glued together from pieces.
///
/// Ownership: value, holding the localizer it wraps. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct PseudoLocalizer: Localizer {
    public var base: any Localizer
    /// How much longer the text is made, as a share of its length; 0.3 by default, which is about
    /// what German and Finnish take over English.
    public var expansion: Double

    public init(wrapping base: any Localizer, expansion: Double = 0.3) {
        self.base = base
        self.expansion = max(0, expansion)
    }

    public func resolve(_ text: LocalizedText, locale: Locale) -> ResolvedText {
        var resolved = base.resolve(text, locale: locale)
        let accented = String(resolved.text.map { Self.accents[$0] ?? $0 })
        let filler = String(
            repeating: "~",
            count: Int((Double(accented.count) * expansion).rounded(.up))
        )
        resolved.text = "［" + accented + filler + "］"
        return resolved
    }

    private static let accents: [Character: Character] = [
        "a": "à", "b": "ƀ", "c": "ç", "d": "ð", "e": "é", "g": "ĝ", "h": "ĥ", "i": "î",
        "j": "ĵ", "k": "ķ", "l": "ļ", "n": "ñ", "o": "ö", "p": "þ", "r": "ŕ", "s": "š",
        "t": "ţ", "u": "ü", "w": "ŵ", "y": "ý", "z": "ž",
        "A": "À", "B": "Ɓ", "C": "Ç", "D": "Ð", "E": "É", "G": "Ĝ", "H": "Ĥ", "I": "Î",
        "J": "Ĵ", "K": "Ķ", "L": "Ļ", "N": "Ñ", "O": "Ö", "P": "Þ", "R": "Ŕ", "S": "Š",
        "T": "Ţ", "U": "Ü", "W": "Ŵ", "Y": "Ý", "Z": "Ž",
    ]
}

/// Puts arguments into a template.
enum Interpolation {
    /// Replaces `%1$@`, `%2$d`, `%@`, `%lld`, `%.2f` and the like with the arguments, and `%%` with
    /// `%`. A numbered placeholder takes the argument of that number; the others take the arguments in
    /// order, starting from the first. A placeholder with no argument is left as written.
    static func format(_ template: String, _ arguments: [LocalizedArgument], locale: Locale)
        -> String
    {
        guard template.contains("%") else { return template }

        var result = ""
        var next = 0
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            guard character == "%" else {
                result.append(character)
                index = template.index(after: index)
                continue
            }

            if let placeholder = parse(template, at: index) {
                switch placeholder.kind {
                case .percent:
                    result.append("%")
                case .argument(let number, let precision):
                    let position = number.map { $0 - 1 } ?? next
                    if number == nil { next += 1 }
                    if arguments.indices.contains(position) {
                        result += render(arguments[position], precision: precision, locale: locale)
                    } else {
                        result += template[index..<placeholder.end]
                    }
                }
                index = placeholder.end
            } else {
                result.append(character)
                index = template.index(after: index)
            }
        }
        return result
    }

    private enum Kind {
        case percent
        case argument(number: Int?, precision: Int?)
    }

    /// The placeholder starting at the `%` at `start`, if what follows is one.
    private static func parse(_ text: String, at start: String.Index)
        -> (kind: Kind, end: String.Index)?
    {
        var index = text.index(after: start)
        guard index < text.endIndex else { return nil }

        if text[index] == "%" { return (.percent, text.index(after: index)) }

        var number: Int?
        let digitsStart = index
        while index < text.endIndex, text[index].isASCII, text[index].isNumber {
            index = text.index(after: index)
        }
        if index < text.endIndex, text[index] == "$", index > digitsStart {
            number = Int(text[digitsStart..<index])
            index = text.index(after: index)
        } else {
            index = digitsStart
        }
        var precision: Int?
        if index < text.endIndex, text[index] == "." {
            let precisionStart = text.index(after: index)
            var end = precisionStart
            while end < text.endIndex, text[end].isASCII, text[end].isNumber {
                end = text.index(after: end)
            }
            guard end > precisionStart else { return nil }

            precision = Int(text[precisionStart..<end])
            index = end
        }
        while index < text.endIndex, text[index] == "l" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, "@diuf".contains(text[index]) else { return nil }

        return (.argument(number: number, precision: precision), text.index(after: index))
    }

    private static func render(_ argument: LocalizedArgument, precision: Int?, locale: Locale)
        -> String
    {
        switch argument {
        case .string(let value):
            return value
        case .integer(let value):
            return value.formatted(.number.locale(locale))
        case .number(let value):
            if let precision {
                return value.formatted(
                    .number.precision(.fractionLength(precision)).locale(locale)
                )
            }
            return value.formatted(.number.locale(locale))
        case .date(let value):
            return value.formatted(.dateTime.year().month().day().locale(locale))
        }
    }
}
