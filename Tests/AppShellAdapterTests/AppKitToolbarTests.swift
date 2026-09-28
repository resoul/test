#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import LayoutCore
    import Nodes
    import NodesAppKit
    import StateCore
    import Testing

    @testable import AppShellAppKit

    private enum Route: Hashable {
        case inbox
        case message
        case settings
    }

    extension Command {
        fileprivate static let compose = Command("compose", title: "Compose")
        fileprivate static let flag = Command("flag", title: "Flag")
        fileprivate static let unreadOnly = Command("unreadOnly", title: "Unread Only")
    }

    @MainActor
    private final class Leaf: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    @MainActor
    private func window(showing controller: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // The window is not put on screen: the controller is told it appeared.
        controller.viewDidAppear()
        return window
    }

    @MainActor
    private func identifiers(_ window: NSWindow) -> [String] {
        window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
    }

    @MainActor
    private func settled(_ stack: Stack<Route>) async throws {
        for _ in 0..<200 where stack.presentedPath != stack.path {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stack.presentedPath == stack.path)
    }

    private let flexible = NSToolbarItem.Identifier.flexibleSpace.rawValue

    @Test @MainActor
    func aStacksWindowHasABackButtonAndTheTopScreensCommands() async throws {
        var flagged = 0
        let settings = NSViewController()
        settings.view = NSView()
        let stack = Stack(root: Route.inbox) { route in
            switch route {
            case .inbox:
                let screen = NodeScreen(Leaf(), title: "Inbox")
                screen.toolbar = [.compose]
                return screen
            case .message:
                let root = Leaf()
                root.handle(.flag) { flagged += 1 }
                let screen = NodeScreen(root, title: "Message")
                screen.toolbar = [.flag]
                return screen
            case .settings:
                return ControllerScreen(settings, title: "Settings")
            }
        }
        let controller = stack.makeViewController()
        let window = window(showing: controller)
        #expect(identifiers(window) == ["toolbar.back", flexible, "compose"])

        stack.push(.message)
        try await settled(stack)
        #expect(identifiers(window) == ["toolbar.back", flexible, "flag"])
        let screen = try #require(stack.screen(for: stack.presentedEntries[1]))
        screen.toolbar = [.flag, .compose]
        StateUpdates.flush()
        #expect(identifiers(window) == ["toolbar.back", flexible, "flag", "compose"])

        // The buttons go to the screen's node view: enabled while its tree carries them out.
        let view = try #require(controller.view.subviews.first as? NodeNSView)
        let items = try #require(window.toolbar?.items)
        try #require(items.count == 4)
        #expect(view.validateToolbarItem(items[0]))
        #expect(view.validateToolbarItem(items[2]))
        #expect(!view.validateToolbarItem(items[3]))
        view.performCommand(items[2])
        #expect(flagged == 1)
        view.performCommand(items[0])
        try await settled(stack)
        #expect(stack.path == [.inbox])

        // Over a view of AppKit, the stack takes the back button.
        stack.push(.settings)
        try await settled(stack)
        let validator = try #require(controller as? NSToolbarItemValidation)
        let back = try #require(window.toolbar?.items.first)
        #expect(identifiers(window) == ["toolbar.back"])
        #expect(validator.validateToolbarItem(back))
        stack.close()
    }

    @Test @MainActor
    func aScreenAsAWindowsContentPutsUpItsCommandsAlone() throws {
        let screen = NodeScreen(Leaf(), title: "Compose")
        screen.toolbar = [.compose]
        let controller = ScreenViewController(screen)
        let window = window(showing: controller)
        #expect(identifiers(window) == [flexible, "compose"])
        screen.toolbar = []
        StateUpdates.flush()
        #expect(identifiers(window).isEmpty)
        controller.nodeView.host.detach()
    }

    @Test @MainActor
    func aCommandThatIsOnShowsACheckmarkInItsMenu() throws {
        var unreadOnly = false
        let root = Leaf()
        root.handle(.unreadOnly, isOn: { unreadOnly }) { unreadOnly.toggle() }
        let view = NodeNSView(root: root)
        let item = NSMenuItem(Command.unreadOnly)

        #expect(view.validateMenuItem(item))
        #expect(item.state == .off)
        view.performCommand(item)
        #expect(view.validateMenuItem(item))
        #expect(item.state == .on)
        view.host.detach()
    }
#endif
