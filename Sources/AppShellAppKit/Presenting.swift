// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import Nodes
    import NodesAppKit
    import StateCore

    /// The controller showing a window's content, or a presentation's: a stack's controller,
    /// a screen of nodes, or a screen's own controller of AppKit.
    @MainActor
    func contentController(for content: CommandResponder) -> NSViewController {
        if let stack = content as? any PresentedStack {
            return stack.makeViewController()
        }
        if let screen = content as? ControllerScreen {
            return screen.controller
        }
        if let screen = content as? NodeScreen {
            let controller = ScreenViewController(screen)
            // Alone, not in a stack: it shows what the screen presents itself.
            screen.presentationPresenter = controller.modalPresenter
            return controller
        }
        return NSViewController()
    }

    extension PresentedStack {
        /// The stack's view controller, whatever its routes.
        func makeViewController() -> NSViewController {
            if let existing = platformContainer as? StackViewController {
                return existing
            }
            let controller = StackViewController(stack: self)
            platformContainer = controller
            return controller
        }
    }

    /// Shows the presentations of the screens of one controller as sheets of its window, one
    /// at a time. A Mac has no presentation over the whole window: that style is a sheet too.
    @MainActor
    final class ModalPresenter: PresentationPresenter {
        weak var host: NSViewController?
        /// Asked for while the host was out of a window: shown when it appears.
        private var waiting: [Presentation] = []
        private var containers: [ObjectIdentifier: PresentedViewController] = [:]
        /// The alerts showing, as sheets of the host's window.
        private var alerts: [ObjectIdentifier: NSAlert] = [:]

        func show(_ presentation: Presentation) {
            guard let host, host.viewIfLoaded?.window != nil else {
                waiting.append(presentation)
                return
            }
            // A window shows one sheet of ours at a time.
            guard host.presentedViewControllers?.isEmpty ?? true else {
                presentation.showEnded(completed: false)
                return
            }

            if let alert = presentation.content as? Alert, let window = host.view.window {
                show(alert, of: presentation, in: window)
                return
            }
            let container = PresentedViewController(presentation)
            containers[ObjectIdentifier(presentation)] = container
            host.presentAsSheet(container)
            presentation.showEnded(completed: true)
        }

        func hide(_ presentation: Presentation) {
            if let alert = alerts.removeValue(forKey: ObjectIdentifier(presentation)) {
                alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
            }
            if let container = containers[ObjectIdentifier(presentation)] {
                containers[ObjectIdentifier(presentation)] = nil
                if container.presentingViewController != nil {
                    container.dismiss(nil)
                }
                container.letGo()
            }
            presentation.hideEnded()
        }

        /// Shows `alert` as a sheet of `window`: its first button takes Return, its cancel
        /// button Escape.
        private func show(_ alert: Alert, of presentation: Presentation, in window: NSWindow) {
            let shown = NSAlert()
            shown.messageText = alert.title
            shown.informativeText = alert.message ?? ""
            for action in alert.actions {
                let button = shown.addButton(withTitle: action.title)
                switch action.role {
                case .normal: break
                case .cancel: button.keyEquivalent = "\u{1B}"
                case .destructive: button.hasDestructiveAction = true
                }
            }
            alerts[ObjectIdentifier(presentation)] = shown
            shown.beginSheetModal(for: window) { [weak self, weak alert] response in
                let index =
                    response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                // Taken away by `hide`: nothing was chosen.
                guard let self, let alert,
                    alerts.removeValue(forKey: ObjectIdentifier(presentation)) != nil
                else { return }

                alert.choose(index)
            }
            presentation.showEnded(completed: true)
        }

        /// The host is in a window: what waited for it shows.
        func hostAppeared() {
            let shown = waiting
            waiting = []
            for presentation in shown {
                if presentation.isWanted {
                    show(presentation)
                } else {
                    presentation.showEnded(completed: false)
                }
            }
        }
    }

    /// Shows a presentation's content — a screen, or a stack — in a sheet, and what its
    /// screen presents over it. The keyboard goes to it; Escape over a view of AppKit closes
    /// it as the presentation says.
    final class PresentedViewController: NSViewController {
        let presentation: Presentation
        let content: NSViewController
        let modalPresenter = ModalPresenter()

        /// The size of a sheet whose content asks for none.
        static let standardSize = NSSize(width: 480, height: 400)

        init(_ presentation: Presentation) {
            self.presentation = presentation
            content = contentController(for: presentation.content)
            super.init(nibName: nil, bundle: nil)
            modalPresenter.host = self
            (presentation.content as? Screen)?.presentationPresenter = modalPresenter
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            let size =
                content.preferredContentSize == .zero
                ? Self.standardSize : content.preferredContentSize
            view = NSView(frame: NSRect(origin: .zero, size: size))
            addChild(content)
            content.view.frame = view.bounds
            content.view.autoresizingMask = [.width, .height]
            view.addSubview(content.view)
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            if let screen = content as? ScreenViewController {
                view.window?.makeFirstResponder(screen.nodeView)
            }
            modalPresenter.hostAppeared()
        }

        /// Escape over a view of AppKit that does not cancel anything itself.
        override func cancelOperation(_ sender: Any?) {
            presentation.content.perform(.cancel)
        }

        /// The presentation is gone: a tree of nodes leaves its host.
        func letGo() {
            (content as? ScreenViewController)?.nodeView.host.detach()
        }
    }
#endif
