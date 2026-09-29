#if canImport(UIKit)
    import AppShell
    import Nodes
    import StateCore
    import UIKit

    extension Tabs {
        /// The tab bar controller showing the tabs — one for the tabs, asking again gives the
        /// same. A scene shows its `Tabs` content in it by itself; this is for an app that puts
        /// them into a hierarchy of its own.
        ///
        /// Ownership: the tabs keep the controller weakly; the caller keeps it. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public func makeViewController() -> UIViewController {
            (self as any PresentedTabs).makeViewController()
        }
    }

    extension PresentedTabs {
        /// The tabs' tab bar controller, whatever their ids.
        func makeViewController() -> UIViewController {
            if let existing = platformContainer as? TabsController {
                return existing
            }
            let controller = TabsController(tabs: self)
            platformContainer = controller
            return controller
        }
    }

    /// Shows `Tabs` in a tab bar controller: each tab is the controller of its content, the
    /// selection goes both ways, and the tabs are told when the controller is on screen.
    final class TabsController: UITabBarController, UITabBarControllerDelegate {
        let model: any PresentedTabs
        private var watch: Observer?

        init(tabs: any PresentedTabs) {
            model = tabs
            super.init(nibName: nil, bundle: nil)
            delegate = self
            viewControllers = model.presentedTabs.map { tab in
                let controller = contentController(for: tab.content)
                controller.tabBarItem = UITabBarItem(
                    title: tab.title,
                    image: tab.symbol.flatMap { UIImage(systemName: $0) },
                    selectedImage: nil
                )
                return controller
            }
            follow()
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// The selection of the tabs shows: a pick from code moves the bar, and one of the
        /// user's, which the tabs took, is the same index.
        private func follow() {
            let watch = Observer { [weak self] in self?.follow() }
            self.watch = watch
            let index = watch.track { model.selectedIndex }
            if selectedIndex != index {
                selectedIndex = index
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            model.setOnScreen(true)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            model.setOnScreen(false)
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            didSelect viewController: UIViewController
        ) {
            if let index = viewControllers?.firstIndex(of: viewController) {
                model.pick(index: index)
            }
        }
    }
#endif
