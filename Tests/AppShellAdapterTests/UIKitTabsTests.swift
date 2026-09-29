#if canImport(UIKit)
    import AppShell
    import AppShellUIKit
    import LayoutCore
    import Nodes
    import NodesUIKit
    import StateCore
    import Testing
    import UIKit

    private enum Section: Hashable {
        case inbox
        case search
    }

    private enum Route: Hashable {
        case root
        case detail
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

    extension Command {
        fileprivate static let flag = Command("flag", title: "Flag")
    }

    @MainActor
    private func window(showing controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    private func makeTabs() -> (Tabs<Section>, Stack<Route>, Watched) {
        let stack = Stack(root: Route.root) { route in
            NodeScreen(Leaf(), title: route == .root ? "Inbox" : "Message")
        }
        let search = Watched(Leaf(), title: "Search")
        let tabs = Tabs<Section>(
            selection: .inbox,
            [
                Tab(.inbox, title: "Inbox", symbol: "tray", content: stack),
                Tab(.search, title: "Search", symbol: "magnifyingglass", content: search),
            ]
        )
        return (tabs, stack, search)
    }

    @Test @MainActor
    func tabsShowEachContentInATabOfTheBarWithItsTitleAndSymbol() throws {
        let (tabs, stack, _) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? UITabBarController)
        #expect(tabs.makeViewController() === controller)
        let window = window(showing: controller)
        defer { window.isHidden = true }

        #expect(controller.viewControllers?.count == 2)
        #expect(controller.viewControllers?[0] is UINavigationController)
        #expect(controller.viewControllers?[0].tabBarItem.title == "Inbox")
        #expect(controller.viewControllers?[0].tabBarItem.image != nil)
        #expect(controller.viewControllers?[1].tabBarItem.title == "Search")
        #expect(controller.selectedIndex == 0)
        #expect(stack.presentedPath == [.root])
    }

    @Test @MainActor
    func aPickFromCodeMovesTheBarAndOneOfTheUserGoesToTheTabs() async throws {
        let (tabs, _, _) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? UITabBarController)
        let window = window(showing: controller)
        defer { window.isHidden = true }

        tabs.select(.search)
        // The bar follows at the next turn of the main actor, as titles do.
        for _ in 0..<200 where controller.selectedIndex != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.selectedIndex == 1)

        // The user taps the first tab: the bar tells its delegate, and the tabs follow.
        controller.selectedIndex = 0
        controller.delegate?.tabBarController?(
            controller,
            didSelect: controller.viewControllers![0]
        )
        #expect(tabs.selection == .inbox)
    }

    @Test @MainActor
    func onlyTheSelectedTabsScreenAppearsAndThePickedOneReplacesIt() throws {
        let (tabs, _, search) = makeTabs()
        let controller = try #require(tabs.makeViewController() as? UITabBarController)
        let window = window(showing: controller)
        defer { window.isHidden = true }

        #expect(search.events.isEmpty)
        tabs.select(.search)
        #expect(search.events == ["appeared"])
        tabs.select(.inbox)
        #expect(search.events == ["appeared", "disappeared"])
    }

    @Test @MainActor
    func theScreenOfTheSelectedTabIsOnTheChainOfTheTabsAndOutToTheWindow() throws {
        let (tabs, stack, _) = makeTabs()
        var flagged = 0
        tabs.handle(.flag) { flagged += 1 }
        let controller = try #require(tabs.makeViewController() as? UITabBarController)
        let window = window(showing: controller)
        defer { window.isHidden = true }

        let root = try #require(stack.screen(for: stack.presentedEntries[0]))
        #expect(root.perform(.flag))
        #expect(flagged == 1)
    }
#endif
