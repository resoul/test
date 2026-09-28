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
            if let existing = platformContainer as? StackNavigationController {
                return existing
            }
            let controller = StackNavigationController(stack: self)
            platformContainer = controller
            return controller
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
        /// The title each controller shows, watched on its screen.
        private var titles: [StackEntryID: Observer] = [:]
        /// A move of the stack being shown.
        private var applying: StackMove?
        /// The user going back, until the platform's move ends.
        private var goingBack: StackMove?

        init(stack: any PresentedStack) {
            self.stack = stack
            super.init(nibName: nil, bundle: nil)
            delegate = self
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
        /// the platform. The stack's own moves set the controllers and never come here.
        override func popViewController(animated: Bool) -> UIViewController? {
            let count = viewControllers.count - 1
            guard applying == nil, goingBack == nil else {
                return super.popViewController(animated: animated)
            }
            guard let move = stack.backBegan(keeping: count) else { return nil }

            goingBack = move
            let popped = super.popViewController(animated: animated)
            follow(move, done: popped != nil, animated: animated)
            return popped
        }

        /// The back button's menu, jumping back several screens.
        override func popToViewController(
            _ viewController: UIViewController,
            animated: Bool
        ) -> [UIViewController]? {
            guard applying == nil, goingBack == nil,
                let index = viewControllers.firstIndex(of: viewController)
            else { return super.popToViewController(viewController, animated: animated) }
            guard let move = stack.backBegan(keeping: index + 1) else { return nil }

            goingBack = move
            let popped = super.popToViewController(viewController, animated: animated)
            follow(move, done: popped != nil, animated: animated)
            return popped
        }

        override func popToRootViewController(animated: Bool) -> [UIViewController]? {
            guard applying == nil, goingBack == nil, let root = viewControllers.first else {
                return super.popToRootViewController(animated: animated)
            }

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
            let title = Observer { [weak self] in self?.showTitle(of: entry) }
            titles[entry] = title
            showTitle(of: entry)
            return controller
        }

        private func showTitle(of entry: StackEntryID) {
            guard let screen = stack.screen(for: entry), let title = titles[entry] else { return }

            let text = title.track { screen.title }
            if !text.isEmpty {
                controllers[entry]?.navigationItem.title = text
            }
        }

        /// Lets go of the controllers of entries the stack no longer has; a tree of nodes
        /// leaves its host.
        private func letGo() {
            for (entry, controller) in controllers where stack.screen(for: entry) == nil {
                controllers[entry] = nil
                titles[entry]?.cancel()
                titles[entry] = nil
                (controller as? ScreenViewController)?.nodeView.host.detach()
            }
        }
    }

    /// Shows a screen of nodes: its tree in a node view, within the safe area. The tree's
    /// commands go on to the screen.
    final class ScreenViewController: UIViewController {
        let screen: NodeScreen
        let nodeView: NodeView

        init(_ screen: NodeScreen) {
            self.screen = screen
            nodeView = NodeView(root: screen.root)
            super.init(nibName: nil, bundle: nil)
            nodeView.host.outerResponder = screen
            nodeView.host.solvesInBackground = true
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
