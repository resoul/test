/// The menus of an app's menu bar — on a Mac, and on iPad with a keyboard:
///
///     let bar = MenuBar {
///         Menu("Message") {
///             Command.flag
///             Command.archive
///             Divider()
///             Menu("Move to") { Command.moveToInbox; Command.moveToTrash }
///         }
///     }
///
/// A platform adapter turns it into the platform's menus. A command in them goes to the
/// focused node, else to the node last pressed or clicked, else to the root, and out through
/// the nodes around it (`Node.handle`); the menu shows it enabled while one of them would
/// carry it out.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct MenuBar: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let menus: [Menu]

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(@MenuBarBuilder _ menus: () -> [Menu]) {
        self.menus = menus()
    }
}

/// A menu of commands, dividers and menus inside it.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Menu: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let title: String

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let items: [MenuItem]

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ title: String, @MenuBuilder _ items: () -> [MenuItem]) {
        self.title = title
        self.items = items()
    }
}

/// An item of a menu.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public indirect enum MenuItem: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case command(Command)
    /// A line between groups of items.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case divider
    /// A menu inside the menu.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case menu(Menu)
}

/// A line between groups of items of a `Menu`.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Divider: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}
}

/// Builds the items of a `Menu` from commands, dividers and menus.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
@resultBuilder
public enum MenuBuilder {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ command: Command) -> [MenuItem] {
        [.command(command)]
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ divider: Divider) -> [MenuItem] {
        [.divider]
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ menu: Menu) -> [MenuItem] {
        [.menu(menu)]
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ item: MenuItem) -> [MenuItem] {
        [item]
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildBlock(_ parts: [MenuItem]...) -> [MenuItem] {
        parts.flatMap { $0 }
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildOptional(_ part: [MenuItem]?) -> [MenuItem] {
        part ?? []
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildEither(first part: [MenuItem]) -> [MenuItem] {
        part
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildEither(second part: [MenuItem]) -> [MenuItem] {
        part
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildArray(_ parts: [[MenuItem]]) -> [MenuItem] {
        parts.flatMap { $0 }
    }
}

/// Builds the menus of a `MenuBar`.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
@resultBuilder
public enum MenuBarBuilder {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ menu: Menu) -> [Menu] {
        [menu]
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildBlock(_ parts: [Menu]...) -> [Menu] {
        parts.flatMap { $0 }
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildOptional(_ part: [Menu]?) -> [Menu] {
        part ?? []
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildEither(first part: [Menu]) -> [Menu] {
        part
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildEither(second part: [Menu]) -> [Menu] {
        part
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func buildArray(_ parts: [[Menu]]) -> [Menu] {
        parts.flatMap { $0 }
    }
}
