#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore

    /// A field of several lines of text, which the platform's own text view shows and edits:
    /// every language's input, dictation, the selection and its menu, undo and what the system
    /// fills in all work as in any app. Return starts a new line.
    ///
    ///     let notes = TextEditor(placeholder: "Notes")
    ///     notes.minLines = 3
    ///     notes.onChange = { model.notes = $0 }
    ///
    /// It is `minLines` lines high when empty, grows with its text up to `maxLines` lines, and
    /// scrolls inside itself beyond that. While it is edited, the scrolls around it keep it
    /// above the keyboard.
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class TextEditor: EmbeddedNode {
        private let textState: State<String>
        private let editingState = State(false)

        /// The text. Reading it under tracking depends on it; setting it shows the new text
        /// without calling `onChange`.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var text: String {
            get { textState.value }
            set { textState.value = newValue }
        }

        /// What the empty editor shows.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var placeholder: String

        /// How many lines high it is when its text is shorter.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var minLines = 3 {
            didSet { if minLines != oldValue { setNeedsLayout() } }
        }

        /// How many lines high it grows to; more text scrolls inside it. `nil` grows without a
        /// limit.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var maxLines: Int? = 8 {
            didSet { if maxLines != oldValue { setNeedsLayout() } }
        }

        /// How many characters it takes at most: what the user types or pastes beyond it is cut
        /// off, in the view as in `text`. `nil` is no limit. Text set by code is not cut.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var maxLength: Int?

        /// Called when the user changes the text.
        ///
        /// Ownership: the editor keeps the closure; it must not keep the editor. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var onChange: (@MainActor (String) -> Void)?

        /// Whether the editor has the keyboard. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isEditing: Bool { editingState.value }

        /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(_ text: String = "", placeholder: String = "") {
            textState = State(text)
            self.placeholder = placeholder
            super.init()
        }

        /// Gives the editor the keyboard; it takes it once it shows.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: `endEditing()`.
        public func beginEditing() {
            onEditingRequest?(true)
        }

        /// Takes the keyboard away from the editor.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func endEditing() {
            onEditingRequest?(false)
        }

        // MARK: - For platform adapters

        /// Set by the adapter: gives the editor's view the keyboard, or takes it away.
        package var onEditingRequest: (@MainActor (Bool) -> Void)?

        /// The user changed the text in the editor's view.
        package func userChanged(_ typed: String) {
            let text = maxLength.map { String(typed.prefix(max($0, 0))) } ?? typed
            guard text != textState.value else { return }

            textState.value = text
            onChange?(text)
        }

        /// The editor's view took the keyboard, or gave it up.
        package func editingChanged(_ isEditing: Bool) {
            editingState.value = isEditing
            if isEditing {
                host?.reveal(self)
            }
        }

        /// The height, in points, that `minLines` and `maxLines` of text with a line `lineHeight`
        /// high and `insets` above and below make, and whether `contentHeight` needs more than
        /// the most: the view scrolls then.
        package func height(
            forContent contentHeight: Double,
            lineHeight: Double,
            insets: Double
        ) -> (height: Double, scrolls: Bool) {
            let least = Double(max(minLines, 1)) * lineHeight + insets
            let most = maxLines.map { Double(max($0, max(minLines, 1))) * lineHeight + insets }
            let wanted = max(contentHeight, least)
            guard let most, wanted > most else { return (wanted, false) }

            return (most, true)
        }
    }
#endif
