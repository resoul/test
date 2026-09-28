#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import AppShellAppKit
    import LayoutCore
    import Nodes
    import NodesAppKit
    import StateCore
    import Testing

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
    private func makeStack(settings: NSViewController = NSViewController()) -> Stack<Route> {
        if settings.isViewLoaded == false {
            settings.view = NSView()
        }
        return Stack(root: Route.inbox) { route in
            switch route {
            case .inbox: NodeScreen(Leaf(), title: "Inbox")
            case .message(let id): NodeScreen(Leaf(), title: "Message \(id)")
            case .settings: ControllerScreen(settings, title: "Settings")
            }
        }
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
        return window
    }

    @MainActor
    private func settled(_ stack: Stack<Route>) async throws {
        for _ in 0..<200 where stack.presentedPath != stack.path {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stack.presentedPath == stack.path)
    }

    @MainActor
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16)
        -> NSEvent
    {
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
    func aStackShowsItsTopScreenAloneAndTakesItsTitle() throws {
        let stack = makeStack()
        let controller = stack.makeViewController()
        #expect(stack.makeViewController() === controller)
        controller.loadView()
        #expect(controller.title == "Inbox")
        #expect(controller.view.subviews.count == 1)

        stack.push(.message(1))
        #expect(stack.presentedPath == [.inbox, .message(1)])
        #expect(controller.view.subviews.count == 1)
        #expect(controller.title == "Message 1")
        let message = try #require(stack.screen(for: stack.presentedEntries[1]))
        message.title = "Re: Message 1"
        StateUpdates.flush()
        #expect(controller.title == "Re: Message 1")
        stack.close()
    }

    @Test @MainActor
    func commandMinusBracketGoesBackAndTheFocusComesBack() async throws {
        let stack = makeStack()
        let controller = stack.makeViewController()
        let window = window(showing: controller)
        let inbox = try #require(stack.screen(for: stack.presentedEntries[0]) as? NodeScreen)
        let inboxView = try #require(controller.view.subviews.first as? NodeNSView)
        inboxView.layout()
        window.makeFirstResponder(inboxView)
        inboxView.host.focus(inbox.root.id)

        stack.push(.message(1))
        try await settled(stack)
        #expect(!inbox.root.isShown)
        let messageView = try #require(controller.view.subviews.first as? NodeNSView)
        #expect(window.firstResponder === messageView)

        messageView.keyDown(with: key("[", .command, keyCode: 33))
        try await settled(stack)
        #expect(stack.path == [.inbox])
        #expect(inbox.root.isShown)
        #expect(window.firstResponder === inboxView)
        #expect(inboxView.host.focusedNode == inbox.root.id)
        window.close()
        stack.close()
    }

    @Test @MainActor
    func overAControllerOfAppKitTheMenuAndCommandMinusBracketGoBack() throws {
        let stack = makeStack()
        let controller = stack.makeViewController()
        let window = window(showing: controller)
        stack.push(.settings)
        let item = NSMenuItem(Command.back)
        let validation = try #require(controller as? NSMenuItemValidation)
        #expect(validation.validateMenuItem(item))

        #expect(controller.view.performKeyEquivalent(with: key("[", .command, keyCode: 33)))
        #expect(stack.path == [.inbox])
        #expect(!validation.validateMenuItem(item))
        window.close()
        stack.close()
    }
#endif
