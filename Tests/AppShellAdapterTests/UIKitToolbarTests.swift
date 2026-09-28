#if canImport(UIKit)
    import AppShell
    import AppShellUIKit
    import LayoutCore
    import Nodes
    import NodesUIKit
    import StateCore
    import Testing
    import UIKit

    private enum Route: Hashable {
        case inbox
        case settings
    }

    extension Command {
        fileprivate static let compose = Command("compose", title: "Compose")
        fileprivate static let flag = Command("flag", title: "Flag")
    }

    @MainActor
    private final class Leaf: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    @Test @MainActor
    func aScreensCommandsAreButtonsOfItsNavigationBarAsEnabledAsTheCommands() throws {
        let canFlag = State(false)
        var composed = 0
        let settings = UIViewController()
        let custom = UIBarButtonItem(title: "Done")
        settings.navigationItem.rightBarButtonItem = custom
        let root = Leaf()
        root.handle(.flag, isEnabled: { canFlag.value }) {}
        let stack = Stack(root: Route.inbox) { route in
            switch route {
            case .inbox:
                let screen = NodeScreen(root, title: "Inbox")
                screen.toolbar = [.compose, .flag]
                screen.handle(.compose) { composed += 1 }
                return screen
            case .settings:
                return ControllerScreen(settings, title: "Settings")
            }
        }
        let controller = try #require(stack.makeViewController() as? UINavigationController)
        let item = controller.viewControllers[0].navigationItem
        let isTV = controller.traitCollection.userInterfaceIdiom == .tv

        // A TV's navigation bar shows no buttons.
        guard !isTV else {
            #expect(item.rightBarButtonItems == nil)
            stack.close()
            return
        }
        // The first command reads first, from the leading side.
        let buttons = try #require(item.rightBarButtonItems)
        #expect(buttons.map(\.accessibilityIdentifier) == ["flag", "compose"])
        #expect(buttons[1].isEnabled)
        #expect(!buttons[0].isEnabled)

        canFlag.value = true
        StateUpdates.flush()
        #expect(buttons[0].isEnabled)
        let screen = try #require(stack.screen(for: stack.presentedEntries[0]))
        screen.perform(.compose)
        #expect(composed == 1)

        screen.toolbar = [.flag]
        StateUpdates.flush()
        #expect(item.rightBarButtonItems?.map(\.accessibilityIdentifier) == ["flag"])
        // A controller of UIKit with no toolbar commands keeps its own buttons.
        stack.push(.settings)
        #expect(settings.navigationItem.rightBarButtonItems == [custom])
        stack.close()
    }
#endif
