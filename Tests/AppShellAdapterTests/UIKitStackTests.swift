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
        case message(Int)
        case settings
    }

    @MainActor
    private final class Leaf: Node {
        override init() {
            super.init()
            onTap = {}
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    @MainActor
    private func makeStack(settings: UIViewController = UIViewController()) -> Stack<Route> {
        Stack(root: Route.inbox) { route in
            switch route {
            case .inbox: NodeScreen(Leaf(), title: "Inbox")
            case .message(let id): NodeScreen(Leaf(), title: "Message \(id)")
            case .settings: ControllerScreen(settings, title: "Settings")
            }
        }
    }

    /// Waits for the platform's move to end, and lays out what shows.
    @MainActor
    private func settled(_ stack: Stack<Route>, in window: UIWindow) async throws {
        for _ in 0..<200 where stack.presentedPath != stack.path {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stack.presentedPath == stack.path)
        window.layoutIfNeeded()
    }

    /// Waits for the stack to show `path`: a move the platform begins changes the stack only
    /// when it ends.
    @MainActor
    private func shows(_ path: [Route], _ stack: Stack<Route>, in window: UIWindow) async throws {
        for _ in 0..<200 where stack.presentedPath != path || stack.path != path {
            try await Task.sleep(for: .milliseconds(10))
        }
        window.layoutIfNeeded()
    }

    @MainActor
    private func window(showing controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @Test @MainActor
    func aStackShowsItsScreensInOneNavigationController() throws {
        let settings = UIViewController()
        let stack = makeStack(settings: settings)
        let controller = try #require(stack.makeViewController() as? UINavigationController)
        #expect(stack.makeViewController() === controller)
        #expect(controller.viewControllers.count == 1)
        #expect(controller.viewControllers[0].navigationItem.title == "Inbox")
        #expect(stack.presentedPath == [.inbox])

        stack.push(.message(1))
        stack.push(.settings)
        #expect(controller.viewControllers.count == 3)
        #expect(controller.viewControllers[2] === settings)
        #expect(controller.viewControllers[2].navigationItem.title == "Settings")
        stack.close()
    }

    @Test @MainActor
    func theScreenUnderTheNextStopsShowingAndAPoppedTreeLeavesItsHost() async throws {
        let stack = makeStack()
        let controller = try #require(stack.makeViewController() as? UINavigationController)
        let window = window(showing: controller)
        let inbox = try #require(stack.screen(for: stack.presentedEntries[0]) as? NodeScreen)
        #expect(inbox.root.isShown)

        stack.push(.message(1))
        try await settled(stack, in: window)
        let message = try #require(stack.screen(for: stack.presentedEntries[1]) as? NodeScreen)
        #expect(!inbox.root.isShown)
        #expect(inbox.root.isMounted)
        #expect(message.root.isShown)
        #expect(message.isPresented && !inbox.isPresented)

        stack.pop()
        try await settled(stack, in: window)
        #expect(inbox.root.isShown)
        #expect(!message.root.isMounted)
        window.isHidden = true
        stack.close()
    }

    @Test @MainActor
    func theNavigationControllerGoingBackByItselfTakesTheStackWithIt() async throws {
        let stack = makeStack()
        let controller = try #require(stack.makeViewController() as? UINavigationController)
        let window = window(showing: controller)
        stack.push(.message(1))
        try await settled(stack, in: window)
        stack.push(.message(2))
        try await settled(stack, in: window)

        // The back button: the platform pops, and the stack follows.
        controller.popViewController(animated: true)
        try await shows([.inbox, .message(1)], stack, in: window)
        #expect(stack.path == [.inbox, .message(1)])
        #expect(stack.presentedPath == [.inbox, .message(1)])
        #expect(controller.viewControllers.count == 2)

        // The back button's menu: back to the root at once.
        stack.push(.message(2))
        try await settled(stack, in: window)
        controller.popToRootViewController(animated: false)
        #expect(stack.path == [.inbox])
        #expect(controller.viewControllers.count == 1)
        // At the root, the platform does not go back either.
        #expect(controller.popViewController(animated: false) == nil)
        window.isHidden = true
        stack.close()
    }

    @Test @MainActor
    func aScreensNewTitleShowsInTheNavigationBar() throws {
        let stack = makeStack()
        let controller = try #require(stack.makeViewController() as? UINavigationController)
        let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))

        inbox.title = "Inbox (3)"
        StateUpdates.flush()
        #expect(controller.viewControllers[0].navigationItem.title == "Inbox (3)")
        stack.close()
    }

    @Test @MainActor
    func theNavigationControllersOwnCommandMinusBracketTakesTheStackBack() async throws {
        let stack = makeStack()
        let controller = try #require(stack.makeViewController() as? UINavigationController)
        let window = window(showing: controller)
        stack.push(.settings)
        try await settled(stack, in: window)
        // Over nodes, their view takes Command-[ first; over a controller of UIKit, the
        // navigation controller's own does.
        let back = try #require(controller.keyCommands?.first { $0.input == "[" })

        controller.perform(back.action!, with: back)
        try await shows([.inbox], stack, in: window)
        #expect(stack.path == [.inbox])
        window.isHidden = true
        stack.close()
    }
#endif
