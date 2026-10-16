import Nodes
import RichTextCore

extension RichFormat {
    /// The command that names the format in a menu or on a toolbar button, with the shortcut
    /// the rich text editor answers to: Command-B, -I and -U for bold, italic and underline,
    /// Command-Shift-X for strikethrough, Command-Shift-M for monospaced text, Command-K for a
    /// link, Command-Shift-9 for a quotation and Command-Option-C for code.
    ///
    /// The editor carries these out itself, through the platform's responder chain, because the
    /// text view holds the keyboard focus, not a node of the tree; a tree does not need to
    /// handle them.
    public var command: Command {
        switch self {
        case .bold:
            Command("richText.bold", title: "Bold", shortcut: Shortcut("b", [.command]))
        case .italic:
            Command("richText.italic", title: "Italic", shortcut: Shortcut("i", [.command]))
        case .monospace:
            Command(
                "richText.monospace",
                title: "Monospaced",
                shortcut: Shortcut("m", [.command, .shift])
            )
        case .strikethrough:
            Command(
                "richText.strikethrough",
                title: "Strikethrough",
                shortcut: Shortcut("x", [.command, .shift])
            )
        case .underline:
            Command("richText.underline", title: "Underline", shortcut: Shortcut("u", [.command]))
        case .link:
            Command("richText.link", title: "Link…", shortcut: Shortcut("k", [.command]))
        case .quote:
            Command(
                "richText.quote",
                title: "Quote",
                shortcut: Shortcut("9", [.command, .shift])
            )
        case .code:
            Command(
                "richText.code",
                title: "Code Block",
                shortcut: Shortcut("c", [.command, .option])
            )
        }
    }

    /// The format a command of this list is, or `nil` for any other command.
    public init?(commandID id: String) {
        guard let format = Self.allCases.first(where: { $0.command.id == id }) else {
            return nil
        }

        self = format
    }
}
