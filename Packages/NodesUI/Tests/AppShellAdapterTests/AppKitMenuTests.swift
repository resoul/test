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

    @Test @MainActor
    func theMenusHaveNewWindowAndSettingsOnlyWhenTheAppHasThem() throws {
        let plain = NSMenu(standardAround: MenuBar {})
        #expect(plain.items[1].submenu?.items.map(\.title) == ["Close Window"])
        #expect(!(plain.items[0].submenu?.items.map(\.title).contains("Settings…") ?? true))

        let menu = NSMenu(standardAround: MenuBar {}, newWindow: true, settings: true)
        let file = try #require(menu.items[1].submenu)
        #expect(file.items.map(\.title) == ["New Window", "Close Window"])
        #expect(file.items[0].keyEquivalent == "n")
        #expect(file.items[0].action == #selector(NodeNSView.performCommand(_:)))
        // Settings… follows About, before Hide.
        let app = try #require(menu.items[0].submenu)
        let titles = app.items.map(\.title)
        #expect(
            titles.prefix(4).map { $0.hasPrefix("About") ? "About" : $0 } == [
                "About", "", "Settings…", "",
            ]
        )
        let settings = try #require(app.items.first { $0.title == "Settings…" })
        #expect(settings.keyEquivalent == ",")
    }
#endif
