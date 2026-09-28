// The demo screen in a Mac window, with the screen's commands in the menu bar: the
// `LayoutDemoMac` scheme of `Demo.xcodeproj`.
import AppKit
import Nodes
import NodesAppKit

/// Opens a window showing the demo screen.
@MainActor
final class DemoApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = DemoModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
        let screen = content.addSubnode(model.screen)
        screen.frame = content.bounds
        screen.autoresizingMask = [.width, .height]
        screen.host.solvesInBackground = true

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Layout demo"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        // The keyboard, and with it the menu's commands, go to the screen from the start.
        window.makeFirstResponder(screen)
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
