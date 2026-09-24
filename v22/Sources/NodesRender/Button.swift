#if canImport(CoreText)
    import LayoutCore
    import Nodes

    /// A tappable label on a filled, rounded box, dimmed while pressed, lifted (bigger, with a
    /// shadow) while focused.
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
            style: TextStyle = TextStyle(size: 15, weight: .semibold, color: .white),
            action: @escaping @MainActor () -> Void
        ) {
            label = Text(title, style: style)
            super.init()
            onTap = action
            appearance.background = Color(red: 0.16, green: 0.42, blue: 0.95)
            appearance.cornerRadius = 8
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
            appearance.scale = isFocused ? 1.1 : 1
            appearance.shadow = isFocused ? Shadow() : nil
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressChanged(_ isPressed: Bool) {
            appearance.opacity = isPressed ? 0.6 : 1
        }
    }
#endif
