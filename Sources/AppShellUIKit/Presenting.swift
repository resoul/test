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
                presentation.style.coversWindow ? .fullScreen : .automatic
            container.presentationController?.delegate = self
            (container as? any SheetHeights)?.setUpHeights()
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

        /// A presentation the user cannot close holds a sheet back from a swipe down; a
        /// sheet moves to the height the presentation asks for.
        private func watchDismissible() {
            let watch = Observer { [weak self] in self?.watchDismissible() }
            self.watch = watch
            let (dismissible, height) = watch.track {
                (presentation.isDismissible, presentation.height)
            }
            isModalInPresentation = !dismissible
            (self as? any SheetHeights)?.show(height)
        }

        /// The presentation is gone: a tree of nodes leaves its host.
        func letGo() {
            watch?.cancel()
            (content as? ScreenViewController)?.nodeView.host.detach()
        }
    }

    /// The heights a sheet stops at. A TV has no sheets that stop part of the way: there
    /// the conformance is unavailable, and a cast to it finds none.
    @MainActor
    protocol SheetHeights {
        /// Gives the sheet the presentation's heights, before it shows.
        func setUpHeights()
        /// Moves the sheet to `height`, unless it is there.
        func show(_ height: SheetHeight)
    }

    @available(tvOS, unavailable)
    extension PresentedViewController: SheetHeights {
        func setUpHeights() {
            guard let sheet = sheetPresentationController, !presentation.style.coversWindow
            else { return }

            let heights = presentation.style.heights
            sheet.detents = heights.map(\.detent)
            sheet.prefersGrabberVisible = heights.count > 1
            sheet.selectedDetentIdentifier = presentation.height.identifier
            sheet.largestUndimmedDetentIdentifier = presentation.style.usableBelow?.identifier
        }

        func show(_ height: SheetHeight) {
            // Before the presentation begins, asking for the sheet would make its controller
            // with the style not yet set; `setUpHeights()` gives the first height then.
            guard !presentation.style.coversWindow, presentingViewController != nil,
                let sheet = sheetPresentationController,
                sheet.selectedDetentIdentifier != height.identifier
            else { return }

            sheet.animateChanges {
                sheet.selectedDetentIdentifier = height.identifier
            }
        }
    }

    @available(tvOS, unavailable)
    extension ModalPresenter: UISheetPresentationControllerDelegate {
        /// The user dragged a sheet to another height.
        func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
            _ sheetPresentationController: UISheetPresentationController
        ) {
            guard
                let container = sheetPresentationController.presentedViewController
                    as? PresentedViewController,
                let height = container.presentation.style.heights.first(where: {
                    $0.identifier == sheetPresentationController.selectedDetentIdentifier
                })
            else { return }

            container.presentation.userMoved(to: height)
        }
    }

    @available(tvOS, unavailable)
    extension SheetHeight {
        var identifier: UISheetPresentationController.Detent.Identifier {
            switch self {
            case .medium: .medium
            case .large: .large
            case .points(let points): .init("points.\(points)")
            case .fraction(let fraction): .init("fraction.\(fraction)")
            }
        }

        var detent: UISheetPresentationController.Detent {
            switch self {
            case .medium: .medium()
            case .large: .large()
            case .points(let points):
                .custom(identifier: identifier) { context in
                    min(points, context.maximumDetentValue)
                }
            case .fraction(let fraction):
                .custom(identifier: identifier) { context in
                    context.maximumDetentValue * min(max(fraction, 0), 1)
                }
            }
        }
    }
#endif
