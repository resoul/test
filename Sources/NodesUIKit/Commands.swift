#if canImport(UIKit)
    import Nodes
    import UIKit

    extension UIMenu {
        /// The menu from `menu`, for the menu bar on iPad and Mac Catalyst — added in the app
        /// delegate's `buildMenu(with:)`:
        ///
        ///     builder.insertSibling(UIMenu(message), afterMenu: .view)
        ///
        /// Its commands go to the first responder: a node view there sends them to its tree,
        /// and they are enabled while a node would carry them out. Dividers split the items
        /// into groups shown inline.
        ///
        /// Ownership: returns a new menu. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        @available(tvOS, unavailable)
        public convenience init(_ menu: Menu) {
            var groups: [[UIMenuElement]] = [[]]
            for item in menu.items {
                switch item {
                case .command(let command):
                    groups[groups.count - 1].append(UIMenu.element(command))
                case .divider:
                    groups.append([])
                case .menu(let inner):
                    groups[groups.count - 1].append(UIMenu(inner))
                }
            }
            groups.removeAll(where: \.isEmpty)
            let children: [UIMenuElement] =
                groups.count > 1
                ? groups.map { UIMenu(title: "", options: .displayInline, children: $0) }
                : groups.first ?? []
            self.init(
                title: menu.title,
                identifier: UIMenu.Identifier("nodes.menu." + menu.title),
                children: children
            )
        }

        /// A menu element for `command`: a key command when it has a shortcut, else a plain
        /// command. Its property list is the command's id.
        @available(tvOS, unavailable)
        private static func element(_ command: Command) -> UIMenuElement {
            guard let shortcut = command.shortcut else {
                return UICommand(
                    title: command.title,
                    action: #selector(NodeView.performCommand(_:)),
                    propertyList: command.id
                )
            }

            let key = UIKeyCommand(
                title: command.title,
                action: #selector(NodeView.performCommand(_:)),
                input: shortcut.input,
                modifierFlags: UIKeyModifierFlags(shortcut.modifiers),
                propertyList: command.id
            )
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
    }

    extension NodeView {
        /// The shortcuts of the commands the nodes from the focused one out carry out, for the
        /// keyboard and its list of shortcuts on iPad.
        ///
        /// Ownership: returns new commands. Isolation: MainActor. Errors: none. Cancellation:
        /// none.
        public override var keyCommands: [UIKeyCommand]? {
            let own = host.availableCommands().compactMap { command -> UIKeyCommand? in
                guard let shortcut = command.shortcut else { return nil }

                let key = UIKeyCommand(
                    input: shortcut.input,
                    modifierFlags: UIKeyModifierFlags(shortcut.modifiers),
                    action: #selector(performShortcut(_:))
                )
                key.title = command.title
                key.discoverabilityTitle = command.title
                key.wantsPriorityOverSystemBehavior = true
                return key
            }
            return (super.keyCommands ?? []) + own
        }

        /// A menu item made from a command (`UIMenu(_:)`) was chosen: the tree carries the
        /// command out.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        @objc public func performCommand(_ sender: UICommand) {
            guard let command = command(of: sender) else { return }

            host.perform(command)
        }

        /// The keys of one of the view's `keyCommands` were pressed: the tree carries out the
        /// command they are the shortcut of.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        @objc public func performShortcut(_ sender: UIKeyCommand) {
            guard let shortcut = Shortcut(sender) else { return }

            host.perform(shortcut)
        }

        /// A command's key command and menu item reach the view while a node of the tree would
        /// carry the command out; the menu shows them enabled then.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(performCommand(_:)):
                guard let command = (sender as? UICommand).flatMap(command(of:)) else {
                    return false
                }

                return host.canPerform(command)
            case #selector(performShortcut(_:)):
                guard let shortcut = (sender as? UIKeyCommand).flatMap(Shortcut.init) else {
                    return false
                }

                return host.canPerform(shortcut)
            default:
                return super.canPerformAction(action, withSender: sender)
            }
        }

        private func command(of sender: UICommand) -> Command? {
            guard let id = sender.propertyList as? String else { return nil }

            return host.availableCommands().first { $0.id == id }
        }
    }

    extension Shortcut {
        /// The keys of `command`, or `nil` for keys a shortcut cannot have.
        @MainActor
        init?(_ command: UIKeyCommand) {
            guard let input = command.input else { return nil }

            let key: Key
            switch input {
            case UIKeyCommand.inputEscape: key = .escape
            case UIKeyCommand.inputUpArrow: key = .up
            case UIKeyCommand.inputDownArrow: key = .down
            case UIKeyCommand.inputLeftArrow: key = .left
            case UIKeyCommand.inputRightArrow: key = .right
            case UIKeyCommand.inputHome: key = .home
            case UIKeyCommand.inputEnd: key = .end
            case UIKeyCommand.inputPageUp: key = .pageUp
            case UIKeyCommand.inputPageDown: key = .pageDown
            case "\u{8}": key = .delete
            default:
                guard input.count == 1, let character = input.first else { return nil }

                key = Key(character)
            }
            var modifiers: KeyModifiers = []
            let flags = command.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.alternate) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            self.init(key, modifiers)
        }

        /// The key as a key command's input.
        var input: String {
            switch key {
            case .character(let character): String(character)
            case .return: "\r"
            case .escape: UIKeyCommand.inputEscape
            case .delete: "\u{8}"
            case .tab: "\t"
            case .space: " "
            case .up: UIKeyCommand.inputUpArrow
            case .down: UIKeyCommand.inputDownArrow
            case .left: UIKeyCommand.inputLeftArrow
            case .right: UIKeyCommand.inputRightArrow
            case .home: UIKeyCommand.inputHome
            case .end: UIKeyCommand.inputEnd
            case .pageUp: UIKeyCommand.inputPageUp
            case .pageDown: UIKeyCommand.inputPageDown
            }
        }
    }

    extension UIKeyModifierFlags {
        init(_ modifiers: KeyModifiers) {
            self = []
            if modifiers.contains(.command) { insert(.command) }
            if modifiers.contains(.shift) { insert(.shift) }
            if modifiers.contains(.option) { insert(.alternate) }
            if modifiers.contains(.control) { insert(.control) }
        }
    }
#endif
