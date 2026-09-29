#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import LayoutCore
    import Nodes
    import NodesAppKit
    import StateCore
    import Testing

    @testable import AppShellAppKit

    private enum Section: Hashable {
        case inbox
        case search
    }

    private enum Route: Hashable {
        case root
        case detail
    }

    extension Command {
        fileprivate static let compose = Command("compose", title: "Compose")
        fileprivate static let filter = Command("filter", title: "Filter")
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
    private func makeTabs() -> (Tabs<Section>, Stack<Route>, Watched) {
        let stack = Stack(root: Route.root) { _ in
            let screen = NodeScreen(Leaf(), title: "Inbox")
            screen.toolbar = [.compose]
            return screen
        }
        let search = Watched(Leaf(), title: "Search")
        search.toolbar = [.filter]
        let tabs = Tabs<Section>(
            selection: .inbox,
            [
                Tab(.inbox, title: "Inbox", symbol: "tray", content: stack),
                Tab(.search, title: "Search", symbol: "magnifyingglass", content: search),
            ]
        )
        return (tabs, stack, search)
    }

    /// The tabs as a window's content. The window is not put on screen: the controllers are
    /// told they appeared, the tabs' first, then the one that shows.
    @MainActor
    private func window(showing controller: NSTabViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.viewDidAppear()
        shown(controller).viewDidAppear()
        return window
    }

    /// The controller of the tab that shows.
    @MainActor
    private func shown(_ controller: NSTabViewController) -> NSViewController {
        controller.tabViewItems[controller.selectedTabViewItemIndex].viewController!
    }

    @MainActor
    private func identifiers(_ window: NSWindow) -> [String] {
        window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
    }

    private let flexible = NSToolbarItem.Identifier.flexibleSpace.rawValue

    @Test @MainActor
    func tabsShowEachContentInATabItemWithItsTitleAndSymbol() throws {
        let (tabs, stack, _) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? NSTabViewController)
        #expect(tabs.makeViewController() === controller)
        let window = window(showing: controller)
        defer { window.close() }

        #expect(controller.tabStyle == .segmentedControlOnTop)
        #expect(controller.tabViewItems.map(\.label) == ["Inbox", "Search"])
        #expect(controller.tabViewItems[0].image != nil)
        #expect(controller.tabViewItems[1].image != nil)
        #expect(controller.selectedTabViewItemIndex == 0)
        #expect(controller.tabViewItems[0].viewController is StackViewController)
        #expect(stack.presentedPath == [.root])
    }

    @Test @MainActor
    func aPickFromCodeMovesTheControlAndOneOfTheUserGoesToTheTabs() throws {
        let (tabs, _, _) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? NSTabViewController)
        let window = window(showing: controller)
        defer { window.close() }

        tabs.select(.search)
        StateUpdates.flush()
        #expect(controller.selectedTabViewItemIndex == 1)

        controller.selectedTabViewItemIndex = 0
        #expect(tabs.selection == .inbox)
    }

    @Test @MainActor
    func onlyTheSelectedTabsScreenAppearsAndThePickedOneReplacesIt() throws {
        let (tabs, _, search) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? NSTabViewController)
        let window = window(showing: controller)
        defer { window.close() }

        #expect(search.events.isEmpty)
        tabs.select(.search)
        #expect(search.events == ["appeared"])
        tabs.select(.inbox)
        #expect(search.events == ["appeared", "disappeared"])
    }

    @Test @MainActor
    func theWindowsToolbarIsTheOneOfTheTabThatShows() throws {
        let (tabs, _, _) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? NSTabViewController)
        let window = window(showing: controller)
        defer { window.close() }
        #expect(identifiers(window) == ["toolbar.back", flexible, "compose"])

        // The other tab shows: it puts up its own toolbar in place of the first's.
        tabs.select(.search)
        StateUpdates.flush()
        shown(controller).viewDidAppear()
        #expect(identifiers(window) == [flexible, "filter"])

        tabs.select(.inbox)
        StateUpdates.flush()
        shown(controller).viewDidAppear()
        #expect(identifiers(window) == ["toolbar.back", flexible, "compose"])
    }
#endif
