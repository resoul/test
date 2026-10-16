#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import ThemeCore

    /// A tappable label on a filled, rounded box, dimmed while pressed, lighter under the
    /// pointer, faded while turned off, lifted (bigger, with a shadow) while focused on a TV.
    /// By default it takes the theme's accent, its color for text on the accent, its button
    /// font and its medium corner radius.
    ///
    ///     let follow = Button("Follow") { profile.isFollowing.value.toggle() }
    ///     let compose = Button(command: .compose)
    ///
    /// Ownership: the creator owns it; it keeps `action`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public final class Button: Control {
        /// Ownership: owned by the button. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public let label: Text

        /// A button showing `title`, running `action` when tapped.
        ///
        /// Ownership: keeps `action`, which must not keep the button. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public init(
            _ title: String,
            style: TextStyle = TextStyle(.button),
            action: @escaping @MainActor () -> Void
        ) {
            label = Text(title, style: style)
            titleColor = style.color
            super.init()
            onTap = action
        }

        /// A button showing the title of `command`, carrying it out when tapped, and turned
        /// off while nothing can.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public init(command: Command, style: TextStyle = TextStyle(.button)) {
            label = Text(command.title, style: style)
            titleColor = style.color
            super.init()
            self.command = command
        }

        /// The fill of the box; `nil` for the theme's accent.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var fill: Color? {
            didSet { if fill != oldValue { update() } }
        }

        /// The color of the title as the style gave it; `nil` takes the theme's color for text
        /// on the accent.
        private let titleColor: Color?

        /// Follows the theme: the accent, the color on it, the medium corner radius.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func update() {
            let theme = self.theme
            appearance.background = fill ?? theme.color(.accent)
            appearance.cornerRadius = theme.radius(.medium)
            if titleColor == nil {
                label.style.color = theme.color(.onAccent)
            }
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var title: String {
            get { label.text }
            set { label.text = newValue }
        }

        /// Ownership: returns a value borrowing the label. Isolation: MainActor. Errors:
        /// none. Cancellation: none.
        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer { label }
                .padding(10)
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func stateChanged(from previous: ControlState) {
            appearance.opacity =
                if state.contains(.disabled) {
                    0.4
                } else if state.contains(.pressed) {
                    0.6
                } else if state.contains(.hovered) {
                    0.85
                } else {
                    1
                }
            guard (host?.focusLook ?? .lift) == .lift,
                state.contains(.focused) != previous.contains(.focused)
            else { return }

            let isFocused = state.contains(.focused)
            appearance.scale = isFocused ? 1.15 : 1
            appearance.shadow = isFocused ? Shadow(opacity: 0.45, radius: 14, y: 10) : nil
        }
    }
#endif
