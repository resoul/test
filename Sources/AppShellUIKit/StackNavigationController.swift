#if canImport(UIKit)
    import AppShell
    import Nodes
    import NodesUIKit
    import StateCore
    import UIKit

    /// A screen showing a view controller of UIKit, in a stack of screens on nodes:
    ///
    ///     case .settings: ControllerScreen(SettingsViewController(), title: "Settings")
    ///
    /// The stack shows the controller as it is, as a child of its navigation controller; the
    /// controller gets its own appearance calls and presses. A title set on the screen goes
    /// to the controller's navigation item.
    ///
    /// Ownership: keeps `controller`, which must not be shown elsewhere. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    @MainActor
    open class ControllerScreen: Screen {
        /// Ownership: kept by the screen. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public let controller: UIViewController

        /// Ownership: keeps `controller`. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public init(_ controller: UIViewController, title: String = "") {
            self.controller = controller
            super.init(title: title)
        }
    }

    extension Stack {
        /// The navigation controller showing the stack, for a window's root or any place
        /// in a UIKit app. A stack has one: asking again while it lives gives the same one.
        /// The controller keeps the stack; the path changes only through the stack — the
        /// controller's own `viewControllers` must not be set from outside.
        ///
        /// Ownership: returns a controller the caller keeps; it keeps the stack. Isolation:
        /// MainActor. Errors: none. Cancellation: `close()` on the stack.
        public func makeViewController() -> UIViewController {
            (self as any PresentedStack).makeViewController()
        }
    }

    /// Shows a stack in a `UINavigationController`: each move of the stack as a change of
    /// its view controllers, and the user's going back — the back button and its menu, the
    /// swipe from the edge, Command-[, Menu on the remote over a controller of UIKit — as the
    /// stack's going back.
    final class StackNavigationController: UINavigationController, StackPresenter,
        UINavigationControllerDelegate
    {
        let stack: any PresentedStack
        /// The controller of each entry, kept while the stack has the entry.
        private var controllers: [StackEntryID: UIViewController] = [:]
        /// The title and the toolbar each controller shows, watched on its screen.
        private var watches: [StackEntryID: Observer] = [:]
        /// The buttons of each screen's toolbar commands, with the commands they carry out.
        private var buttons: [StackEntryID: [(command: Command, item: UIBarButtonItem)]] = [:]
        /// A move of the stack being shown.
        private var applying: StackMove?
        /// The user going back, until the platform's move ends.
        private var goingBack: StackMove?
        /// Shows what the stack's screens present, over the whole stack.
        let modalPresenter = ModalPresenter()

        init(stack: any PresentedStack) {
            self.stack = stack
            super.init(nibName: nil, bundle: nil)
            delegate = self
            modalPresenter.host = self
            modalPresenter.onHidden = { [weak self] in self?.takeKeyboard() }
            stack.presenter = self
            // A stack shown before — in a scene the system connects again — shows what it
            // showed, without a move.
            if viewControllers.isEmpty {
                matchStack()
            }
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            modalPresenter.hostAppeared()
        }

        /// A presentation gone, the top screen's tree takes the keyboard back: its keys and
        /// the menus' commands reach it again.
        private func takeKeyboard() {
            (topViewController as? ScreenViewController)?.nodeView.becomeFirstResponder()
        }

        // MARK: - StackPresenter

        func present(_ move: StackMove) {
            let shown = move.to.compactMap(controller(for:))
            applying = move
            // The first screens, and a controller out of a window, show without a move.
            let animated = !move.from.isEmpty && view.window != nil
            setViewControllers(shown, animated: animated)
            if animated, let coordinator = transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    self?.ended(move, completed: !context.isCancelled)
                }
            } else {
                ended(move, completed: true)
            }
        }

        private func ended(_ move: StackMove, completed: Bool) {
            if applying == move {
                applying = nil
            }
            if goingBack == move {
                goingBack = nil
            }
            stack.moveEnded(move.id, completed: completed)
            letGo()
            matchStack()
        }

        // MARK: - The user going back

        /// The platform going back by itself — the back button, the swipe from the edge, its
        /// own Command-[, Menu over a controller of UIKit: the stack goes back with it, and
        /// learns at the end whether it did. When the stack cannot go back now, neither does
        /// the platform. The stack's own moves set the controllers and never come here: a
        /// call during one is the platform going back a second time for the same press — on
        /// a TV, Menu reaches both the tree, which goes back through the stack, and the
        /// navigation controller's own recognizer — and does nothing. Nor does a press of Menu
        /// that a node of a screen took for itself, a panel it closes, take the screen off.
        override func popViewController(animated: Bool) -> UIViewController? {
            let count = viewControllers.count - 1
            guard applying == nil, goingBack == nil, !treeHandlesMenu,
                let move = stack.backBegan(keeping: count)
            else { return nil }

            goingBack = move
            let popped = super.popViewController(animated: animated)
            follow(move, done: popped != nil, animated: animated)
            return popped
        }

        /// A screen's tree took the Menu press that is going on.
        private var treeHandlesMenu: Bool {
            viewControllers.contains {
                ($0 as? ScreenViewController)?.nodeView.isHandlingMenu == true
            }
        }

        /// The back button's menu, jumping back several screens.
        override func popToViewController(
            _ viewController: UIViewController,
            animated: Bool
        ) -> [UIViewController]? {
            guard applying == nil, goingBack == nil, !treeHandlesMenu,
                let index = viewControllers.firstIndex(of: viewController),
                let move = stack.backBegan(keeping: index + 1)
            else { return nil }

            goingBack = move
            let popped = super.popToViewController(viewController, animated: animated)
            follow(move, done: popped != nil, animated: animated)
            return popped
        }

        override func popToRootViewController(animated: Bool) -> [UIViewController]? {
            guard let root = viewControllers.first else { return nil }

            return popToViewController(root, animated: animated)
        }

        /// Reports the end of the platform's move back to the stack: at once, or when its
        /// animation — or the user's swipe — ends.
        private func follow(_ move: StackMove, done: Bool, animated: Bool) {
            guard done else {
                ended(move, completed: false)
                return
            }
            if animated, let coordinator = transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    self?.ended(move, completed: !context.isCancelled)
                }
            } else {
                ended(move, completed: true)
            }
        }

        /// After a move of the platform, what shows is what the stack showed last: a move the
        /// stack did not follow is put back.
        /// A screen about to show brings its buttons up to date: whether a command can be
        /// carried out may depend on what nothing watches.
        func navigationController(
            _ navigationController: UINavigationController,
            willShow viewController: UIViewController,
            animated: Bool
        ) {
            if let entry = controllers.first(where: { $0.value === viewController })?.key {
                showTop(of: entry)
            }
        }

        func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController,
            animated: Bool
        ) {
            matchStack()
        }

        private func matchStack() {
            guard applying == nil, goingBack == nil, transitionCoordinator == nil else { return }

            let shown = stack.presentedEntries.compactMap(controller(for:))
            if viewControllers.map(ObjectIdentifier.init) != shown.map(ObjectIdentifier.init) {
                setViewControllers(shown, animated: false)
            }
        }

        // MARK: - Controllers

        private func controller(for entry: StackEntryID) -> UIViewController? {
            if let controller = controllers[entry] {
                return controller
            }
            guard let screen = stack.screen(for: entry) else { return nil }

            let controller: UIViewController
            if let screen = screen as? NodeScreen {
                controller = ScreenViewController(screen)
            } else if let screen = screen as? ControllerScreen {
                controller = screen.controller
            } else {
                return nil
            }
            controllers[entry] = controller
            screen.presentationPresenter = modalPresenter
            watches[entry] = Observer { [weak self] in self?.showTop(of: entry) }
            showTop(of: entry)
            return controller
        }

        /// Shows the screen's title, and its toolbar's commands as buttons at the trailing
        /// end of the navigation bar, enabled as the commands are, as they change. A TV's navigation bar shows no buttons: a screen there shows its commands
        /// among its own nodes.
        private func showTop(of entry: StackEntryID) {
            guard let screen = stack.screen(for: entry), let watch = watches[entry],
                let controller = controllers[entry]
            else { return }

            let target: any CommandTarget =
                (controller as? ScreenViewController)?.nodeView.host ?? screen
            let showsButtons = traitCollection.userInterfaceIdiom != .tv
            let text = watch.track {
                let text = screen.title
                guard showsButtons else { return text }

                let commands = screen.toolbar
                var shown = buttons[entry] ?? []
                if shown.map(\.command) != commands {
                    shown = commands.map { ($0, UIBarButtonItem($0, target: target)) }
                    buttons[entry] = shown
                    controller.navigationItem.rightBarButtonItems =
                        shown.isEmpty ? nil : shown.reversed().map(\.item)
                }
                for (command, item) in shown {
                    item.update(command, for: target)
                }
                return text
            }
            if !text.isEmpty {
                controller.navigationItem.title = text
            }
        }

        /// Lets go of the controllers of entries the stack no longer has; a tree of nodes
        /// leaves its host.
        private func letGo() {
            for (entry, controller) in controllers where stack.screen(for: entry) == nil {
                controllers[entry] = nil
                watches[entry]?.cancel()
                watches[entry] = nil
                buttons[entry] = nil
                (controller as? ScreenViewController)?.nodeView.host.detach()
            }
        }
    }

    /// Shows a screen of nodes: its tree in a node view, within the safe area. The tree's
    /// commands go on to the screen.
    final class ScreenViewController: UIViewController {
        let screen: NodeScreen
        let nodeView: NodeView
        /// Shows what the screen presents while it is not in a stack.
        let modalPresenter = ModalPresenter()

        init(_ screen: NodeScreen) {
            self.screen = screen
            nodeView = NodeView(root: screen.root)
            super.init(nibName: nil, bundle: nil)
            nodeView.host.outerResponder = screen
            nodeView.host.solvesInBackground = true
            nodeView.host.drawingMode = screen.drawingMode
            nodeView.host.displayRange = screen.displayRange
            modalPresenter.host = self
            modalPresenter.onHidden = { [weak nodeView] in _ = nodeView?.becomeFirstResponder() }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            modalPresenter.hostAppeared()
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            let view = UIView()
            // What shows around the tree, outside the safe area and during a move: the
            // system's own background has no tvOS counterpart.
            view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
            nodeView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(nodeView)
            let area = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                nodeView.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                nodeView.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                nodeView.topAnchor.constraint(equalTo: area.topAnchor),
                nodeView.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            ])
            self.view = view
        }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            [nodeView]
        }
    }
#endif
