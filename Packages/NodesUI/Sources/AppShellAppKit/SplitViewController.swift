// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import Nodes
    import StateCore

    extension Split {
        /// The split view controller showing the split — one for the split, asking again gives
        /// the same. A scene shows its `Split` content in it by itself; this is for an app that
        /// puts it into a hierarchy of its own.
        ///
        /// Ownership: the split keeps the controller weakly; the caller keeps it. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public func makeViewController() -> NSViewController {
            (self as any PresentedSplit).makeViewController()
        }
    }

    extension PresentedSplit {
        /// The split's view controller.
        func makeViewController() -> NSViewController {
            if let existing = platformContainer as? SplitViewController {
                return existing
            }
            let controller = SplitViewController(split: self)
            platformContainer = controller
            return controller
        }
    }

    /// Shows a `Split` in a split view controller with a sidebar: the sidebar's screen in the
    /// sidebar item, the content beside it. A Mac window has room for both, so the split is
    /// never collapsed: `showSidebar()` brings back a sidebar the user hid, and
    /// `showContent()` changes nothing. The window's toolbar is the content's.
    final class SplitViewController: NSSplitViewController, WindowLevelContainer {
        let model: any PresentedSplit
        private let sidebarItem: NSSplitViewItem
        private let contentItem: NSSplitViewItem
        private var watch: Observer?

        init(split: any PresentedSplit) {
            model = split
            sidebarItem = NSSplitViewItem(
                sidebarWithViewController: contentController(for: split.presentedSidebar)
            )
            contentItem = NSSplitViewItem(
                viewController: contentController(for: split.presentedContent)
            )
            super.init(nibName: nil, bundle: nil)
            sidebarItem.minimumThickness = 180
            sidebarItem.maximumThickness = 360
            addSplitViewItem(sidebarItem)
            addSplitViewItem(contentItem)
            split.setCollapsed(false)
            follow()
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// A sidebar the split asks for shows, whether the user hid it or not.
        private func follow() {
            let watch = Observer { [weak self] in self?.follow() }
            self.watch = watch
            let contentShown = watch.track { model.isContentShown }
            if !contentShown, sidebarItem.isCollapsed {
                sidebarItem.animator().isCollapsed = false
            }
        }

        func ownsToolbar(_ child: NSViewController) -> Bool {
            child === contentItem.viewController
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            model.setOnScreen(true)
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            model.setOnScreen(false)
        }
    }
#endif
