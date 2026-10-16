import Foundation

extension Locale {
    /// Whether the language of the locale is written from right to left, by the language's own
    /// data and not a list kept here.
    public var isRightToLeft: Bool {
        language.characterDirection == .rightToLeft
    }
}

/// The identifiers a catalog is asked for, most specific first, for a locale.
///
/// Identifiers are written with hyphens and compared without regard to case, so `pt_BR`,
/// `pt-br` and `pt-BR` name one language.
///
/// Ownership: none. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LanguageChain {
    /// For `zh-Hans-CN`: `zh-hans-cn`, `zh-hans`, `zh-cn`, `zh`. A locale with no language gives
    /// none.
    public static func candidates(for locale: Locale) -> [String] {
        // Only the parts the identifier names: the locale's own `language.script` is the likely
        // one (Latin for Portuguese), which would put `pt-latn` in the chain of every Portuguese.
        let identifier =
            locale.identifier
            .split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        let parts = Locale.Language.Components(
            identifier: identifier.replacingOccurrences(of: "_", with: "-")
        )
        guard let code = parts.languageCode?.identifier else { return [] }

        let script = parts.script?.identifier
        let region = parts.region?.identifier
        var result: [String] = []
        func add(_ parts: String?...) {
            let identifier = normalize(parts.compactMap { $0 }.joined(separator: "-"))
            if !result.contains(identifier) { result.append(identifier) }
        }
        add(code, script, region)
        add(code, script)
        add(code, region)
        add(code)
        return result
    }

    /// The form identifiers are compared in: hyphens, lower case.
    public static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
