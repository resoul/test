#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import Nodes

    extension NSMenu {
        /// The app's main menu from `bar`: one menu of the bar for each item. As in any Mac
        /// app, the first menu is the application menu and shows under the app's name. Set it
        /// as `NSApplication.shared.mainMenu`.
        ///
        /// Ownership: returns a new menu. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public convenience init(_ bar: MenuBar) {
            self.init(title: "")
            for menu in bar.menus {
                addItem(NSMenuItem(menu))
            }
        }

        /// The menu from `menu`. Its commands go to the first responder: a node view there
        /// sends them to its tree, and enables them while a node would carry them out.
        ///
        /// Ownership: returns a new menu. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public convenience init(_ menu: Menu) {
            self.init(title: menu.title)
            for item in menu.items {
                switch item {
                case .command(let command):
                    addItem(NSMenuItem(command))
                case .divider:
                    addItem(.separator())
                case .menu(let menu):
                    addItem(NSMenuItem(menu))
                }
            }
        }
    }

    extension NSMenuItem {
        /// An item carrying out `command` through the responder chain, with its title and
        /// shortcut.
        ///
        /// Ownership: returns a new item. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public convenience init(_ command: Command) {
            self.init(
                title: command.title,
                action: #selector(NodeNSView.performCommand(_:)),
                keyEquivalent: command.shortcut?.keyEquivalent ?? ""
            )
            keyEquivalentModifierMask =
                command.shortcut.map { NSEvent.ModifierFlags($0.modifiers) } ?? []
            representedObject = command
        }

        /// An item opening `menu`.
        ///
        /// Ownership: returns a new item. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public convenience init(_ menu: Menu) {
            self.init(title: menu.title, action: nil, keyEquivalent: "")
            submenu = NSMenu(menu)
        }
    }

    extension NodeNSView: NSMenuItemValidation {
        /// A menu item made from a command (`NSMenuItem(_:)`) was chosen: the tree carries the
        /// command out.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        @objc public func performCommand(_ sender: Any?) {
            guard let command = (sender as? NSMenuItem)?.representedObject as? Command else {
                return
            }

            host.perform(command)
        }

        /// A command's item is enabled while a node of the tree would carry it out.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            guard menuItem.action == #selector(performCommand(_:)) else { return true }
            guard let command = menuItem.representedObject as? Command else { return false }

            return host.canPerform(command)
        }
    }

    extension Shortcut {
        /// The keys of `event`, or `nil` for a key a shortcut cannot have.
        init?(_ event: NSEvent) {
            let key: Key
            switch event.specialKey {
            case .carriageReturn?, .enter?, .newline?: key = .return
            case .delete?, .backspace?: key = .delete
            case .tab?, .backTab?: key = .tab
            case .upArrow?: key = .up
            case .downArrow?: key = .down
            case .leftArrow?: key = .left
            case .rightArrow?: key = .right
            case .home?: key = .home
            case .end?: key = .end
            case .pageUp?: key = .pageUp
            case .pageDown?: key = .pageDown
            case .some: return nil
            case nil:
                // The character without Shift, which the characters ignoring modifiers keep:
                // Command-Shift-8 is "8" with Shift, not "*".
                let characters =
                    event.modifierFlags.contains(.shift)
                    ? event.characters(byApplyingModifiers: []) : event.charactersIgnoringModifiers
                guard var character = characters?.first else { return nil }

                // Under a layout of other letters — Cyrillic, Greek — the key is the Latin one
                // in its place, as for the menus' shortcuts.
                if !character.isASCII, let latin = Shortcut.latin[event.keyCode] {
                    character = latin
                }
                key = Key(character)
            }
            var modifiers: KeyModifiers = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) || event.specialKey == .backTab { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            self.init(key, modifiers)
        }

        /// The characters of the US keyboard, by key code.
        private static let latin: [UInt16: Character] = {
            let keys: [(UInt16, Character)] = [
                (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"),
                (8, "c"), (9, "v"), (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"),
                (16, "y"), (17, "t"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (22, "6"),
                (23, "5"), (24, "="), (25, "9"), (26, "7"), (27, "-"), (28, "8"), (29, "0"),
                (30, "]"), (31, "o"), (32, "u"), (33, "["), (34, "i"), (35, "p"), (37, "l"),
                (38, "j"), (39, "'"), (40, "k"), (41, ";"), (42, "\\"), (43, ","), (44, "/"),
                (45, "n"), (46, "m"), (47, "."), (50, "`"),
            ]
            return Dictionary(uniqueKeysWithValues: keys)
        }()

        /// The key as a menu item's key equivalent.
        var keyEquivalent: String {
            switch key {
            case .character(let character): String(character)
            case .return: "\r"
            case .escape: "\u{1B}"
            case .delete: "\u{8}"
            case .tab: "\t"
            case .space: " "
            case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .left: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .home: String(UnicodeScalar(NSHomeFunctionKey)!)
            case .end: String(UnicodeScalar(NSEndFunctionKey)!)
            case .pageUp: String(UnicodeScalar(NSPageUpFunctionKey)!)
            case .pageDown: String(UnicodeScalar(NSPageDownFunctionKey)!)
            }
        }
    }

    extension NSEvent.ModifierFlags {
        init(_ modifiers: KeyModifiers) {
            self = []
            if modifiers.contains(.command) { insert(.command) }
            if modifiers.contains(.shift) { insert(.shift) }
            if modifiers.contains(.option) { insert(.option) }
            if modifiers.contains(.control) { insert(.control) }
        }
    }
#endif
