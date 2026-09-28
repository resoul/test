// The demo screen in a Mac window, in a stack of screens — a message opened in the inbox
// slides in over it — with the screen's commands in the menu bar: the `LayoutDemoMac` scheme
// of `Demo.xcodeproj`.
import AppKit
import AppShell
import AppShellAppKit
import Nodes
import NodesAppKit

/// Opens a window showing the demo screen.
@MainActor
final class DemoApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = DemoModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openMessages(from: ProcessInfo.processInfo.environment)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = model.stack.makeViewController()
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        let quit = NSMenuItem(
            title: "Quit Layout Demo",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let app = NSMenuItem(title: "Layout Demo", action: nil, keyEquivalent: "")
        app.submenu = NSMenu(title: "Layout Demo")
        app.submenu?.addItem(quit)
        let menu = NSMenu(title: "")
        menu.addItem(app)
        menu.addItem(NSMenuItem(DemoModel.menu))
        menu.addItem(NSMenuItem(Menu("Go") { Command.back }))
        NSApplication.shared.mainMenu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = DemoApp()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.activate(ignoringOtherApps: true)
application.run()
