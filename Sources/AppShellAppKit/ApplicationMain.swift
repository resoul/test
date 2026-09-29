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
        /// What the last run kept of each kind of scene (`SceneSession.restorationData()`),
        /// until a scene of the kind takes it.
        private var restorations: [String: Data] = [:]
        private static let restorationPrefix = "restoration."

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

        // MARK: - State restoration

        func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
            true
        }

        /// The app is asked for its state: each kind of scene keeps that of its first window.
        func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
            var kept: Set<String> = []
            for session in shell.sessions where !kept.contains(session.kind.id) {
                guard let data = session.restorationData() else { continue }

                kept.insert(session.kind.id)
                coder.encode(
                    data as NSData,
                    forKey: Self.restorationPrefix + session.kind.id
                )
            }
        }

        /// The state comes, before the first window is made or after it: a window takes what
        /// its kind kept, once.
        func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
            for kind in shell.application.scenes.map(\.id) {
                guard
                    let data = coder.decodeObject(
                        of: NSData.self,
                        forKey: Self.restorationPrefix + kind
                    ) as Data?
                else { continue }

                restorations[kind] = data
                if let session = shell.sessions.first(where: { $0.kind.id == kind }) {
                    restorations[kind] = nil
                    session.restore(from: data)
                }
            }
        }

        private func show(_ session: SceneSession) {
            if let data = restorations.removeValue(forKey: session.kind.id) {
                session.restore(from: data)
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            // A window without an identifier has no state of its own for the system to keep,
            // and the app's state, with the scene's snapshot, is kept along with the windows'.
            window.identifier = NSUserInterfaceItemIdentifier("scene." + session.kind.id)
            window.isRestorable = true
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
