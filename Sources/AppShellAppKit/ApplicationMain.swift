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
        /// What the last run kept of its windows, in the order they were open, until a window of
        /// the kind takes it.
        private var pending: [KeptWindow] = []
        private static let restorationKey = "windows"
        /// Whether the first window is made: the kept state that comes before waits for it.
        private var hasLaunched = false

        /// One window as the last run left it: its kind, and the state of its containers when
        /// any opted in — a window with none still comes back, as it was the first time.
        private struct KeptWindow: Codable {
            var kind: String
            var state: Data?
        }

        init(shell: Shell) {
            self.shell = shell
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let scenes = shell.application.scenes
            NSApplication.shared.mainMenu = NSMenu(
                standardAround: shell.application.menuBar,
                newWindow: scenes.first { $0.role == .standard }?.allowsMultiple ?? false,
                settings: scenes.contains { $0.role == .settings }
            )
            shell.platformScenes = PlatformScenes(canOpen: { _ in true }) { [weak self] kind in
                guard let self, let session = shell.makeSession(kind.id) else { return }

                show(session)
            }
            if let session = shell.makeSession() {
                show(session)
            }
            hasLaunched = true
            openKeptWindows()
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

        /// The app is asked for its state: every window is kept, in the order they opened, each
        /// with the state of its own containers.
        func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
            guard shell.application.restoresState else { return }

            let windows = shell.sessions.filter { $0.kind.role == .standard }.map {
                KeptWindow(kind: $0.kind.id, state: $0.restorationData())
            }
            guard let data = try? JSONEncoder().encode(windows) else { return }

            coder.encode(data as NSData, forKey: Self.restorationKey)
        }

        /// The state comes, before the first window is made or after it: each window takes what
        /// the window of its place kept, and the ones the last run had more of open.
        func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
            guard shell.application.restoresState,
                let data = coder.decodeObject(of: NSData.self, forKey: Self.restorationKey)
                    as Data?,
                let windows = try? JSONDecoder().decode([KeptWindow].self, from: data)
            else { return }

            pending = windows
            shell.sessions.forEach(putBackState(in:))
            if hasLaunched {
                openKeptWindows()
            }
        }

        /// Puts into `session` what the first kept window of its kind held, once.
        private func putBackState(in session: SceneSession) {
            guard let index = pending.firstIndex(where: { $0.kind == session.kind.id }) else {
                return
            }

            let kept = pending.remove(at: index)
            if let state = kept.state {
                session.restore(from: state)
            }
        }

        /// Opens a window for each kept one no window took: the app had more than one open.
        private func openKeptWindows() {
            let kept = pending
            pending = []
            for window in kept {
                let kinds = shell.application.scenes
                guard let kind = kinds.first(where: { $0.id == window.kind }),
                    kind.allowsMultiple
                        || !shell.sessions.contains(where: { $0.kind.id == kind.id }),
                    let session = shell.makeSession(kind.id)
                else { continue }

                if let state = window.state {
                    session.restore(from: state)
                }
                show(session)
            }
        }

        private func show(_ session: SceneSession) {
            putBackState(in: session)
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
            if let key = NSApplication.shared.keyWindow, windows.values.contains(key) {
                // A new window steps down and to the right of the one in front, so that it does
                // not hide it exactly.
                window.cascadeTopLeft(
                    from: NSPoint(x: key.frame.minX + 26, y: key.frame.maxY - 26)
                )
            } else {
                window.center()
            }
            windows[ObjectIdentifier(session)] = window
            session.canClose = true
            session.closePlatformScene = { [weak window] in window?.performClose(nil) }
            session.activatePlatformScene = { [weak window] in
                guard let window else { return }

                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
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
        /// With `newWindow`, File starts with New Window (`Command.newWindow`); with `settings`,
        /// the app's menu has Settings… (`Command.openSettings`) after About.
        ///
        /// Ownership: returns a new menu. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public convenience init(
            standardAround bar: MenuBar,
            newWindow: Bool = false,
            settings: Bool = false
        ) {
            self.init(title: "")
            let name = ProcessInfo.processInfo.processName

            let app = NSMenu(title: name)
            app.addItem(
                withTitle: "About \(name)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
            app.addItem(.separator())
            if settings {
                app.addItem(NSMenuItem(Command.openSettings))
                app.addItem(.separator())
            }
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
            if newWindow {
                file.addItem(NSMenuItem(Command.newWindow))
            }
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
