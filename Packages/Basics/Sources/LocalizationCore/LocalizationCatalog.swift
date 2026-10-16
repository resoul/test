import Foundation

/// The strings of an app by language, table and key.
///
/// A value: it is built (by hand, for tests, or from the bundle's `.strings` and `.stringsdict`
/// files) and then only read, so it can be shared by every thread.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LocalizationCatalog: Sendable, Hashable {
    /// What a key is in one language.
    public enum Entry: Sendable, Hashable {
        /// One string for every number.
        case text(String)
        /// One string for each plural form the language uses; ``PluralCategory/other`` is the one
        /// used for a form the entry does not have.
        case plural([PluralCategory: String])
    }

    /// The table a text without one is looked up in.
    public static let defaultTable = "Localizable"

    private var languages: [String: [String: [String: Entry]]] = [:]

    public init() {}

    /// The identifiers of the languages the catalog has strings for, normalized.
    public var languageIdentifiers: Set<String> { Set(languages.keys) }

    /// Puts `entry` for `key` in `table` of `language`, replacing the one that was there.
    ///
    /// - Parameter language: An identifier such as `en`, `pt-BR` or `zh_Hans`.
    public mutating func insert(
        _ entry: Entry,
        for key: String,
        table: String = LocalizationCatalog.defaultTable,
        language: String
    ) {
        languages[LanguageChain.normalize(language), default: [:]][table, default: [:]][key] = entry
    }

    public func entry(
        for key: String,
        table: String = LocalizationCatalog.defaultTable,
        language: String
    ) -> Entry? {
        languages[LanguageChain.normalize(language)]?[table]?[key]
    }

    /// A catalog of plain strings: `strings[language][key]`, all in `table`.
    public init(
        strings: [String: [String: String]],
        table: String = LocalizationCatalog.defaultTable
    ) {
        for (language, keys) in strings {
            for (key, value) in keys {
                insert(.text(value), for: key, table: table, language: language)
            }
        }
    }

    // MARK: - From a bundle

    /// The catalog of the strings in `bundle`: for each language the bundle has a folder for
    /// (`ru.lproj`), the `.strings` and `.stringsdict` files of each table.
    ///
    /// A key in a `.stringsdict` file becomes a plural entry when its format is one
    /// `%#@variable@` with text around it (`"%#@count@ unread"`): each form of the variable
    /// replaces the `%#@variable@`. A key with several variables is not read. The `.strings` file
    /// is read when it is a property list, which is what the Xcode build makes of a string
    /// catalog, and in the text format with `"key" = "value";` lines.
    ///
    /// A folder named `Base` is the bundle's development language.
    ///
    /// - Parameters:
    ///   - tables: The tables to read; `Localizable` by default.
    public static func loading(
        from bundle: Bundle,
        tables: [String] = [LocalizationCatalog.defaultTable]
    ) -> LocalizationCatalog {
        var catalog = LocalizationCatalog()
        for localization in bundle.localizations {
            let language =
                localization == "Base" ? (bundle.developmentLocalization ?? "en") : localization
            for table in tables {
                if let url = bundle.url(
                    forResource: table,
                    withExtension: "strings",
                    subdirectory: nil,
                    localization: localization
                ), let dictionary = NSDictionary(contentsOf: url) as? [String: String] {
                    for (key, value) in dictionary {
                        catalog.insert(.text(value), for: key, table: table, language: language)
                    }
                }
                if let url = bundle.url(
                    forResource: table,
                    withExtension: "stringsdict",
                    subdirectory: nil,
                    localization: localization
                ), let dictionary = NSDictionary(contentsOf: url) as? [String: Any] {
                    for (key, value) in dictionary {
                        if let entry = pluralEntry(from: value) {
                            catalog.insert(entry, for: key, table: table, language: language)
                        }
                    }
                }
            }
        }
        return catalog
    }

    /// The strings of the app's main bundle, read the first time they are asked for.
    public static let main = LocalizationCatalog.loading(from: .main)

    private static func pluralEntry(from value: Any) -> Entry? {
        guard let entry = value as? [String: Any],
            let format = entry["NSStringLocalizedFormatKey"] as? String
        else { return nil }

        // Exactly one `%#@name@`.
        let marks = format.components(separatedBy: "%#@").dropFirst()
        guard marks.count == 1, let rest = marks.first, let close = rest.firstIndex(of: "@")
        else { return nil }

        let name = String(rest[..<close])
        guard let variable = entry[name] as? [String: Any] else { return nil }

        var forms: [PluralCategory: String] = [:]
        for category in PluralCategory.allCases {
            if let form = variable[category.rawValue] as? String {
                forms[category] = format.replacingOccurrences(of: "%#@\(name)@", with: form)
            }
        }
        return forms[.other] == nil ? nil : .plural(forms)
    }
}
