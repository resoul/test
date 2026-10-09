// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import Nodes
    import NodesAppKit
    import StateCore

    /// A screen showing a view controller of AppKit, in a stack of screens on nodes:
    ///
    ///     case .settings: ControllerScreen(SettingsViewController(), title: "Settings")
    ///
    /// The stack shows the controller as it is, as its child.
    ///
    /// Ownership: keeps `controller`, which must not be shown elsewhere. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    @MainActor
    open class ControllerScreen: Screen {
        /// Ownership: kept by the screen. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public let controller: NSViewController

        /// Ownership: keeps `controller`. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public init(_ controller: NSViewController, title: String = "") {
            self.controller = controller
            super.init(title: title)
        }
    }

    extension Stack {
        /// The view controller showing the stack, for a window's content or any place in an
        /// AppKit app. The Mac has no navigation controller: this one shows the top screen
        /// alone, and slides the next one in. Command-[ and a menu item for `Command.back` go
        /// back. The title of the top screen is the controller's, which a window shows. A stack
        /// has one: asking again while it lives gives the same one; it keeps the stack.
        ///
        /// Ownership: returns a controller the caller keeps; it keeps the stack. Isolation:
        /// MainActor. Errors: none. Cancellation: `close()` on the stack.
        public func makeViewController() -> NSViewController {
            (self as any PresentedStack).makeViewController()
        }
    }

    /// Shows a stack's top screen, and slides between screens as the stack moves.
    final class StackViewController: NSViewController, StackPresenter, NSMenuItemValidation,
        NSToolbarItemValidation
    {
        let stack: any PresentedStack
        /// The controller of each entry, kept while the stack has the entry.
        private var controllers: [StackEntryID: NSViewController] = [:]
        /// The entry whose screen shows.
        private var shown: StackEntryID?
        /// The node that had the keyboard's focus on each screen when it went under the next.
        private var savedFocus: [StackEntryID: NodeID] = [:]
        private var topWatch: Observer?
        /// The window's toolbar, while the stack is a window's content.
        private let toolbar = WindowToolbar(hasBack: true)
        /// Shows what the stack's screens present, as sheets of its window.
        let modalPresenter = ModalPresenter()

        /// Seconds a slide to the next screen takes.
        static let slideTime = 0.25

        init(stack: any PresentedStack) {
            self.stack = stack
            super.init(nibName: nil, bundle: nil)
            modalPresenter.host = self
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            view = StackView(controller: self)
            view.wantsLayer = true
            view.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
            stack.presenter = self
            // A stack shown before shows what it showed, without a move.
            if shown == nil, let top = stack.presentedEntries.last,
                let controller = controller(for: top)
            {
                addChild(controller)
                controller.view.frame = view.bounds
                controller.view.autoresizingMask = [.width, .height]
                view.addSubview(controller.view)
                shown = top
                watchTop()
            }
        }

        /// Shown in a window whose keyboard is nowhere, the stack gives it to the top screen:
        /// its keys and the menus' commands reach it from the start. As the window's content,
        /// or in the tabs or the split that are, it puts up the window's toolbar.
        override func viewDidAppear() {
            super.viewDidAppear()
            guard let window = view.window else { return }

            modalPresenter.hostAppeared()
            if isWindowLevel(in: window) {
                toolbar.attach(to: window)
            }
            guard window.firstResponder === window, let shown, let controller = controllers[shown]
            else { return }

            giveKeyboard(to: controller, entry: shown)
        }

        // MARK: - StackPresenter

        func present(_ move: StackMove) {
            guard let target = move.to.last, target != shown,
                let incoming = controller(for: target)
            else {
                end(move)
                return
            }

            let outgoing = shown.flatMap { controllers[$0] }
            let hadKeyboard = outgoing.map(holdsKeyboard) ?? true
            if let shown, let screen = outgoing as? ScreenViewController {
                savedFocus[shown] = screen.nodeView.host.focusedNode
            }
            // Going back when the screen that shows was in the path before.
            let back =
                shown.map { move.to.contains($0) == false && move.from.contains(target) }
                ?? false
            if incoming.parent == nil {
                addChild(incoming)
            }
            let bounds = view.bounds
            incoming.view.frame = bounds
            incoming.view.autoresizingMask = [.width, .height]
            view.addSubview(incoming.view)
            shown = target
            watchTop()

            let finish = { [weak self] in
                outgoing?.view.removeFromSuperview()
                incoming.view.frame = self?.view.bounds ?? bounds
                guard let self else { return }

                if hadKeyboard {
                    self.giveKeyboard(to: incoming, entry: target)
                }
                self.end(move)
            }
            // A window not on screen shows no slide, and the end of an animation there is
            // not certain to come: the move ends at once.
            guard let outgoing, view.window?.isVisible == true,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            else {
                finish()
                return
            }

            let width = bounds.width
            incoming.view.frame = bounds.offsetBy(dx: back ? -width : width, dy: 0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StackViewController.slideTime
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                incoming.view.animator().frame = bounds
                outgoing.view.animator().frame = bounds.offsetBy(dx: back ? width : -width, dy: 0)
            } completionHandler: {
                finish()
            }
        }

        private func end(_ move: StackMove) {
            stack.moveEnded(move.id, completed: true)
            letGo()
        }

        /// Whether the keyboard is in `controller`'s view, or nowhere in the window.
        private func holdsKeyboard(_ controller: NSViewController) -> Bool {
            guard let window = view.window else { return true }
            guard let responder = window.firstResponder as? NSView else {
                return window.firstResponder === window || window.firstResponder == nil
            }

            return responder.isDescendant(of: controller.view)
        }

        /// The keyboard goes to the screen now showing, and to the node it had there.
        private func giveKeyboard(to controller: NSViewController, entry: StackEntryID) {
            guard let window = view.window else { return }

            if let screen = controller as? ScreenViewController {
                window.makeFirstResponder(screen.nodeView)
                screen.nodeView.host.focus(savedFocus[entry])
            } else {
                window.makeFirstResponder(controller.view)
            }
            savedFocus[entry] = nil
        }

        // MARK: - Commands

        /// A command's menu item chosen over a controller of AppKit: the top screen, and the
        /// stack around it, carry it out. Over nodes, their view takes it first.
        @objc func performCommand(_ sender: Any?) {
            guard let command = Command(carriedBy: sender) else { return }

            topScreen?.perform(command)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            menuItem.validate(with: topScreen)
        }

        func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
            guard item.action == #selector(performCommand(_:)) else { return true }
            guard let command = Command(carriedBy: item) else { return false }

            return topScreen?.canPerform(command) ?? false
        }

        /// Command-[ over a controller of AppKit goes back.
        func goBack(with event: NSEvent) -> Bool {
            guard let window = view.window,
                !(window.firstResponder is NodeNSView),
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "[" || event.keyCode == 33,
                let screen = topScreen, screen.canPerform(.back)
            else { return false }

            screen.perform(.back)
            return true
        }

        private var topScreen: Screen? {
            shown.flatMap(stack.screen(for:))
        }

        // MARK: - Controllers

        private func controller(for entry: StackEntryID) -> NSViewController? {
            if let controller = controllers[entry] {
                return controller
            }
            guard let screen = stack.screen(for: entry) else { return nil }

            let controller: NSViewController
            if let screen = screen as? NodeScreen {
                controller = ScreenViewController(screen)
            } else if let screen = screen as? ControllerScreen {
                controller = screen.controller
            } else {
                return nil
            }
            controllers[entry] = controller
            screen.presentationPresenter = modalPresenter
            return controller
        }

        /// The controller's title is the top screen's, and the toolbar's commands are, as they
        /// change.
        private func watchTop() {
            topWatch?.cancel()
            let watch = Observer { [weak self] in self?.watchTop() }
            topWatch = watch
            guard let screen = topScreen else { return }

            let (text, commands) = watch.track { (screen.title, screen.toolbar) }
            title = text
            toolbar.show(commands)
        }

        /// Lets go of the controllers of entries the stack no longer has; a tree of nodes
        /// leaves its host.
        private func letGo() {
            for (entry, controller) in controllers where stack.screen(for: entry) == nil {
                controllers[entry] = nil
                savedFocus[entry] = nil
                controller.view.removeFromSuperview()
                controller.removeFromParent()
                (controller as? ScreenViewController)?.nodeView.host.detach()
            }
        }
    }

    /// The stack's view: Command-[ over a controller of AppKit goes back.
    private final class StackView: NSView {
        weak var controller: StackViewController?

        init(controller: StackViewController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if controller?.goBack(with: event) == true { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Shows a screen of nodes: its tree in a node view filling the controller's view. The
    /// tree's commands go on to the screen. As a window's content, or in the tabs or the split
    /// that are, it puts up the window's toolbar with the screen's commands.
    final class ScreenViewController: NSViewController {
        let screen: NodeScreen
        let nodeView: NodeNSView
        private var toolbar: WindowToolbar?
        private var toolbarWatch: Observer?
        /// Shows what the screen presents while it is not in a stack.
        let modalPresenter = ModalPresenter()

        init(_ screen: NodeScreen) {
            self.screen = screen
            nodeView = NodeNSView(root: screen.root)
            super.init(nibName: nil, bundle: nil)
            nodeView.host.outerResponder = screen
            nodeView.host.solvesInBackground = true
            nodeView.host.drawingMode = screen.drawingMode
            nodeView.host.displayRange = screen.displayRange
            modalPresenter.host = self
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            view = nodeView
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            modalPresenter.hostAppeared()
            guard let window = view.window, isWindowLevel(in: window) else { return }

            if toolbar == nil {
                toolbar = WindowToolbar(hasBack: false)
                watchToolbar()
            }
            toolbar?.attach(to: window)
        }

        private func watchToolbar() {
            let watch = Observer { [weak self] in self?.watchToolbar() }
            toolbarWatch = watch
            toolbar?.show(watch.track { screen.toolbar })
        }
    }

    /// A container of the layer — tabs, a split — that can be the window's content, whose
    /// contents then have the window's toolbar to put up.
    @MainActor
    protocol WindowLevelContainer: NSViewController {
        /// Whether `child` may put up the window's toolbar: the tab that shows, a split's
        /// content, not its sidebar.
        func ownsToolbar(_ child: NSViewController) -> Bool
    }

    extension WindowLevelContainer {
        func ownsToolbar(_ child: NSViewController) -> Bool { true }
    }

    extension NSViewController {
        /// Whether this controller is the window's content, or in a container of the layer
        /// that is and lets it: the controllers that show the window's toolbar, one at a time.
        func isWindowLevel(in window: NSWindow) -> Bool {
            var controller: NSViewController? = self
            while let current = controller {
                if window.contentViewController === current { return true }

                guard let parent = current.parent as? WindowLevelContainer,
                    parent.ownsToolbar(current)
                else { return false }

                controller = parent
            }
            return false
        }
    }
#endif
