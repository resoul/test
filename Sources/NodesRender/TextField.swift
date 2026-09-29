#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore

    /// What the keyboard's Return key says, and what it does in a `TextField`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ReturnKey: Hashable, Sendable {
        /// Return: `onSubmit`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case `default`
        /// Next: the next field of the tree takes the keyboard; `onSubmit` too.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case next
        /// Done: the keyboard goes away; `onSubmit` too.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case done
        /// Send: `onSubmit`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case send
        /// Search: `onSubmit`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case search
    }

    /// What a field is for: the keyboard it gets, and what the system offers to fill it
    /// with — a saved email, a name, a password.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum TextContent: Hashable, Sendable {
        /// Any text.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case text
        /// A person's name.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case name
        /// An email address: the email keyboard, no autocorrection, no capitals.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case email
    }

    /// A field of one line of text, which the platform's own text field shows and edits:
    /// every language's input, dictation, the selection and its menu, undo, and what the
    /// system fills in all work as in any app.
    ///
    ///     let email = TextField(placeholder: "Email", content: .email)
    ///     email.returnKey = .next
    ///     email.onChange = { model.email = $0 }
    ///
    /// Return with `.next` moves the keyboard to the next field of the tree. While a field is
    /// edited, the scrolls around it keep it above the keyboard.
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    @MainActor
    public final class TextField: EmbeddedNode {
        private let textState: State<String>
        private let editingState = State(false)

        /// The text in the field. Reading it under tracking depends on it; setting it shows
        /// the new text without calling `onChange`.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var text: String {
            get { textState.value }
            set { textState.value = newValue }
        }

        /// What the empty field shows.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var placeholder: String

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public let content: TextContent

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var returnKey = ReturnKey.default

        /// Called when the user changes the text.
        ///
        /// Ownership: the field keeps the closure; it must not keep the field. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var onChange: (@MainActor (String) -> Void)?

        /// Called when the user presses Return.
        ///
        /// Ownership: the field keeps the closure; it must not keep the field. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var onSubmit: (@MainActor () -> Void)?

        /// Whether the field has the keyboard. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isEditing: Bool { editingState.value }

        /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(_ text: String = "", placeholder: String = "", content: TextContent = .text) {
            textState = State(text)
            self.placeholder = placeholder
            self.content = content
            super.init()
        }

        /// Gives the field the keyboard; it takes it once it shows.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: `endEditing()`.
        public func beginEditing() {
            onEditingRequest?(true)
        }

        /// Takes the keyboard away from the field.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func endEditing() {
            onEditingRequest?(false)
        }

        // MARK: - For platform adapters

        /// Set by the adapter: gives the field's view the keyboard, or takes it away.
        package var onEditingRequest: (@MainActor (Bool) -> Void)?

        /// The user changed the text in the field's view.
        package func userChanged(_ text: String) {
            guard text != textState.value else { return }

            textState.value = text
            onChange?(text)
        }

        /// The field's view took the keyboard, or gave it up.
        package func editingChanged(_ isEditing: Bool) {
            editingState.value = isEditing
            if isEditing {
                host?.reveal(self)
            }
        }

        /// The user pressed Return: what the return key says is done.
        package func userSubmitted() {
            onSubmit?()
            switch returnKey {
            case .next:
                if let next = nextField() {
                    next.beginEditing()
                } else {
                    endEditing()
                }
            case .done:
                endEditing()
            case .default, .send, .search:
                break
            }
        }

        /// The next field of the tree after this one, in the tree's order.
        private func nextField() -> TextField? {
            guard let fields = host?.embeddedItems().compactMap({ $0.node as? TextField }),
                let index = fields.firstIndex(where: { $0 === self }),
                index + 1 < fields.count
            else { return nil }

            return fields[index + 1]
        }
    }
#endif
