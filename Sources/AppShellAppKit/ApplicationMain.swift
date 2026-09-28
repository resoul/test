// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import Nodes
    import NodesAppKit

    extension Application {
        /// The entry point of a Mac app: `@main` on the type calls it. Each scene of the app is
        /// a window; the first opens at launch. It puts up the standard menus around the
        /// app's, and brings links in — URLs the app is asked to open (its `Info.plist` names
        /// the schemes).
        ///
        /// Ownership: the app runs until it quits. Isolation: MainActor. Errors: none.
        /// Cancellation: quitting the app.
        public static func main() {
            let application = NSApplication.shared
            let delegate = ShellApplicationDelegate(shell: Shell(application: Self()))
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            application.run()
            _ = delegate
        }
    }

    /// The app's delegate: a window for each scene session, the menus, the links.
    @MainActor
    final class ShellApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
        let shell: Shell
        /// The window of each session.
        private var windows: [ObjectIdentifier: NSWindow] = [:]

        init(shell: Shell) {
            self.shell = shell
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApplication.shared.mainMenu = NSMenu(standardAround: shell.application.menuBar)
            if let session = shell.makeSession() {
                show(session)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            shell.firstSceneShown()
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            let key = NSApplication.shared.keyWindow.flatMap(session(of:))
            for url in urls {
                shell.open(url, in: key)
            }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }

        func applicationDidHide(_ notification: Notification) {
            shell.sessions.forEach(updateActivation(of:))
        }

        func applicationDidUnhide(_ notification: Notification) {
            shell.sessions.forEach(updateActivation(of:))
        }

        private func show(_ session: SceneSession) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = contentController(for: session.content)
            if window.title.isEmpty {
                window.title = session.kind.title
            }
            window.setContentSize(NSSize(width: 640, height: 560))
            window.delegate = self
            window.center()
            windows[ObjectIdentifier(session)] = window
            session.canClose = true
            session.closePlatformScene = { [weak window] in window?.performClose(nil) }
            window.makeKeyAndOrderFront(nil)
            updateActivation(of: session)
        }

        private func contentController(for content: any SceneContent) -> NSViewController {
            if let stack = content as? any PresentedStack {
                return stack.makeViewController()
            }
            if let screen = content as? ControllerScreen {
                return screen.controller
            }
            if let screen = content as? NodeScreen {
                return ScreenViewController(screen)
            }
            return NSViewController()
        }

        // MARK: - NSWindowDelegate

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, let session = session(of: window)
            else { return }

            windows[ObjectIdentifier(session)] = nil
            shell.sessionClosed(session)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            changed(notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            changed(notification)
        }

        func windowDidMiniaturize(_ notification: Notification) {
            changed(notification)
        }

        func windowDidDeminiaturize(_ notification: Notification) {
            changed(notification)
        }

        private func changed(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, let session = session(of: window)
            else { return }

            updateActivation(of: session)
        }

        private func session(of window: NSWindow) -> SceneSession? {
            shell.sessions.first { windows[ObjectIdentifier($0)] === window }
        }

        private func updateActivation(of session: SceneSession) {
            guard let window = windows[ObjectIdentifier(session)] else { return }

            if window.isMiniaturized || NSApplication.shared.isHidden || !window.isVisible {
                session.setActivation(.background)
            } else {
                session.setActivation(window.isKeyWindow ? .active : .inactive)
            }
        }
    }

    extension PresentedStack {
        /// The stack's view controller, whatever its routes.
        fileprivate func makeViewController() -> NSViewController {
            if let existing = platformContainer as? StackViewController {
                return existing
            }
            let controller = StackViewController(stack: self)
            platformContainer = controller
            return controller
        }
    }

    extension NSMenu {
        /// A Mac app's main menu: the app's menu (About, Hide, Quit), File (Close Window),
        /// Edit (Undo to Select All), the menus of `bar`, and Window. Standard items go to
        /// AppKit's own actions; Close Window is `Command.closeWindow`, carried out by the
        /// window whose content has the keyboard.
        ///
        /// Ownership: returns a new menu. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public convenience init(standardAround bar: MenuBar) {
            self.init(title: "")
            let name = ProcessInfo.processInfo.processName

            let app = NSMenu(title: name)
            app.addItem(
                withTitle: "About \(name)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
            app.addItem(.separator())
            app.addItem(
                withTitle: "Hide \(name)",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"
            )
            let others = app.addItem(
                withTitle: "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h"
            )
            others.keyEquivalentModifierMask = [.command, .option]
            app.addItem(
                withTitle: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""
            )
            app.addItem(.separator())
            app.addItem(
                withTitle: "Quit \(name)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            addItem(submenu(app))

            let file = NSMenu(title: "File")
            file.addItem(NSMenuItem(Command.closeWindow))
            addItem(submenu(file))

            let edit = NSMenu(title: "Edit")
            edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = edit.addItem(
                withTitle: "Redo",
                action: Selector(("redo:")),
                keyEquivalent: "z"
            )
            redo.keyEquivalentModifierMask = [.command, .shift]
            edit.addItem(.separator())
            edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            edit.addItem(
                withTitle: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
            edit.addItem(
                withTitle: "Select All",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
            addItem(submenu(edit))

            for menu in bar.menus {
                addItem(NSMenuItem(menu))
            }

            let window = NSMenu(title: "Window")
            window.addItem(
                withTitle: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
            window.addItem(
                withTitle: "Zoom",
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""
            )
            window.addItem(.separator())
            window.addItem(
                withTitle: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                keyEquivalent: ""
            )
            addItem(submenu(window))
            NSApplication.shared.windowsMenu = window
        }

        private func submenu(_ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }
    }
#endif
