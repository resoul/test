#if canImport(UIKit)
    import AppShell
    import Nodes
    import NodesUIKit
    import StateCore
    import UIKit

    /// The controller showing a window's content, or a presentation's: a stack's navigation
    /// controller, a screen of nodes, or a screen's own controller of UIKit.
    @MainActor
    func contentController(for content: any SceneContent) -> UIViewController {
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
        return UIViewController()
    }

    extension PresentedStack {
        /// The stack's navigation controller, whatever its routes.
        func makeViewController() -> UIViewController {
            if let existing = platformContainer as? StackNavigationController {
                return existing
            }
            let controller = StackNavigationController(stack: self)
            platformContainer = controller
            return controller
        }
    }

    /// Shows the presentations of the screens of one controller — a stack's navigation
    /// controller, a screen alone, a presentation's container — over it, one at a time, and
    /// follows the user's closing of a sheet by a swipe down.
    @MainActor
    final class ModalPresenter: NSObject, PresentationPresenter,
        UIAdaptivePresentationControllerDelegate
    {
        weak var host: UIViewController?
        /// Asked for while the host was out of a window: shown when it appears.
        private var waiting: [Presentation] = []
        private var containers: [ObjectIdentifier: PresentedViewController] = [:]
        /// Called when a presentation is gone: the host takes the keyboard back.
        var onHidden: (@MainActor () -> Void)?

        func show(_ presentation: Presentation) {
            guard let host, host.viewIfLoaded?.window != nil else {
                waiting.append(presentation)
                return
            }
            // UIKit shows one presentation over a controller.
            guard host.presentedViewController == nil else {
                presentation.showEnded(completed: false)
                return
            }

            let container = PresentedViewController(presentation)
            containers[ObjectIdentifier(presentation)] = container
            container.modalPresentationStyle =
                presentation.style == .fullScreen ? .fullScreen : .automatic
            container.presentationController?.delegate = self
            host.present(container, animated: true) {
                presentation.showEnded(completed: true)
            }
        }

        func hide(_ presentation: Presentation) {
            guard let container = containers[ObjectIdentifier(presentation)],
                let presenting = container.presentingViewController
            else {
                gone(presentation)
                presentation.hideEnded()
                return
            }

            presenting.dismiss(animated: container.viewIfLoaded?.window != nil) {
                [weak self] in
                self?.gone(presentation)
                presentation.hideEnded()
            }
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

        private func gone(_ presentation: Presentation) {
            containers[ObjectIdentifier(presentation)]?.letGo()
            containers[ObjectIdentifier(presentation)] = nil
            onHidden?()
        }

        private func presentation(of controller: UIPresentationController) -> Presentation? {
            (controller.presentedViewController as? PresentedViewController)?.presentation
        }

        // MARK: - UIAdaptivePresentationControllerDelegate

        func presentationControllerShouldDismiss(
            _ presentationController: UIPresentationController
        ) -> Bool {
            presentation(of: presentationController)?.canBeginUserDismiss ?? false
        }

        func presentationControllerDidAttemptToDismiss(
            _ presentationController: UIPresentationController
        ) {
            presentation(of: presentationController)?.userDismissAttempted()
        }

        /// A swipe down went all the way: a swipe let go early never comes here.
        func presentationControllerDidDismiss(
            _ presentationController: UIPresentationController
        ) {
            guard let presentation = presentation(of: presentationController) else { return }

            gone(presentation)
            presentation.userDismissed()
        }
    }

    /// Shows a presentation's content — a screen, or a stack — and what its screen presents
    /// over it. The keyboard goes to it; Menu on the remote, when the content does not take
    /// it, closes it as the presentation says, not by UIKit's own dismissal.
    final class PresentedViewController: UIViewController {
        let presentation: Presentation
        let content: UIViewController
        let modalPresenter = ModalPresenter()
        private var watch: Observer?

        init(_ presentation: Presentation) {
            self.presentation = presentation
            content = contentController(for: presentation.content)
            super.init(nibName: nil, bundle: nil)
            modalPresenter.host = self
            if presentation.content is Screen {
                (presentation.content as? Screen)?.presentationPresenter = modalPresenter
            }
            watchDismissible()
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(content)
            content.view.frame = view.bounds
            content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(content.view)
            content.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            (content as? ScreenViewController)?.nodeView.becomeFirstResponder()
            modalPresenter.hostAppeared()
        }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            [content]
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard presses.contains(where: { $0.type == .menu }) else {
                super.pressesBegan(presses, with: event)
                return
            }

            // The content first: a stack in it goes back while it can.
            presentation.content.perform(.back)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard presses.contains(where: { $0.type == .menu }) else {
                super.pressesEnded(presses, with: event)
                return
            }
        }

        /// A presentation the user cannot close holds a sheet back from a swipe down.
        private func watchDismissible() {
            let watch = Observer { [weak self] in self?.watchDismissible() }
            self.watch = watch
            isModalInPresentation = !watch.track { presentation.isDismissible }
        }

        /// The presentation is gone: a tree of nodes leaves its host.
        func letGo() {
            watch?.cancel()
            (content as? ScreenViewController)?.nodeView.host.detach()
        }
    }
#endif
