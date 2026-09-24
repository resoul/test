#if canImport(AppKit)
    import AppKit
    import DemoScreens
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
            self.window = window
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
#endif
