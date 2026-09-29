#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore

    /// A control that shows one of several options and opens a menu of them: the platform's
    /// own — a pop-up menu with a check mark by the chosen option on iPhone, iPad and Apple TV,
    /// a pop-up button on the Mac.
    ///
    ///     let sort = Select(options: [Sort.date, .sender, .subject], selection: .date) {
    ///         $0.title
    ///     }
    ///     sort.onChange = { model.sort = $0 }
    ///
    /// Ownership: the tree keeps the node. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class Select<Option: Hashable>: EmbeddedNode {
        private let optionsState: State<[Option]>
        private let selectionState: State<Option?>
        private let enabledState = State(true)

        /// What each option is called in the menu and on the button.
        ///
        /// Ownership: the select keeps the closure; it must not keep the select. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public let title: @MainActor (Option) -> String

        /// What the button says while no option is chosen.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var placeholder: String

        /// The options in the menu, in order. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var options: [Option] {
            get { optionsState.value }
            set { optionsState.value = newValue }
        }

        /// The chosen option, or `nil`. Reading it under tracking depends on it; setting it
        /// shows the choice without calling `onChange`.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var selection: Option? {
            get { selectionState.value }
            set { selectionState.value = newValue }
        }

        /// Whether the user can open the menu. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isEnabled: Bool {
            get { enabledState.value }
            set { enabledState.value = newValue }
        }

        /// Called when the user chooses an option — a different one, or the one chosen again.
        ///
        /// Ownership: the select keeps the closure; it must not keep the select. Isolation:
        /// MainActor. Errors: none. Cancellation: set to `nil`.
        public var onChange: (@MainActor (Option) -> Void)?

        /// Ownership: keeps `title`, which must not keep the node. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public init(
            options: [Option],
            selection: Option? = nil,
            placeholder: String = "Select",
            title: @escaping @MainActor (Option) -> String
        ) {
            optionsState = State(options)
            selectionState = State(selection)
            self.placeholder = placeholder
            self.title = title
            super.init()
        }

        /// What the button says: the chosen option's title, else the placeholder.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var label: String {
            selection.map(title) ?? placeholder
        }

        // MARK: - For platform adapters

        /// The user chose `option` in the menu.
        package func userChose(_ option: Option) {
            selectionState.value = option
            onChange?(option)
        }
    }
#endif
