#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import ThemeCore

    /// A tappable label on a filled, rounded box, dimmed while pressed, lifted (bigger, with a
    /// shadow) while focused on a TV. By default it takes the theme's accent, its color for
    /// text on the accent, its button font and its medium corner radius.
    ///
    ///     let follow = Button("Follow") { profile.isFollowing.value.toggle() }
    ///
    /// Ownership: the creator owns it; it keeps `action`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public final class Button: Node {
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
        public override func focusChanged(_ isFocused: Bool) {
            guard (host?.focusLook ?? .lift) == .lift else { return }

            appearance.scale = isFocused ? 1.15 : 1
            appearance.shadow = isFocused ? Shadow(opacity: 0.45, radius: 14, y: 10) : nil
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressChanged(_ isPressed: Bool) {
            appearance.opacity = isPressed ? 0.6 : 1
        }
    }
#endif
