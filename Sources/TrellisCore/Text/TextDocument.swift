import Foundation

/// Run-level font family override — mirrors `TextStyle.fontName`, including `"system"`.
///
/// Ownership: no owned state; this is a `Foundation.AttributedStringKey` marker type.
/// Isolation: none. Errors: none. Cancellation: not applicable.
public enum TextFontNameAttribute: AttributedStringKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Value = String

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let name = "TrellisTextFontName"
}

/// Run-level point size override, in points.
///
/// Ownership: no owned state. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TextPointSizeAttribute: AttributedStringKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Value = Double

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let name = "TrellisTextPointSize"
}

/// Run-level weight override.
///
/// Ownership: no owned state. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TextWeightAttribute: AttributedStringKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Value = TextWeight

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let name = "TrellisTextWeight"
}

/// Run-level color override.
///
/// Ownership: no owned state. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TextColorAttribute: AttributedStringKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Value = ThemeColor

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let name = "TrellisTextColor"
}

/// The only attributes a `TextNode` document may carry (D55) — first version supports
/// font/size/weight/color run overrides; paragraph-level fields (`lineHeight`/`alignment`/
/// `maxLines`/`truncation`) stay on `TextStyle`, not in runs. An attribute outside this scope
/// carries no promised meaning: it is neither measured nor drawn.
///
/// Ownership: no owned state; this is a `Foundation.AttributeScope` marker type. Isolation:
/// none. Errors: none. Cancellation: not applicable.
public struct TrellisTextAttributes: AttributeScope {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let fontName: TextFontNameAttribute

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let pointSize: TextPointSizeAttribute

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let weight: TextWeightAttribute

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let color: TextColorAttribute
}

extension AttributeScopes {
    /// Exposes `TrellisTextAttributes` as `AttributeScopes.trellisText` — the customary way
    /// Foundation looks up a custom scope by name.
    ///
    /// Ownership: returns a metatype value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var trellisText: TrellisTextAttributes.Type { TrellisTextAttributes.self }
}

extension AttributeDynamicLookup {
    /// Enables `attributedString.trellisText.fontName` / `.pointSize` / `.weight` / `.color`
    /// dynamic-member access on runs, the customary way Foundation reads a custom scope.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<TrellisTextAttributes, T>
    ) -> T {
        self[T.self]
    }
}

/// The single canonical text model a `TextNode` holds (D55) — one `AttributedString`, not a
/// pair of independent `text`/`attributedText` fields (the W07-class defect this avoids).
/// `TextNode(text:)` builds one of these with no runs; mixed styling builds one directly.
///
/// Ownership: value type, copied on write like any `AttributedString`. Isolation: none —
/// `AttributedString` is `Sendable` when its scope's attribute values are, which
/// `TrellisTextAttributes` satisfies. Errors: none. Cancellation: not applicable.
public typealias TextDocument = AttributedString

extension TextDocument {
    /// The plain characters of this document, independent of any run attributes — used for
    /// accessibility's default label (D57) and by measurers that only need the text itself.
    ///
    /// Ownership: returns a new string. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var plainCharacters: String {
        String(characters)
    }
}
