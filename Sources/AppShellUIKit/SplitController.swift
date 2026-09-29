#if canImport(UIKit)
    import AppShell
    import Foundation
    import Nodes
    import StateCore
    import UIKit

    extension Split {
        /// The split view controller showing the split — one for the split, asking again gives
        /// the same. A scene shows its `Split` content in it by itself; this is for an app that
        /// puts it into a hierarchy of its own.
        ///
        /// Ownership: the split keeps the controller weakly; the caller keeps it. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public func makeViewController() -> UIViewController {
            (self as any PresentedSplit).makeViewController()
        }
    }

    extension PresentedSplit {
        /// The split's view controller.
        func makeViewController() -> UIViewController {
            if let existing = platformContainer as? SplitController {
                return existing
            }
            let controller = SplitController(split: self)
            platformContainer = controller
            return controller
        }
    }

    /// Shows a `Split` in a split view controller of two columns: the sidebar's screen in the
    /// primary column, the content in the secondary. Where room is short for both, it shows
    /// the one the split says, and the user's going between them goes to the split.
    final class SplitController: UISplitViewController, UISplitViewControllerDelegate {
        let model: any PresentedSplit
        private var watch: Observer?
        private var titleWatch: Observer?
        private let sidebarController: UINavigationController

        init(split: any PresentedSplit) {
            model = split
            let sidebar = contentController(for: split.presentedSidebar)
            sidebarController = UINavigationController(rootViewController: sidebar)
            super.init(style: .doubleColumn)
            delegate = self
            preferredDisplayMode = .oneBesideSecondary
            setViewController(sidebarController, for: .primary)
            setViewController(contentController(for: split.presentedContent), for: .secondary)
            follow()
            watchTitle()
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// The sidebar's title is the screen's.
        private func watchTitle() {
            let watch = Observer { [weak self] in self?.watchTitle() }
            titleWatch = watch
            let screen = model.presentedSidebar
            let title = watch.track { screen.title }
            sidebarController.viewControllers.first?.navigationItem.title = title
        }

        /// Where room is short, the column the split says shows.
        private func follow() {
            let watch = Observer { [weak self] in self?.follow() }
            self.watch = watch
            let contentShown = watch.track { model.isContentShown }
            guard isCollapsed else { return }

            show(contentShown ? .secondary : .primary)
        }

        /// Whether room is short for both columns, as far as the controller knows: it collapses
        /// for a compact width, but a window not yet in a scene has no size class, and the
        /// controller collapses only after it appeared.
        private var isNarrow: Bool {
            isCollapsed || traitCollection.horizontalSizeClass == .compact
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            model.setCollapsed(isNarrow)
        }

        /// The screens appear once the controller has decided how many columns show: it may
        /// collapse after it appeared, and a content that appeared for that moment would
        /// disappear at once. The split learns how much room there is first, and only then that
        /// it is on screen.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            DispatchQueue.main.async { [weak self] in
                guard let self, viewIfLoaded?.window != nil else { return }

                model.setCollapsed(isNarrow)
                model.setOnScreen(true)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            model.setCollapsed(isNarrow)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            model.setOnScreen(false)
        }

        // MARK: - UISplitViewControllerDelegate

        func splitViewController(
            _ svc: UISplitViewController,
            topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController
                .Column
        ) -> UISplitViewController.Column {
            model.isContentShown ? .secondary : .primary
        }

        func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
            model.setCollapsed(true)
        }

        func splitViewControllerDidExpand(_ svc: UISplitViewController) {
            model.setCollapsed(false)
        }

        /// The user going between the sidebar and the content where only one shows.
        func splitViewController(
            _ svc: UISplitViewController,
            willShow column: UISplitViewController.Column
        ) {
            guard isCollapsed else { return }

            model.setContentShown(column == .secondary)
        }
    }
#endif
