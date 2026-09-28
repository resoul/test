#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesAppKit
    import Testing

    extension Command {
        fileprivate static let flag = Command(
            "flag",
            title: "Flag",
            shortcut: Shortcut("f", [.command, .shift])
        )
        fileprivate static let archive = Command("archive", title: "Archive")
        fileprivate static let top = Command(
            "top",
            title: "Top",
            shortcut: Shortcut(.up, [.command])
        )
    }

    @MainActor
    private final class Leaf: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 40, height: 20)) }
    }

    @MainActor
    private func key(
        _ characters: String,
        _ flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test @MainActor
    func aMenuBarBecomesTheMainMenuWithTheCommandsShortcuts() throws {
        let bar = MenuBar {
            Menu("Demo") { Command.archive }
            Menu("Message") {
                Command.flag
                Divider()
                Menu("Go") { Command.top }
            }
        }

        let menu = NSMenu(bar)

        #expect(menu.items.map(\.title) == ["Demo", "Message"])
        let message = try #require(menu.items[1].submenu)
        #expect(message.items.count == 3)
        #expect(message.items[0].title == "Flag")
        #expect(message.items[0].keyEquivalent == "f")
        #expect(message.items[0].keyEquivalentModifierMask == [.command, .shift])
        #expect(message.items[0].action == #selector(NodeNSView.performCommand(_:)))
        #expect(message.items[1].isSeparatorItem)
        let top = try #require(message.items[2].submenu?.items.first)
        #expect(top.keyEquivalent == String(UnicodeScalar(NSUpArrowFunctionKey)!))
        #expect(top.keyEquivalentModifierMask == .command)
    }

    @Test @MainActor
    func aCommandsMenuItemIsEnabledWhileANodeCanCarryItOut() {
        let leaf = Leaf()
        let view = NodeNSView(root: leaf)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        view.layout()
        var flags = 0
        var can = false
        leaf.handle(.flag, isEnabled: { can }) { flags += 1 }
        let item = NSMenuItem(Command.flag)
        let other = NSMenuItem(Command.archive)

        #expect(view.acceptsFirstResponder)
        #expect(!view.validateMenuItem(item))
        #expect(!view.validateMenuItem(other))
        can = true
        #expect(view.validateMenuItem(item))

        view.performCommand(item)
        view.performCommand(other)
        #expect(flags == 1)
        view.host.detach()
    }

    @Test @MainActor
    func aShortcutComesBeforeWhatTheKeysDoOtherwise() {
        let leaf = Leaf()
        let view = NodeNSView(root: leaf)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        view.layout()
        var done: [String] = []
        leaf.handle(.flag) { done.append("flag") }
        leaf.handle(.back) { done.append("back") }
        leaf.handle(.top) { done.append("top") }

        // Shift turns the letter into a capital; the shortcut is still Command-Shift-F.
        view.keyDown(with: key("F", [.command, .shift], keyCode: 3))
        view.keyDown(with: key("\u{1B}", keyCode: 53))
        view.keyDown(
            with: key(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .function])
        )
        #expect(done == ["flag", "back", "top"])
        view.host.detach()
    }
#endif
