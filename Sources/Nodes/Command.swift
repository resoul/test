/// A key of a keyboard shortcut.
///
/// A character key is written as a string literal — `"f"`, `"8"`, `"["` — and is kept in
/// lower case: Shift is a modifier of the shortcut, not a capital letter.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum Key: Sendable, Hashable, ExpressibleByStringLiteral {
    /// A key that types a character, in lower case.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case character(Character)
    /// Return, and Enter.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case `return`
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case escape
    /// The key that deletes backward (Backspace).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case delete
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case tab
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case space
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case up
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case down
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case left
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case right
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case home
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case end
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case pageUp
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case pageDown

    /// The key typing the first character of `value`; a space is `.space`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(stringLiteral value: String) {
        self.init(value.first ?? " ")
    }

    /// The key typing `character`; a space is `.space`, a capital letter its small one.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ character: Character) {
        switch character {
        case " ": self = .space
        case "\r", "\n": self = .return
        case "\t": self = .tab
        case "\u{1B}": self = .escape
        default: self = .character(Character(character.lowercased()))
        }
    }
}

/// The modifier keys held with a shortcut's key.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: Int

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Command on a Mac or iPad keyboard.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let command = KeyModifiers(rawValue: 1 << 0)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    /// Option (Alt).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let option = KeyModifiers(rawValue: 1 << 2)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// A key pressed with modifiers — Command-Shift-F is `Shortcut("f", [.command, .shift])`.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Shortcut: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let key: Key

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let modifiers: KeyModifiers

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Something the user asks the app to do — from a menu, a keyboard shortcut or a button of
/// the remote — that nodes of the tree carry out (`Node.handle`). Declared once, it names the
/// same action wherever it comes from:
///
///     extension Command {
///         static let flag = Command(
///             "flag", title: "Flag", shortcut: Shortcut("f", [.command, .shift]))
///     }
///
/// Commands are told apart by `id`: a handler for one carries out any command with its id.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Command: Sendable, Hashable, Identifiable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: String

    /// What a menu shows for the command, and the keyboard's list of shortcuts on iPad.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let title: String

    /// The keys that carry out the command, or `nil` for none.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let shortcut: Shortcut?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ id: String, title: String, shortcut: Shortcut? = nil) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
    }

    /// Going back: the remote's Menu button (Back on newer remotes), and Escape. When no node
    /// carries it out, the press goes on to the system — at the top of an app on a TV, that
    /// leaves the app. A screen that can go back handles it while it can:
    ///
    ///     root.handle(.back, isEnabled: { stack.count > 1 }) { pop() }
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let back = Command("back", title: "Back", shortcut: Shortcut(.escape))

    /// The remote's Play/Pause button.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let playPause = Command("playPause", title: "Play/Pause")

    /// The remote's select button held down. While a node carries it out, holding select on
    /// the focused node does this instead of pressing it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let longPress = Command("longPress", title: "More")
}

/// How a node carries out a command.
@MainActor
struct CommandHandler {
    let command: Command
    let isEnabled: @MainActor () -> Bool
    let perform: @MainActor () -> Void
}

extension Node {
    /// Carries out `command` with `perform` while `isEnabled` says the node can. A command
    /// goes to the node with the focus, else to the node last pressed or clicked, else to the
    /// root, and then out through the nodes around it: the first of them with a handler for
    /// it that is enabled carries it out. A disabled handler leaves the command to the nodes
    /// further out. A menu shows the command enabled while one of them would carry it out.
    ///
    ///     list.handle(.flag, isEnabled: { !selection.isEmpty }) { flagSelection() }
    ///
    /// A second handler for the same command replaces the first.
    ///
    /// Ownership: the node keeps the closures; they must not keep the node. Isolation:
    /// MainActor. Errors: none. Cancellation: `removeHandler(for:)`.
    public func handle(
        _ command: Command,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        perform: @escaping @MainActor () -> Void
    ) {
        let handler = CommandHandler(command: command, isEnabled: isEnabled, perform: perform)
        if let index = commandHandlers.firstIndex(where: { $0.command.id == command.id }) {
            commandHandlers[index] = handler
        } else {
            commandHandlers.append(handler)
        }
    }

    /// Stops carrying out `command`.
    ///
    /// Ownership: drops the handler's closures. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func removeHandler(for command: Command) {
        commandHandlers.removeAll { $0.command.id == command.id }
    }

    /// The commands the node has handlers for, in the order they were added.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var handledCommands: [Command] {
        commandHandlers.map(\.command)
    }
}
