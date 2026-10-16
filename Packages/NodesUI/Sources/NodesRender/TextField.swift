#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore

    /// What checking a field's text found.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum FieldValidation: Hashable, Sendable {
        /// Nothing was checked yet, or there is nothing to check — the field is empty, or its
        /// text was set by code.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case unchecked
        /// The text passed.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case valid
        /// The text did not pass, and the message says why, for the user.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case invalid(String)
    }

    /// When a field checks its text on its own.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ValidationTiming: Hashable, Sendable {
        /// After every change the user makes.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case onInput
        /// When the user leaves the field, and when Return is pressed in it.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case onEndEditing
        /// Only when Return is pressed in it (`TextField.validate()` at any other time).
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case onSubmit
    }

    /// When a field shows a button that clears it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum ClearButton: Hashable, Sendable {
        /// Never.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case never
        /// While the field is edited and has text.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case whileEditing
        /// Whenever the field has text.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case always
    }

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
        /// The password of an account that exists: the system offers the saved one. No
        /// autocorrection, no capitals.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case password
        /// The password of an account being made or changed: the system offers a strong one.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case newPassword
        /// A telephone number: the number pad.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case phone
        /// A code sent to the user — by SMS, by email — which the system offers to fill in from
        /// the message: the number pad.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case oneTimeCode
        /// A web address: the URL keyboard, no autocorrection, no capitals.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case url
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
    open class TextField: EmbeddedNode {
        private let textState: State<String>
        private let editingState = State(false)
        private let validationState = State(FieldValidation.unchecked)

        /// The text in the field. Reading it under tracking depends on it; setting it shows
        /// the new text without calling `onChange`.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var text: String {
            get { textState.value }
            set {
                textState.value = newValue
                // What was checked was another text.
                setValidation(.unchecked)
            }
        }

        /// What the empty field shows.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var placeholder: String

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public let content: TextContent

        /// How many characters the field takes at most: what the user types or pastes beyond it
        /// is cut off, in the field as in `text`. `nil` is no limit. Text set by code is not cut.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var maxLength: Int?

        /// When the field shows a button that clears it: UIKit's own; the Mac's text field has
        /// none, and shows nothing.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var clearButton = ClearButton.never

        /// Whether the field shows what is typed: a secure field shows dots.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        open var isSecure: Bool { false }

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

        /// How the text is checked: `nil` checks nothing. A field made for a kind of text has
        /// one (`EmailField`); the app gives one to any other, or another to that one.
        ///
        ///     name.validator = { $0.isEmpty ? .invalid("Enter your name") : .valid }
        ///
        /// Ownership: the field keeps the closure; it must not keep the field. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var validator: (@MainActor (String) -> FieldValidation)?

        /// When the field checks by itself: on leaving it by default. Once a check was made,
        /// every change the user makes checks again, so that a message goes as soon as the text
        /// is right. `validate()` checks at any time.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var validationTiming = ValidationTiming.onEndEditing

        /// What the last check found. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var validation: FieldValidation { validationState.value }

        /// Why the text did not pass, for the user; `nil` unless the last check said so.
        /// Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var validationMessage: String? {
            if case .invalid(let message) = validation { return message }
            return nil
        }

        /// Called when what a check found is not what the last one did.
        ///
        /// Ownership: the field keeps the closure; it must not keep the field. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var onValidationChange: (@MainActor (FieldValidation) -> Void)?

        /// Checks the text now — a form does it for every field when it is sent — and returns
        /// what was found: `.unchecked` for a field with nothing to check it by.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        @discardableResult
        public func validate() -> FieldValidation {
            let result = validator?(textState.value) ?? .unchecked
            setValidation(result)
            return result
        }

        private func setValidation(_ result: FieldValidation) {
            guard result != validationState.value else { return }

            validationState.value = result
            onValidationChange?(result)
        }

        /// Whether the field has the keyboard. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isEditing: Bool { editingState.value }

        /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            _ text: String = "",
            placeholder: String = "",
            content: TextContent = .text
        ) {
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
        package func userChanged(_ typed: String) {
            let text = maxLength.map { String(typed.prefix(max($0, 0))) } ?? typed
            guard text != textState.value else { return }

            textState.value = text
            onChange?(text)
            if validationTiming == .onInput || validation != .unchecked {
                validate()
            }
        }

        /// The field's view took the keyboard, or gave it up.
        package func editingChanged(_ isEditing: Bool) {
            editingState.value = isEditing
            if isEditing {
                host?.reveal(self)
            } else if validationTiming == .onEndEditing {
                validate()
            }
        }

        /// The user pressed Return: what the return key says is done.
        package func userSubmitted() {
            if validationTiming != .onInput {
                validate()
            }
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

        /// The next text input of the tree after this one, in the tree's order.
        private func nextField() -> (any TextInputNode)? {
            neighbor(1)
        }
    }

    /// A field for a password: it shows dots for what is typed, does not offer the text to
    /// autocorrection or the pasteboard's history, and lets the system fill in a saved password
    /// (`content` `.password`) or suggest a strong one (`.newPassword`). Everything else is a
    /// `TextField`'s: Return with `.next` goes to the next field, `text` is the password as
    /// typed.
    ///
    ///     let password = SecureField(placeholder: "Password")
    ///     password.onSubmit = { model.signIn(password: password.text) }
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class SecureField: TextField {
        /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override init(
            _ text: String = "",
            placeholder: String = "",
            content: TextContent = .password
        ) {
            super.init(text, placeholder: placeholder, content: content)
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var isSecure: Bool { true }
    }

    /// A field for an email address: the email keyboard, no autocorrection or capitals, what
    /// the system knows of the user's addresses, and a check of the address's form once the
    /// user leaves the field.
    ///
    ///     let email = EmailField(placeholder: "Email")
    ///     email.onValidationChange = { _ in model.emailProblem = email.validationMessage }
    ///
    /// The check is of the form only — text, an at sign, a domain with a dot — and says nothing
    /// of whether the address exists or is the user's. An app that knows more replaces
    /// `validator`. An empty field is `.unchecked`: that a value is needed is the form's rule.
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class EmailField: TextField {
        /// What the field says of an address that is not well formed.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public nonisolated static let defaultMessage =
            "Enter an email address such as name@example.com"

        /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(
            _ text: String = "",
            placeholder: String = "",
            message: String = EmailField.defaultMessage
        ) {
            super.init(text, placeholder: placeholder, content: .email)
            validator = { address in
                if address.isEmpty { return .unchecked }

                return EmailField.isWellFormed(address) ? .valid : .invalid(message)
            }
        }

        /// Whether `address` has the form of an email address: one at sign, text before it,
        /// and after it a domain of labels of letters, digits and hyphens, at least two, with no
        /// empty label; no spaces; at most 254 characters. Not whether it exists.
        ///
        /// Ownership: none. Isolation: none. Errors: none. Cancellation: not applicable.
        public nonisolated static func isWellFormed(_ address: String) -> Bool {
            guard address.count <= 254, !address.contains(where: \.isWhitespace) else {
                return false
            }

            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }

            let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2 else { return false }

            return labels.allSatisfy { label in
                !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            }
        }
    }
#endif
