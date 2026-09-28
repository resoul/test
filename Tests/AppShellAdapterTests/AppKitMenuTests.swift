#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import AppShellAppKit
    import Nodes
    import NodesAppKit
    import Testing

    @Test @MainActor
    func theMainMenuPutsTheAppsMenusBetweenTheStandardOnes() throws {
        let menu = NSMenu(standardAround: MenuBar { Menu("Message") { Command.back } })

        #expect(menu.items.map(\.title).dropFirst() == ["File", "Edit", "Message", "Window"])
        let close = try #require(menu.items[1].submenu?.items.first)
        #expect(close.title == "Close Window")
        #expect(close.keyEquivalent == "w")
        #expect(close.action == #selector(NodeNSView.performCommand(_:)))
        let quit = try #require(menu.items[0].submenu?.items.last)
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(NSApplication.shared.windowsMenu === menu.items.last?.submenu)
    }
#endif
