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

    /// Going back: the remote's Menu button (Back on newer remotes), and Command-[ on a
    /// keyboard, as in the Finder and Safari. When nothing carries it out, the press goes on to
    /// the system — at the top of an app on a TV, that leaves the app. A screen that can go
    /// back handles it while it can:
    ///
    ///     root.handle(.back, isEnabled: { stack.count > 1 }) { pop() }
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let back = Command("back", title: "Back", shortcut: Shortcut("[", [.command]))

    /// Cancelling what is under way — an edit, a drag, a sheet: Escape. It is not going back:
    /// a screen goes back with `back`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let cancel = Command("cancel", title: "Cancel", shortcut: Shortcut(.escape))

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

/// How a node or a responder carries out a command.
@MainActor
struct CommandHandler {
    let command: Command
    let isEnabled: @MainActor () -> Bool
    let isOn: (@MainActor () -> Bool)?
    let perform: @MainActor () -> Void
}

extension [CommandHandler] {
    /// Adds `handler`, in place of one for the same command.
    mutating func set(_ handler: CommandHandler) {
        if let index = firstIndex(where: { $0.command.id == handler.command.id }) {
            self[index] = handler
        } else {
            append(handler)
        }
    }
}

extension Node {
    /// Carries out `command` with `perform` while `isEnabled` says the node can. A command
    /// goes to the node with the focus, else to the node last pressed or clicked, else to the
    /// root, and then out through the nodes around it, and past the root to the host's
    /// `outerResponder` and the responders around it: the first of them with a handler for it
    /// that is enabled carries it out. A disabled handler leaves the command to those further
    /// out. A menu shows the command enabled while one of them would carry it out.
    ///
    ///     list.handle(.flag, isEnabled: { !selection.isEmpty }) { flagSelection() }
    ///
    /// A command that turns something on and off — a sidebar shown, a sort order chosen —
    /// says with `isOn` whether it is on: a menu shows a checkmark by it then.
    ///
    ///     root.handle(.showSidebar, isOn: { sidebar.isShown }) { sidebar.isShown.toggle() }
    ///
    /// A second handler for the same command replaces the first.
    ///
    /// Ownership: the node keeps the closures; they must not keep the node. Isolation:
    /// MainActor. Errors: none. Cancellation: `removeHandler(for:)`.
    public func handle(
        _ command: Command,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        isOn: (@MainActor () -> Bool)? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        commandHandlers.set(
            CommandHandler(command: command, isEnabled: isEnabled, isOn: isOn, perform: perform)
        )
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

/// Something outside a tree of nodes that carries out commands — a screen, a container of
/// screens, a window, the app — in a chain from the inside out. A tree's commands go on to it
/// when no node carries them out (`NodeHost.outerResponder`), and on through `outer`:
///
///     let screen = CommandResponder()
///     screen.handle(.back, isEnabled: { stack.count > 1 }) { stack.removeLast() }
///     screen.outer = window
///     view.host.outerResponder = screen
///
/// A UIKit or AppKit app puts its own controllers into the chain the same way.
///
/// Ownership: the responder keeps its handlers; it does not keep `outer`. Isolation:
/// MainActor. Errors: none. Cancellation: not applicable.
@MainActor
open class CommandResponder: CommandTarget {
    /// The commands the responder carries out.
    var commandHandlers: [CommandHandler] = []

    /// The responder around this one, where the commands it does not carry out go on — the
    /// container around a screen, the window around a container.
    ///
    /// Ownership: not kept: whatever holds the responders keeps the one around. Isolation:
    /// MainActor. Errors: none. Cancellation: set to `nil`.
    public weak var outer: CommandResponder?

    /// Ownership: the caller keeps the responder. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Carries out `command` with `perform` while `isEnabled` says the responder can; a
    /// disabled handler leaves the command to `outer`. `isOn` says whether a command that
    /// turns something on and off is on, as for `Node.handle`. A second handler for the same
    /// command replaces the first.
    ///
    /// Ownership: the responder keeps the closures; they must not keep the responder.
    /// Isolation: MainActor. Errors: none. Cancellation: `removeHandler(for:)`.
    public func handle(
        _ command: Command,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        isOn: (@MainActor () -> Bool)? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        commandHandlers.set(
            CommandHandler(command: command, isEnabled: isEnabled, isOn: isOn, perform: perform)
        )
    }

    /// Stops carrying out `command`.
    ///
    /// Ownership: drops the handler's closures. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func removeHandler(for command: Command) {
        commandHandlers.removeAll { $0.command.id == command.id }
    }

    /// The commands the responder has handlers for, in the order they were added.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var handledCommands: [Command] {
        commandHandlers.map(\.command)
    }

    /// Whether this responder, or one further out, would carry out `command` now.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func canPerform(_ command: Command) -> Bool {
        enabledHandler { $0.command.id == command.id } != nil
    }

    /// Carries out `command` by this responder or the first one further out that can.
    /// Returns whether one did.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func perform(_ command: Command) -> Bool {
        guard let handler = enabledHandler(where: { $0.command.id == command.id }) else {
            return false
        }

        handler.perform()
        return true
    }

    /// Whether `command` is on (`handle(_:isEnabled:isOn:perform:)`), as the handler that
    /// would carry it out says — or, while none can, the nearest handler for it. `false` for a
    /// command that is not turned on and off.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func isOn(_ command: Command) -> Bool {
        let matches = { (handler: CommandHandler) in handler.command.id == command.id }
        let handler = enabledHandler(where: matches) ?? nearestHandler(where: matches)
        return handler?.isOn?() ?? false
    }

    /// The first enabled handler matching, from this responder out.
    func enabledHandler(where matches: (CommandHandler) -> Bool) -> CommandHandler? {
        nearestHandler { matches($0) && $0.isEnabled() }
    }

    /// The first handler matching, enabled or not, from this responder out.
    func nearestHandler(where matches: (CommandHandler) -> Bool) -> CommandHandler? {
        var responder: CommandResponder? = self
        while let current = responder {
            if let handler = current.commandHandlers.first(where: matches) {
                return handler
            }
            responder = current.outer
        }
        return nil
    }
}

/// Where a menu item, a toolbar button or any control made from a command sends it: a tree's
/// host — from its focused node out, and on past the root — or a responder and those around
/// it. It says whether the command would be carried out now and whether it is on.
///
/// Ownership: whoever makes the control keeps the target; controls do not keep it.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public protocol CommandTarget: AnyObject {
    /// Whether the command would be carried out now: a control shows it enabled then.
    /// Reading it under tracking depends on what its handlers read.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func canPerform(_ command: Command) -> Bool

    /// Carries out the command; returns whether one did.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    func perform(_ command: Command) -> Bool

    /// Whether the command is on: a menu shows a checkmark by it.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func isOn(_ command: Command) -> Bool
}
