#if canImport(UIKit)
    import AppShell
    import StateCore
    import UIKit

    /// The window that shows a scene's toasts: a window of the scene above its own and above
    /// what it presents, that takes no touch outside the toast and is never the key window.
    @MainActor
    final class ToastWindow: UIWindow {
        let controller: ToastController

        init(scene: UIWindowScene, session: SceneSession) {
            controller = ToastController(session: session)
            super.init(windowScene: scene)
            windowLevel = .alert + 1
            rootViewController = controller
            isHidden = false
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var canBecomeKey: Bool { false }

        /// Only the toast takes touches: everywhere else they go to the window under.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self || hit === rootViewController?.view ? nil : hit
        }
    }

    /// Shows the toast of a scene's session, and takes it away, and says it to VoiceOver.
    @MainActor
    final class ToastController: UIViewController {
        private let session: SceneSession
        private var watch: Observer?
        private(set) var pill: ToastPillView?
        private var shownID: UUID?
        private var announcementTask: Task<Void, Never>?

        init(session: SceneSession) {
            self.session = session
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            let watch = Observer { [weak self] in self?.follow() }
            self.watch = watch
            watch.track { [weak self] in self?.update() }
            // VoiceOver has read the toast out: it may go.
            announcementTask = Task { [weak self] in
                let finished = NotificationCenter.default.notifications(
                    named: UIAccessibility.announcementDidFinishNotification
                )
                for await _ in finished {
                    self?.session.resumeToast()
                }
            }
        }

        deinit {
            announcementTask?.cancel()
        }

        private func follow() {
            watch?.track { [weak self] in self?.update() }
        }

        /// Shows what the session shows: a new toast comes in, the same stays, none goes.
        func update() {
            let shown = session.shownToast
            guard shown?.id != shownID else { return }

            shownID = shown?.id
            let old = pill
            pill = nil
            if let old {
                UIView.animate(
                    withDuration: 0.2,
                    animations: { old.alpha = 0 },
                    completion: { _ in old.removeFromSuperview() }
                )
            }
            guard let shown else { return }

            let pill = ToastPillView(shown.toast, session: session)
            self.pill = pill
            view.addSubview(pill)
            pill.place(in: view)
            view.layoutIfNeeded()
            pill.alpha = 0
            pill.transform = CGAffineTransform(translationX: 0, y: 16)
            UIView.animate(withDuration: 0.25) {
                pill.alpha = 1
                pill.transform = .identity
            }
            UIAccessibility.post(notification: .announcement, argument: shown.toast.message)
            // While VoiceOver reads it, it stays.
            if UIAccessibility.isVoiceOverRunning {
                session.holdToast()
            }
        }
    }

    /// The toast itself: its words and its action on a blurred rounded box.
    @MainActor
    final class ToastPillView: UIView {
        private weak var session: SceneSession?
        let label = UILabel()
        let actionButton = UIButton(type: .system)
        private let hasAction: Bool

        init(_ toast: Toast, session: SceneSession) {
            self.session = session
            // A TV has no button to take an action with.
            hasAction = toast.action != nil && UIDevice.current.userInterfaceIdiom != .tv
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            layer.cornerRadius = 14
            layer.masksToBounds = true

            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
            blur.translatesAutoresizingMaskIntoConstraints = false
            addSubview(blur)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: trailingAnchor),
                blur.topAnchor.constraint(equalTo: topAnchor),
                blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            label.text = toast.message
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            let stack = UIStackView(arrangedSubviews: [label])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 16
            if hasAction, let action = toast.action {
                actionButton.setTitle(action.title, for: .normal)
                actionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
                actionButton.addAction(
                    UIAction { [weak self] _ in self?.actionTapped() },
                    for: .primaryActionTriggered
                )
                actionButton.setContentHuggingPriority(.required, for: .horizontal)
                actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
                stack.addArrangedSubview(actionButton)
            }
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            ])

            // What VoiceOver says of it, and a way to close it, the persistent one included.
            label.isAccessibilityElement = true
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Dismiss") { [weak session] _ in
                    session?.dismissToast()
                    return true
                }
            ]
            if UIDevice.current.userInterfaceIdiom != .tv {
                // A finger on it holds it; a swipe down takes it away.
                let press = UILongPressGestureRecognizer(
                    target: self,
                    action: #selector(pressed(_:))
                )
                press.minimumPressDuration = 0
                press.cancelsTouchesInView = false
                press.delegate = self
                addGestureRecognizer(press)
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
                swipe.direction = .down
                addGestureRecognizer(swipe)
            }
        }

        required init?(coder: NSCoder) {
            nil
        }

        func actionTapped() {
            session?.performToastAction()
        }

        @objc private func pressed(_ press: UILongPressGestureRecognizer) {
            switch press.state {
            case .began: session?.holdToast()
            case .ended, .cancelled, .failed: session?.resumeToast()
            default: break
            }
        }

        @objc private func swiped() {
            session?.dismissToast()
        }

        /// Puts the toast where it goes in `container`: at the bottom, above the keyboard and
        /// the tab bar; at the top right on a TV.
        func place(in container: UIView) {
            var constraints = [
                leadingAnchor.constraint(
                    greaterThanOrEqualTo: container.safeAreaLayoutGuide.leadingAnchor,
                    constant: 16
                ),
                trailingAnchor.constraint(
                    lessThanOrEqualTo: container.safeAreaLayoutGuide.trailingAnchor,
                    constant: -16
                ),
                widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            ]
            if UIDevice.current.userInterfaceIdiom == .tv {
                constraints += [
                    topAnchor.constraint(
                        equalTo: container.safeAreaLayoutGuide.topAnchor,
                        constant: 40
                    ),
                    trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -80),
                ]
            } else {
                constraints += [
                    centerXAnchor.constraint(equalTo: container.centerXAnchor)
                ]
                let bottom = bottomAnchor.constraint(
                    equalTo: container.safeAreaLayoutGuide.bottomAnchor,
                    constant: -(12 + tabBarHeight(in: container))
                )
                bottom.priority = .defaultHigh
                constraints.append(bottom)
                (container as? any KeyboardAvoiding)?.keepAboveKeyboard(
                    self,
                    constraints: &constraints
                )
            }
            NSLayoutConstraint.activate(constraints)
        }

        /// The height of the tab bar under the toast, when there is one showing.
        private func tabBarHeight(in container: UIView) -> CGFloat {
            var controller = container.window?.windowScene?.windows
                .first { $0.windowLevel == .normal }?.rootViewController
            while let current = controller {
                if let tabs = current as? UITabBarController {
                    return tabs.tabBar.isHidden ? 0 : tabs.tabBar.frame.height
                }
                controller = current.presentedViewController ?? current.children.first
            }
            return 0
        }
    }

    extension ToastPillView: UIGestureRecognizerDelegate {
        /// The finger on the toast is heard along with the button's touch.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// A view that keeps a toast above the keyboard. A TV has no keyboard over the screen, and
    /// the guide it would follow is unavailable there: the conformance is unavailable too, and a
    /// cast still finds it at run time, so the toast checks the device itself first.
    @MainActor
    protocol KeyboardAvoiding {
        func keepAboveKeyboard(_ pill: UIView, constraints: inout [NSLayoutConstraint])
    }

    @available(tvOS, unavailable)
    extension UIView: KeyboardAvoiding {
        func keepAboveKeyboard(_ pill: UIView, constraints: inout [NSLayoutConstraint]) {
            guard UIDevice.current.userInterfaceIdiom != .tv else { return }

            constraints.append(
                pill.bottomAnchor.constraint(
                    lessThanOrEqualTo: keyboardLayoutGuide.topAnchor,
                    constant: -12
                )
            )
        }
    }
#endif
