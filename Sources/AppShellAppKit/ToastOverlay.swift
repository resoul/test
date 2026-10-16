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

        /// The toast is what this view has to say to assistive technologies; the view itself
        /// is not an element.
        override func isAccessibilityElement() -> Bool {
            false
        }

        override func accessibilityChildren() -> [Any]? {
            pill.map { [$0] } ?? []
        }

        /// Only the toast takes the mouse: everywhere else it goes to the view under.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        /// Shows what the session shows: a new toast comes in, the same stays, none goes. A
        /// toast another one joined keeps its place and changes its words, said again.
        func update() {
            let shown = session.shownToast
            if let shown, shown.id == shownID, let pill {
                let said = pill.label.stringValue
                if pill.refresh(shown) {
                    if pill.label.stringValue != said { announce(shown) }
                    return
                }
                // It gained or lost its action: it is built again, without leaving and coming in.
                pill.removeFromSuperview()
                self.pill = nil
                add(shown, animated: false)
                return
            }
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

            add(shown, animated: true)
        }

        private func add(_ shown: ShownToast, animated: Bool) {
            let pill = ToastPillView(shown, session: session)
            self.pill = pill
            addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: centerXAnchor),
                pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
                pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                pill.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            ])
            if animated {
                pill.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    pill.animator().alphaValue = 1
                }
            }
            announce(shown)
        }

        private func announce(_ shown: ShownToast) {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: shown.message,
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

        init(_ shown: ShownToast, session: SceneSession) {
            let toast = shown.toast
            self.session = session
            hasAction = toast.action != nil
            label = NSTextField(wrappingLabelWithString: shown.message)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            material = .hudWindow
            blendingMode = .withinWindow
            state = .active
            wantsLayer = true
            layer?.cornerRadius = 12
            layer?.masksToBounds = true

            // A text field says its words as its value; the label is what a query finds it by.
            label.setAccessibilityLabel(shown.message)
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

        /// The toast is a group: its words, its action, the button that closes it.
        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            .group
        }

        override func accessibilityChildren() -> [Any]? {
            [label] + (hasAction ? [actionButton] : []) + [closeButton]
        }

        /// Shows `shown`, a toast that others joined, in place: its words and its action's title.
        /// Returns `false` when it gained or lost its action and has to be built again.
        func refresh(_ shown: ShownToast) -> Bool {
            guard (shown.toast.action != nil) == hasAction else { return false }

            label.stringValue = shown.message
            label.setAccessibilityLabel(shown.message)
            if let action = shown.toast.action {
                actionButton.title = action.title
            }
            return true
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
