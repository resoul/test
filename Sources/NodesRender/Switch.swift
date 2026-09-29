#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import StateCore
    import ThemeCore

    /// An on/off switch drawn by the theme, the same on every platform: a track in the accent
    /// color when on, in the separator color when off, and a knob that slides between the two
    /// ends. Tapping it, or Space, Return or Select while it is focused, turns it over and
    /// tells `onChange`; writing `isOn` from code does not.
    ///
    ///     let notifications = Switch(isOn: settings.notifications, label: "Notifications")
    ///     notifications.onChange = { settings.notifications = $0 }
    ///
    /// The value is observable: reading `isOn` in an effect depends on it. For VoiceOver and the
    /// other assistive tools it is a toggle with the value on or off and `label` as its name.
    ///
    /// Ownership: owns its knob. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class Switch: Control {
        private let isOnState: State<Bool>
        let knob = Knob()

        /// Whether the switch is on. Reading it under tracking depends on it; a write inside
        /// `withAnimation` slides the knob with that animation.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isOn: Bool {
            get { isOnState.value }
            set { isOnState.value = newValue }
        }

        /// The user turned the switch over: with the value it has now. Not called for a write
        /// of `isOn`.
        ///
        /// Ownership: keeps the closure, which must not keep the switch. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public var onChange: (@MainActor (Bool) -> Void)?

        /// A switch, on or off, with `label` as the name assistive tools give it.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public init(isOn: Bool = false, label: String = "") {
            isOnState = State(isOn)
            super.init()
            appearance.cornerRadius = Switch.height / 2
            if !label.isEmpty {
                accessibility.label = label
            }
            accessibility.traits = [.toggle]
            onTap = { [weak self] in
                guard let self else { return }

                withAnimation(.spring(response: 0.3, dampingRatio: 0.8)) {
                    self.isOn.toggle()
                }
                onChange?(self.isOn)
            }
        }

        static let width = 51.0
        static let height = 31.0
        private static let inset = 2.0

        /// The knob: a white circle, that slides by `offset` from the track's start.
        final class Knob: Node {
            override init() {
                super.init()
                appearance.background = .white
                appearance.cornerRadius = (Switch.height - 2 * Switch.inset) / 2
                appearance.shadow = Shadow(opacity: 0.25, radius: 2, x: 0, y: 1)
            }

            override var layoutContent: LeafContent? {
                let side = Switch.height - 2 * Switch.inset
                return .size(width: side, height: side)
            }
        }

        public override func update() {
            let theme = self.theme
            let on = isOnState.value
            appearance.background = on ? theme.color(.accent) : theme.color(.separator)
            knob.appearance.offset = LayoutPoint(
                x: on ? Switch.width - Switch.height : 0,
                y: 0
            )
            accessibility.value = on ? "1" : "0"
        }

        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { knob }
                .size(width: .points(Switch.width), height: .points(Switch.height))
                .padding(Switch.inset)
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
