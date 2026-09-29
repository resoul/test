#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import RichTextCore
    import StateCore

    /// A field of several lines of styled text, which the platform's own text view shows and
    /// edits: every language's input, dictation, the selection, undo and what the system fills
    /// in work as in any app. The text is a `RichText` — paragraphs, quotes and code, with bold,
    /// italic, monospaced, struck and underlined runs and links — and what the user types is
    /// read back into one, so `richText` and `onChange` always hold a value in normal form.
    ///
    ///     let note = RichTextEditor(placeholder: "Write a note")
    ///     note.onChange = { model.note = $0 }
    ///
    /// Return in a quote or in code adds a line to the block, and on an empty last line leaves
    /// it; Backspace at the start of a quote or of code makes the block a paragraph. Like
    /// `TextEditor`, it is `minLines` lines high when empty, grows up to `maxLines` lines and
    /// scrolls inside itself beyond that, and the scrolls around it keep it above the keyboard.
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class RichTextEditor: EmbeddedNode {
        private let textState: State<RichText>
        private let editingState = State(false)

        /// The text. Reading it under tracking depends on it; setting it shows the new text
        /// without calling `onChange`, and forgets what the view could undo, as that was about
        /// other text.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var richText: RichText {
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

        /// Called when the user changes the text, once the change is complete — not while a
        /// word is being composed in an input method.
        ///
        /// Ownership: the editor keeps the closure; it must not keep the editor. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var onChange: (@MainActor (RichText) -> Void)?

        /// Whether the editor has the keyboard. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isEditing: Bool { editingState.value }

        /// Ownership: the caller keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(_ text: RichText = RichText(), placeholder: String = "") {
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

        /// The user changed the text in the editor's view; it is what the view now holds,
        /// read back.
        package func userChanged(_ text: RichText) {
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

    extension RichTextEditor: TextInputNode {}
#endif
