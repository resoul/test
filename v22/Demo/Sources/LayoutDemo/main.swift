#if canImport(AppKit)
    import AppKit
    import Nodes
    import NodesAppKit

    /// Opens the window: the node screen above a bar of buttons that change its state.
    @MainActor
    final class DemoApp: NSObject, NSApplicationDelegate {
        private var window: NSWindow?
        private let profiles = [
            Profile(
                name: "Ada Lovelace",
                bio: "Wrote the first program for a machine that did not exist yet.",
                color: Color(red: 0.93, green: 0.45, blue: 0.35)
            ),
            Profile(
                name: "Grace Hopper",
                bio: "Built the first compiler, and found the first actual bug.",
                color: Color(red: 0.36, green: 0.66, blue: 0.47)
            ),
        ]
        private let names = ["Ada Lovelace", "Augusta Ada King", "Countess of Lovelace"]
        private var nameIndex = 0

        func applicationDidFinishLaunching(_ notification: Notification) {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
            let screen = content.addSubnode(
                Screen(profiles: profiles) { [weak self] in self?.renameAda() }
            )
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

        private func renameAda() {
            nameIndex = (nameIndex + 1) % names.count
            profiles[0].name.value = names[nameIndex]
        }
    }

    let application = NSApplication.shared
    let delegate = DemoApp()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.activate(ignoringOtherApps: true)
    application.run()
#endif
