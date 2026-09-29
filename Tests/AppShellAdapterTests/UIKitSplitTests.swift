#if canImport(UIKit)
    import AppShell
    import Foundation
    import AppShellUIKit
    import LayoutCore
    import Nodes
    import NodesUIKit
    import StateCore
    import Testing
    import UIKit

    private enum Route: Hashable {
        case root
        case detail
    }

    @MainActor
    private final class Leaf: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    @MainActor
    private func makeSplit() -> (Split, Stack<Route>, NodeScreen) {
        let stack = Stack(root: Route.root) { route in
            NodeScreen(Leaf(), title: route == .root ? "Inbox" : "Message")
        }
        let sidebar = NodeScreen(Leaf(), title: "Mailboxes")
        return (Split(sidebar: sidebar, content: stack), stack, sidebar)
    }

    @MainActor
    private func window(showing controller: UIViewController, size: CGSize) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    private final class Watched: NodeScreen {
        var events: [String] = []
        override func appeared() { events.append("appeared") }
        override func disappeared() { events.append("disappeared") }
    }

    /// Whether the run is on an iPad, where the split has room for both columns.
    private let onPad =
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?
        .hasPrefix("iPad") ?? false

    /// Waits for what the split view controller does at the next turns of the main actor.
    @MainActor
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test @MainActor
    func aSplitShowsTheSidebarInTheFirstColumnAndTheContentInTheSecond() throws {
        let (split, stack, _) = makeSplit()
        let controller = try #require(split.makeViewController() as? UISplitViewController)
        #expect(split.makeViewController() === controller)
        let window = window(showing: controller, size: CGSize(width: 390, height: 700))
        defer { window.isHidden = true }

        let sidebar = try #require(
            controller.viewController(for: .primary) as? UINavigationController
        )
        #expect(sidebar.viewControllers.first?.navigationItem.title == "Mailboxes")
        let content = try #require(
            controller.viewController(for: .secondary) as? UINavigationController
        )
        #expect(content.viewControllers.first?.navigationItem.title == "Inbox")
        #expect(stack.presentedPath == [.root])
    }

    @Test(.enabled(if: !onPad)) @MainActor
    func whereRoomIsShortTheSidebarShowsFirstAndTheContentComesOnShowContent() async throws {
        let (split, stack, _) = makeSplit()
        let controller = try #require(split.makeViewController() as? UISplitViewController)
        let window = window(showing: controller, size: CGSize(width: 390, height: 700))
        defer { window.isHidden = true }
        let content = try #require(
            controller.viewController(for: .secondary) as? UINavigationController
        )

        try await until { controller.isCollapsed }
        #expect(controller.isCollapsed)
        #expect(!split.isContentShown)
        #expect(content.parent == nil)

        // The content goes over the sidebar, whole: its stack is its own.
        split.showContent()
        try await until { content.parent != nil }
        #expect(content.parent != nil)
        stack.push(.detail)
        try await until { stack.presentedPath == stack.path }
        #expect(stack.presentedPath == [.root, .detail])
        #expect(content.viewControllers.count == 2)

        // The sidebar again, and the stack keeps its path.
        split.showSidebar()
        try await until { content.parent == nil }
        #expect(content.parent == nil)
        #expect(stack.path == [.root, .detail])
    }

    @Test(.enabled(if: !onPad)) @MainActor
    func theUsersGoingBetweenTheColumnsWhereOneShowsGoesToTheSplit() async throws {
        let (split, _, _) = makeSplit()
        let controller = try #require(split.makeViewController() as? UISplitViewController)
        let window = window(showing: controller, size: CGSize(width: 390, height: 700))
        defer { window.isHidden = true }
        try await until { controller.isCollapsed }

        controller.delegate?.splitViewController?(controller, willShow: .secondary)
        #expect(split.isContentShown)
        controller.delegate?.splitViewController?(controller, willShow: .primary)
        #expect(!split.isContentShown)
    }

    @Test(.enabled(if: !onPad)) @MainActor
    func onlyTheColumnThatShowsHasItsScreenAppear() async throws {
        let sidebar = Watched(Leaf(), title: "Mailboxes")
        let content = Watched(Leaf(), title: "Inbox")
        let split = Split(sidebar: sidebar, content: content)
        let controller = try #require(split.makeViewController() as? UISplitViewController)
        let window = window(showing: controller, size: CGSize(width: 390, height: 700))
        defer { window.isHidden = true }
        try await until { controller.isCollapsed && sidebar.events == ["appeared"] }

        #expect(sidebar.events == ["appeared"])
        #expect(content.events.isEmpty)
        split.showContent()
        try await until { content.events == ["appeared"] }
        #expect(sidebar.events == ["appeared", "disappeared"])
        #expect(content.events == ["appeared"])
    }

    @Test(.enabled(if: onPad)) @MainActor
    func withRoomForBothBothColumnsShowAndTheChoiceStaysForNarrowing() async throws {
        let sidebar = Watched(Leaf(), title: "Mailboxes")
        let content = Watched(Leaf(), title: "Inbox")
        let split = Split(sidebar: sidebar, content: content)
        let controller = try #require(split.makeViewController() as? UISplitViewController)
        let window = window(showing: controller, size: CGSize(width: 1024, height: 700))
        defer { window.isHidden = true }
        try await until { content.events == ["appeared"] }

        #expect(!controller.isCollapsed)
        #expect(sidebar.events == ["appeared"])
        #expect(content.events == ["appeared"])
        split.showContent()
        #expect(split.isContentShown)
        #expect(!controller.isCollapsed)
        #expect(sidebar.events == ["appeared"])
    }
#endif
