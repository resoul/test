#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesUIKit
    import Testing
    import UIKit

    extension Command {
        fileprivate static let flag = Command(
            "flag",
            title: "Flag",
            shortcut: Shortcut("f", [.command, .shift])
        )
        fileprivate static let archive = Command("archive", title: "Archive")
    }

    /// A button of the remote, pressed in a test.
    private final class Press: UIPress {
        let kind: UIPress.PressType

        init(_ kind: UIPress.PressType) {
            self.kind = kind
            super.init()
        }

        override var type: UIPress.PressType { kind }
    }

    /// The view around the node view: the presses the tree does not take come to it.
    private final class Around: UIView {
        var presses: [UIPress.PressType] = []

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            self.presses += presses.map(\.type)
        }
    }

    @MainActor
    private final class Row: Node {
        var taps = 0

        override init() {
            super.init()
            onTap = { [unowned self] in taps += 1 }
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    @MainActor
    private func showing(_ row: Row) -> (NodeView, Around) {
        let around = Around(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let view = NodeView(root: row)
        view.frame = around.bounds
        around.addSubview(view)
        view.layoutIfNeeded()
        return (view, around)
    }

    @Test @MainActor
    func theMenuButtonGoesBackWhileANodeCanAndLeavesTheRestToTheSystem() {
        let row = Row()
        let (view, around) = showing(row)
        var depth = 1
        row.handle(.back, isEnabled: { depth > 0 }) { depth -= 1 }

        view.pressesBegan([Press(.menu)], with: nil)
        view.pressesBegan([Press(.menu)], with: nil)
        view.pressesBegan([Press(.playPause)], with: nil)

        #expect(depth == 0)
        #expect(around.presses == [.menu, .playPause])
        view.host.detach()
    }

    @Test @MainActor
    func theMenuButtonReachesAResponderOutsideTheTree() {
        let row = Row()
        let (view, around) = showing(row)
        let stack = CommandResponder()
        var backs = 0
        stack.handle(.back, isEnabled: { backs == 0 }) { backs += 1 }
        view.host.outerResponder = stack

        view.pressesBegan([Press(.menu)], with: nil)
        view.pressesBegan([Press(.menu)], with: nil)

        #expect(backs == 1)
        #expect(around.presses == [.menu])
        #expect(view.keyCommands?.contains { $0.input == "[" } == true)
        view.host.detach()
    }

    @Test @MainActor
    func playPauseGoesToTheNodes() {
        let row = Row()
        let (view, around) = showing(row)
        var plays = 0
        row.handle(.playPause) { plays += 1 }
        let press = Press(.playPause)

        view.pressesBegan([press], with: nil)
        view.pressesEnded([press], with: nil)

        #expect(plays == 1)
        #expect(around.presses.isEmpty)
        view.host.detach()
    }

    @Test @MainActor
    func selectHeldDownIsALongPressInsteadOfATap() async throws {
        let row = Row()
        let (view, _) = showing(row)
        var longPresses = 0
        row.handle(.longPress) { longPresses += 1 }
        view.host.focus(row.id)

        let short = Press(.select)
        view.pressesBegan([short], with: nil)
        view.pressesEnded([short], with: nil)
        #expect(row.taps == 1)

        let long = Press(.select)
        view.pressesBegan([long], with: nil)
        // Half a second makes a long press.
        try await Task.sleep(for: .seconds(0.8))
        view.pressesEnded([long], with: nil)
        #expect(row.taps == 1)
        #expect(longPresses == 1)
        view.host.detach()
    }

    @Test @MainActor
    func theKeyCommandsAreTheShortcutsOfTheCommandsTheNodesCarryOut() throws {
        let row = Row()
        let (view, _) = showing(row)
        var flags = 0
        var can = true
        row.handle(.flag, isEnabled: { can }) { flags += 1 }
        row.handle(.archive) {}

        let keys = view.keyCommands ?? []
        let flag = try #require(keys.first { $0.title == "Flag" })
        #expect(keys.count == 1)
        #expect(flag.input == "f")
        #expect(flag.modifierFlags == [.command, .shift])
        #expect(view.canPerformAction(flag.action!, withSender: flag))

        view.performShortcut(flag)
        can = false
        #expect(!view.canPerformAction(flag.action!, withSender: flag))
        #expect(flags == 1)
        #expect(view.canBecomeFirstResponder)
        view.host.detach()
    }

    @Test @MainActor @available(tvOS, unavailable)
    func aMenuOfTheMenuBarGroupsItsItemsBetweenDividers() throws {
        let menu = UIMenu(
            Menu("Message") {
                Command.flag
                Divider()
                Command.archive
                Menu("More") { Command.back }
            }
        )

        #expect(menu.title == "Message")
        let groups = menu.children.compactMap { $0 as? UIMenu }
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.options.contains(.displayInline) })
        let flag = try #require(groups[0].children.first as? UIKeyCommand)
        #expect(flag.input == "f")
        #expect(flag.propertyList as? String == "flag")
        #expect(flag.action == #selector(NodeView.performCommand(_:)))
        let archive = try #require(groups[1].children.first as? UICommand)
        #expect(!(archive is UIKeyCommand))
        #expect((groups[1].children.last as? UIMenu)?.title == "More")
    }

    @Test @MainActor @available(tvOS, unavailable)
    func aCommandThatIsOnShowsACheckmarkInItsMenu() throws {
        var on = false
        let row = Row()
        row.handle(.archive, isOn: { on }) {}
        let view = NodeView(root: row)
        let menu = UIMenu(Menu("Message") { Command.archive })
        let archive = try #require(menu.children.first as? UICommand)

        view.validate(archive)
        #expect(archive.state == .off)
        on = true
        view.validate(archive)
        #expect(archive.state == .on)
        view.host.detach()
    }
#endif
