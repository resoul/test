/// Builds an ordered `[Arrangement]` from a `Row`/`Column`/`Overlay` content closure (C22).
///
/// Supports a plain sequence of items, a conditional branch (`if`/`else`, `switch`), an
/// optional branch (`if` with no `else`), and a loop (`for`) — every form a builder scope is
/// expected to accept.
///
/// Ownership: returns a value; every item's referenced node is only borrowed. Isolation:
/// MainActor. Errors: none. Cancellation: not applicable.
@MainActor
@resultBuilder
public enum ArrangementBuilder {
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static func buildBlock(_ components: [Arrangement]...) -> [Arrangement] {
        components.flatMap { $0 }
    }

    /// Ownership: returns a value; `expression` is borrowed. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public static func buildExpression(_ expression: Arrangement) -> [Arrangement] {
        [expression]
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static func buildOptional(_ component: [Arrangement]?) -> [Arrangement] {
        component ?? []
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static func buildEither(first component: [Arrangement]) -> [Arrangement] {
        component
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static func buildEither(second component: [Arrangement]) -> [Arrangement] {
        component
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static func buildArray(_ components: [[Arrangement]]) -> [Arrangement] {
        components.flatMap { $0 }
    }
}
