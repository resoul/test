import Foundation

/// A value substituted into a localized string: `%1$@` is the first, `%2$@` the second.
///
/// Numbers and dates are written in the format of the locale the text is resolved for, not of
/// the device's, so the same text resolved for two locales reads right in both.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LocalizedArgument: Sendable, Hashable, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral
{
    case string(String)
    case integer(Int)
    case number(Double)
    case date(Date)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
}

/// A piece of text that is looked up for the reader's language when it is shown: a key into a
/// catalog, with what to show when the catalog has nothing, and the values to put into it.
///
///     LocalizedText("inbox.title")
///     LocalizedText("inbox.unread", defaultValue: "%1$@ unread", count: 3)
///     LocalizedText("greeting", defaultValue: "Hello, %1$@!", arguments: ["Ana"])
///
/// ``init(_:table:defaultValue:count:arguments:)`` with a `count` picks the plural form the
/// language uses for that number, and the count is the first argument, so `%1$@` in a plural
/// form is the number and the other arguments follow from `%2$@`.
///
/// A text is a plain value, written where the node is made and resolved where it is shown
/// (`Node.localized(_:)`), so a change of language shows without making the text again.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LocalizedText: Sendable, Hashable, ExpressibleByStringLiteral {
    /// The key the catalog is asked for.
    public var key: String
    /// The table (the `.strings` file) the key is in; `nil` for `Localizable`.
    public var table: String?
    /// What to show when no catalog in the language chain has the key. The key itself by default,
    /// which is readable enough to see what is missing.
    public var defaultValue: String
    /// The number that picks the plural form, and is the first argument; `nil` for a text that
    /// does not count anything.
    public var count: Int?
    /// The values for `%1$@`, `%2$@`… (after the count, if there is one).
    public var arguments: [LocalizedArgument]

    public init(
        _ key: String,
        table: String? = nil,
        defaultValue: String? = nil,
        arguments: [LocalizedArgument] = []
    ) {
        self.key = key
        self.table = table
        self.defaultValue = defaultValue ?? key
        self.count = nil
        self.arguments = arguments
    }

    public init(
        _ key: String,
        table: String? = nil,
        defaultValue: String? = nil,
        count: Int,
        arguments: [LocalizedArgument] = []
    ) {
        self.key = key
        self.table = table
        self.defaultValue = defaultValue ?? key
        self.count = count
        self.arguments = arguments
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Every value a template can name, in order: the count, then the arguments.
    var allArguments: [LocalizedArgument] {
        (count.map { [LocalizedArgument.integer($0)] } ?? []) + arguments
    }
}
