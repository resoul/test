#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import StateCore

    /// Shows the toast of a window's session over its content, at the bottom, and takes it
    /// away, and says it to assistive technologies. It takes no mouse outside the toast.
    @MainActor
    final class ToastOverlay: NSView {
        private let session: SceneSession
        private var watch: Observer?
        private(set) var pill: ToastPillView?
        private var shownID: UUID?

        init(session: SceneSession) {
            self.session = session
            super.init(frame: .zero)
            autoresizingMask = [.width, .height]
            let watch = Observer { [weak self] in self?.follow() }
            self.watch = watch
            watch.track { [weak self] in self?.update() }
        }

        required init?(coder: NSCoder) {
            nil
        }

        private func follow() {
            watch?.track { [weak self] in self?.update() }
        }

        /// Only the toast takes the mouse: everywhere else it goes to the view under.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        /// Shows what the session shows: a new toast comes in, the same stays, none goes.
        func update() {
            let shown = session.shownToast
            guard shown?.id != shownID else { return }

            shownID = shown?.id
            if let old = pill {
                pill = nil
                NSAnimationContext.runAnimationGroup(
                    { context in
                        context.duration = 0.2
                        old.animator().alphaValue = 0
                    },
                    completionHandler: { old.removeFromSuperview() }
                )
            }
            guard let shown else { return }

            let pill = ToastPillView(shown.toast, session: session)
            self.pill = pill
            addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: centerXAnchor),
                pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
                pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                pill.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            ])
            pill.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                pill.animator().alphaValue = 1
            }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: shown.toast.message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    /// The toast itself: its words, its action and a button that closes it, on a rounded box
    /// of the window's material. The mouse over it holds it.
    @MainActor
    final class ToastPillView: NSVisualEffectView {
        private weak var session: SceneSession?
        let label: NSTextField
        let actionButton = NSButton()
        let closeButton = NSButton()
        private let hasAction: Bool

        init(_ toast: Toast, session: SceneSession) {
            self.session = session
            hasAction = toast.action != nil
            label = NSTextField(wrappingLabelWithString: toast.message)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            material = .hudWindow
            blendingMode = .withinWindow
            state = .active
            wantsLayer = true
            layer?.cornerRadius = 12
            layer?.masksToBounds = true

            var views: [NSView] = [label]
            if let action = toast.action {
                actionButton.title = action.title
                actionButton.bezelStyle = .inline
                actionButton.isBordered = true
                actionButton.target = self
                actionButton.action = #selector(actionTapped)
                views.append(actionButton)
            }
            closeButton.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: "Dismiss"
            )
            closeButton.isBordered = false
            closeButton.target = self
            closeButton.action = #selector(closed)
            closeButton.setAccessibilityLabel("Dismiss")
            views.append(closeButton)

            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            ])
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self
                )
            )
        }

        required init?(coder: NSCoder) {
            nil
        }

        @objc func actionTapped() {
            session?.performToastAction()
        }

        @objc func closed() {
            session?.dismissToast()
        }

        override func mouseEntered(with event: NSEvent) {
            session?.holdToast()
        }

        override func mouseExited(with event: NSEvent) {
            session?.resumeToast()
        }
    }
#endif
