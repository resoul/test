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
        case root
        case detail
    }

    extension Command {
        fileprivate static let compose = Command("compose", title: "Compose")
        fileprivate static let newFolder = Command("newFolder", title: "New Folder")
    }

    @MainActor
    private final class Leaf: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    @MainActor
    private final class Watched: NodeScreen {
        var events: [String] = []
        override func appeared() { events.append("appeared") }
        override func disappeared() { events.append("disappeared") }
    }

    @MainActor
    private func makeSplit() -> (Split, Watched, Stack<Route>) {
        let sidebar = Watched(Leaf(), title: "Mailboxes")
        sidebar.toolbar = [.newFolder]
        let stack = Stack(root: Route.root) { _ in
            let screen = NodeScreen(Leaf(), title: "Inbox")
            screen.toolbar = [.compose]
            return screen
        }
        return (Split(sidebar: sidebar, content: stack), sidebar, stack)
    }

    /// The split as a window's content. The window is not put on screen: the controllers are
    /// told they appeared, the split's first.
    @MainActor
    private func window(showing controller: NSSplitViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.viewDidAppear()
        for item in controller.splitViewItems {
            item.viewController.viewDidAppear()
        }
        return window
    }

    private let flexible = NSToolbarItem.Identifier.flexibleSpace.rawValue

    @Test @MainActor
    func aSplitShowsTheSidebarInASidebarItemAndTheContentBesideIt() throws {
        let (split, _, stack) = makeSplit()
        let controller = try #require(split.makeViewController() as? NSSplitViewController)
        #expect(split.makeViewController() === controller)
        let window = window(showing: controller)
        defer { window.close() }

        #expect(controller.splitViewItems.count == 2)
        #expect(controller.splitViewItems[0].behavior == .sidebar)
        #expect(controller.splitViewItems[1].viewController is StackViewController)
        #expect(stack.presentedPath == [.root])
    }

    @Test @MainActor
    func aWindowHasRoomForBothSoBothScreensAppear() throws {
        let (split, sidebar, _) = makeSplit()
        let controller = try #require(split.makeViewController() as? NSSplitViewController)
        let window = window(showing: controller)
        defer { window.close() }

        #expect(sidebar.events == ["appeared"])
        split.showContent()
        // Nothing to collapse on a Mac: the sidebar stays.
        #expect(sidebar.events == ["appeared"])
    }

    @Test @MainActor
    func theWindowsToolbarIsTheContentsNotTheSidebars() throws {
        let (split, _, _) = makeSplit()
        let controller = try #require(split.makeViewController() as? NSSplitViewController)
        let window = window(showing: controller)
        defer { window.close() }

        #expect(
            window.toolbar?.items.map(\.itemIdentifier.rawValue) == [
                "toolbar.back", flexible, "compose",
            ]
        )
    }

    @Test @MainActor
    func showSidebarBringsBackASidebarTheUserHid() throws {
        let (split, _, _) = makeSplit()
        let controller = try #require(split.makeViewController() as? NSSplitViewController)
        let window = window(showing: controller)
        defer { window.close() }
        controller.splitViewItems[0].isCollapsed = true

        split.showContent()
        StateUpdates.flush()
        #expect(controller.splitViewItems[0].isCollapsed)
        // Going to the sidebar is what the split's state says: it changes from the content
        // shown to the sidebar shown.
        split.showContent()
        split.showSidebar()
        StateUpdates.flush()
        #expect(!controller.splitViewItems[0].isCollapsed)
    }
#endif
