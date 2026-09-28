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
        return window
    }

    @Test @MainActor
    func aPresentationIsASheetOfTheWindowAndEscapeClosesIt() throws {
        let stack = Stack(root: Route.inbox) { _ in NodeScreen(Leaf(), title: "Inbox") }
        let controller = stack.makeViewController()
        let window = window(showing: controller)
        let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))
        let compose = NodeScreen(Leaf(), title: "Compose")
        let presentation = Presentation(compose, style: .fullScreen)
        var dismissed = 0
        presentation.onDismissed = { dismissed += 1 }

        inbox.present(presentation)
        #expect(presentation.isShown)
        let sheet = try #require(controller.presentedViewControllers?.first)
        #expect(sheet.view.frame.size == PresentedViewController.standardSize)

        // Escape in the sheet's tree: the presentation cancels.
        let content = try #require(sheet.children.first as? ScreenViewController)
        #expect(content.nodeView.host.perform(.cancel))
        #expect(!presentation.isShown)
        #expect(controller.presentedViewControllers?.isEmpty ?? true)
        #expect(dismissed == 1)
        #expect(inbox.presentation == nil)
        window.close()
        stack.close()
    }

    @Test @MainActor
    func escapeOverAViewOfAppKitAsksAPresentationThatCannotClose() throws {
        let stack = Stack(root: Route.inbox) { _ in NodeScreen(Leaf(), title: "Inbox") }
        let controller = stack.makeViewController()
        let window = window(showing: controller)
        let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))
        let settings = NSViewController()
        settings.view = NSView()
        settings.preferredContentSize = NSSize(width: 300, height: 200)
        let presentation = Presentation(ControllerScreen(settings))
        var attempts = 0
        presentation.onDismissAttempt = { attempts += 1 }
        presentation.isDismissible = false
        inbox.present(presentation)
        let sheet = try #require(controller.presentedViewControllers?.first)
        #expect(sheet.view.frame.size == NSSize(width: 300, height: 200))

        sheet.cancelOperation(nil)
        #expect(attempts == 1)
        #expect(presentation.isShown)
        presentation.dismiss()
        #expect(!presentation.isShown)
        window.close()
        stack.close()
    }

    @Test @MainActor
    func aPresentationAskedForOutOfAWindowShowsWhenTheStackAppears() throws {
        let stack = Stack(root: Route.inbox) { _ in NodeScreen(Leaf(), title: "Inbox") }
        let controller = stack.makeViewController()
        controller.loadView()
        let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))
        let presentation = Presentation(NodeScreen(Leaf()))
        inbox.present(presentation)
        #expect(!presentation.isShown)

        let window = window(showing: controller)
        controller.viewDidAppear()
        #expect(presentation.isShown)
        stack.pop()
        stack.close()
        #expect(!presentation.isShown)
        window.close()
    }
#endif
