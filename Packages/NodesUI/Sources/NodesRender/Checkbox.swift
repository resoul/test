#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore
    import ThemeCore

    /// What a check box shows: nothing chosen, chosen, or some of what it stands for chosen —
    /// the "select all" of a list with some of its rows selected.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum CheckState: Sendable, Hashable {
        case off
        case on
        case mixed
    }

    /// A check box drawn by the theme, the same on every platform: a rounded square, filled in
    /// the accent color with a check mark when on, with a dash when mixed, and an outline only
    /// when off. Tapping it, or Space, Return or Select while it is focused, chooses it —
    /// off and mixed become on, on becomes off — and tells `onChange`; writing `value` from
    /// code does not.
    ///
    ///     let all = Checkbox(.mixed, label: "Select all")
    ///     all.onChange = { rows.selectAll($0 == .on) }
    ///
    /// The value is observable. For VoiceOver and the other assistive tools it is a toggle
    /// with the value 0, 1 or 2, and `label` as its name.
    ///
    /// Ownership: owns its mark. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class Checkbox: Control {
        private let valueState: State<CheckState>
        let mark = Text("", style: TextStyle(size: 15, weight: .bold))

        /// What the check box shows. Reading it under tracking depends on it; a write inside
        /// `withAnimation` fades the mark and the fill with that animation.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var value: CheckState {
            get { valueState.value }
            set { valueState.value = newValue }
        }

        /// The user chose or cleared the check box: with the value it has now. Not called for a
        /// write of `value`.
        ///
        /// Ownership: keeps the closure, which must not keep the check box. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var onChange: (@MainActor (CheckState) -> Void)?

        /// A check box showing `value`, with `label` as the name assistive tools give it.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public init(_ value: CheckState = .off, label: String = "") {
            valueState = State(value)
            super.init()
            appearance.cornerRadius = 6
            appearance.borderWidth = 2
            if !label.isEmpty {
                accessibility.label = label
            }
            accessibility.traits = [.toggle]
            // The mark is drawn by the box, not read on its own.
            mark.accessibility.isElement = false
            onTap = { [weak self] in
                guard let self else { return }

                withAnimation(.easeInOut(duration: 0.15)) {
                    self.value = self.value == .on ? .off : .on
                }
                onChange?(self.value)
            }
        }

        static let side = 22.0

        public override func update() {
            let theme = self.theme
            let value = valueState.value
            let filled = value != .off
            appearance.background = filled ? theme.color(.accent) : nil
            appearance.borderColor = filled ? theme.color(.accent) : theme.color(.separator)
            mark.style.color = theme.color(.onAccent)
            mark.text =
                switch value {
                case .off: ""
                case .on: "✓"
                case .mixed: "–"
                }
            mark.appearance.opacity = filled ? 1 : 0
            accessibility.value =
                switch value {
                case .off: "0"
                case .on: "1"
                case .mixed: "2"
                }
        }

        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { mark }
                .size(width: .points(Checkbox.side), height: .points(Checkbox.side))
                .justifyContent(.center)
                .alignItems(.center)
        }

        public override func stateChanged(from previous: ControlState) {
            appearance.opacity =
                if state.contains(.disabled) {
                    0.4
                } else if state.contains(.pressed) {
                    0.7
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
