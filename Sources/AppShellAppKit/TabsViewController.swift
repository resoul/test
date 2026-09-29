// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import Nodes
    import StateCore

    extension Tabs {
        /// The tab view controller showing the tabs — one for the tabs, asking again gives the
        /// same. A scene shows its `Tabs` content in it by itself; this is for an app that
        /// puts them into a hierarchy of its own.
        ///
        /// Ownership: the tabs keep the controller weakly; the caller keeps it. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public func makeViewController() -> NSViewController {
            (self as any PresentedTabs).makeViewController()
        }
    }

    extension PresentedTabs {
        /// The tabs' view controller, whatever their ids.
        func makeViewController() -> NSViewController {
            if let existing = platformContainer as? TabsViewController {
                return existing
            }
            let controller = TabsViewController(tabs: self)
            platformContainer = controller
            return controller
        }
    }

    /// Shows `Tabs` in a tab view controller with the tabs on top of the content, so that the
    /// window's toolbar stays for the commands of the screen shown: each tab is the controller
    /// of its content, the selection goes both ways, and the tabs are told when the controller
    /// is on screen.
    final class TabsViewController: NSTabViewController, WindowLevelContainer {
        let model: any PresentedTabs
        private var watch: Observer?
        /// The controller is choosing a tab itself — when its view loads, where it picks the
        /// first, and when the tabs pick one from code: what it tells the tabs is not the
        /// user's pick.
        private var isApplying = true

        init(tabs: any PresentedTabs) {
            model = tabs
            super.init(nibName: nil, bundle: nil)
            tabStyle = .segmentedControlOnTop
            for tab in tabs.presentedTabs {
                let item = NSTabViewItem(viewController: contentController(for: tab.content))
                item.label = tab.title
                item.image = tab.symbol.flatMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: tab.title)
                }
                addTabViewItem(item)
            }
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// The tabs are picked once the view is there: a selection set before it loads changes
        /// the content but not the control on top, which then shows another tab than the one
        /// shown — as after the state of the last run is put back.
        override func viewDidLoad() {
            super.viewDidLoad()
            follow()
            isApplying = false
        }

        /// The selection of the tabs shows: a pick from code moves the control, and one of the
        /// user's, which the tabs took, is the same index.
        private func follow() {
            let watch = Observer { [weak self] in self?.follow() }
            self.watch = watch
            let index = watch.track { model.selectedIndex }
            if selectedTabViewItemIndex != index {
                let wasApplying = isApplying
                isApplying = true
                selectedTabViewItemIndex = index
                isApplying = wasApplying
            }
        }

        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            if !isApplying, let tabViewItem, let index = tabViewItems.firstIndex(of: tabViewItem) {
                model.pick(index: index)
            }
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
