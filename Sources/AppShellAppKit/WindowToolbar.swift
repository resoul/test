// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import Nodes
    import NodesAppKit

    /// The toolbar of a window whose content is a stack or a screen: the stack's back button
    /// at the leading edge, and the commands of the screen that shows at the trailing one.
    /// Its buttons send their commands through the responder chain; AppKit enables each while
    /// the first responder — the screen's node view, or the stack over a view of AppKit —
    /// would carry it out.
    @MainActor
    final class WindowToolbar: NSObject, NSToolbarDelegate {
        /// Toolbars with one identifier share their items: each window's has its own.
        let toolbar = NSToolbar(identifier: "screen." + UUID().uuidString)
        /// Whether a back button leads the toolbar.
        private let hasBack: Bool
        private var commands: [Command] = []

        init(hasBack: Bool) {
            self.hasBack = hasBack
            super.init()
            toolbar.delegate = self
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            if hasBack {
                toolbar.insertItem(withItemIdentifier: Self.back, at: 0)
            }
        }

        /// Puts the toolbar on `window`, unless the window has a toolbar of its own.
        func attach(to window: NSWindow) {
            if window.toolbar == nil {
                window.toolbar = toolbar
            }
        }

        /// Shows `commands` as the toolbar's buttons, after the back button.
        func show(_ commands: [Command]) {
            guard commands != self.commands else { return }

            let lead = hasBack ? 1 : 0
            while toolbar.items.count > lead {
                toolbar.removeItem(at: lead)
            }
            self.commands = commands
            guard !commands.isEmpty else { return }

            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: lead)
            for (offset, command) in commands.enumerated() {
                toolbar.insertItem(
                    withItemIdentifier: NSToolbarItem.Identifier(command.id),
                    at: lead + 1 + offset
                )
            }
        }

        /// The identifier of the back button: not a command's id, so that a screen showing
        /// `Command.back` among its own commands gets a button of its own.
        private static let back = NSToolbarItem.Identifier("toolbar.back")

        // MARK: - NSToolbarDelegate

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            if itemIdentifier == Self.back {
                let item = CommandToolbarItem(.back, identifier: Self.back)
                item.image = NSImage(
                    systemSymbolName: "chevron.backward",
                    accessibilityDescription: Command.back.title
                )
                return item
            }
            return commands.first { $0.id == itemIdentifier.rawValue }.map {
                CommandToolbarItem($0)
            }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            identifiers
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            identifiers
        }

        private var identifiers: [NSToolbarItem.Identifier] {
            (hasBack ? [Self.back] : []) + [.flexibleSpace]
                + commands.map { NSToolbarItem.Identifier($0.id) }
        }
    }
#endif
