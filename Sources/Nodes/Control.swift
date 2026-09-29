import LayoutCore
import StateCore

/// What a control shows itself as, several at once: a pressed button can have the focus.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ControlState: OptionSet, Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: Int

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A finger, the mouse, a key or the remote's select button is down on the control.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let pressed = ControlState(rawValue: 1 << 0)
    /// The control has the focus.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let focused = ControlState(rawValue: 1 << 1)
    /// The pointer rests over the control: the mouse on a Mac, a pointer on iPad.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let hovered = ControlState(rawValue: 1 << 2)
    /// The control is turned off: `isEnabled` is `false`, or its command cannot be carried
    /// out now.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let disabled = ControlState(rawValue: 1 << 3)
    /// The control is the chosen one of its kind: `isSelected`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let selected = ControlState(rawValue: 1 << 4)
}

/// A node that someone acts on — a button, a switch, a checkbox. It gathers what the tree
/// tells a node that can be pressed into one `state`, and a subclass shows it in
/// `stateChanged(from:)`:
///
///     final class Chip: Control {
///         override func stateChanged(from previous: ControlState) {
///             appearance.opacity = state.contains(.disabled) ? 0.4 : 1
///             appearance.background = state.contains(.pressed) ? pressedFill : fill
///         }
///     }
///
/// A press runs `onTap`, or carries out `command` where the control is. A control turned
/// off is not pressed, focused or pointed at, and says so to assistive technologies; a
/// press on it does not go through to what is behind it.
///
/// Ownership: the creator owns it. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
open class Control: Node {
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public override init() {
        super.init()
        refreshState()
    }

    /// Whether the control can be acted on. `true` by default.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }

            interactivityChanged()
        }
    }

    /// Whether the control is the chosen one of its kind — a tab shown, a filter on.
    /// `false` by default.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isSelected = false {
        didSet { if isSelected != oldValue { refreshState() } }
    }

    /// What a press carries out, from where the control is in the tree: the nearest node
    /// around it with a handler, or else the screen and the containers around the tree.
    /// While none can carry it out, the control is turned off. Set on a control without
    /// `onTap`, a press carries it out; its title is the control's tip unless `toolTip`
    /// says otherwise. `nil` by default.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var command: Command? {
        didSet {
            guard command != oldValue else { return }

            if command != nil, onTap == nil || pressCarriesCommand {
                pressCarriesCommand = true
                onTap = { [weak self] in self?.carryOutCommand() }
            } else if command == nil, pressCarriesCommand {
                pressCarriesCommand = false
                onTap = nil
            }
            watchCommand()
            host?.setNeedsRender()
        }
    }

    /// What the control shows itself as now.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var state: ControlState = []

    /// `state` changed — to show it. Also called once as the control is made, from no state
    /// at all. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func stateChanged(from previous: ControlState) {}

    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    public final override func pressChanged(_ isPressed: Bool) {
        isPressedNow = isPressed
        refreshState()
    }

    /// Keeps the default look of the focus — a lift on a TV — and adds `.focused` to
    /// `state`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    public final override func focusChanged(_ isFocused: Bool) {
        super.focusChanged(isFocused)
        refreshState()
    }

    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    public final override func hoverChanged(_ isHovered: Bool) {
        refreshState()
    }

    /// Starts watching whether `command` can be carried out as the control joins a tree,
    /// and lets go of a press and the pointer as it leaves. An override calls `super`.
    ///
    /// Ownership: keeps a watch on the command's handlers while mounted. Isolation:
    /// MainActor. Errors: none. Cancellation: the watch ends as the control leaves.
    open override func mountedChanged(_ isMounted: Bool) {
        if !isMounted {
            isPressedNow = false
        }
        watchCommand()
        refreshState()
    }

    // MARK: - Private

    /// Whether `onTap` is the one `command` put there.
    private var pressCarriesCommand = false
    /// Whether a press is down on the control; the host tells it, and forgets it when the
    /// control leaves the tree.
    private var isPressedNow = false
    /// Whether `command`, if any, can be carried out from where the control is.
    private var commandAvailable = true
    private var commandWatch: Effect?

    override var isInteractive: Bool { isEnabled && commandAvailable }

    override var shownToolTip: String? { toolTip ?? command?.title }

    private func carryOutCommand() {
        guard let command, let host else { return }

        host.perform(command, from: self)
    }

    private func watchCommand() {
        commandWatch?.cancel()
        commandWatch = nil
        guard let command, isMounted, let host else {
            if !commandAvailable {
                commandAvailable = true
                interactivityChanged()
            }
            return
        }

        commandWatch = Effect { [weak self, weak host] in
            guard let self, let host else { return }

            let available = host.canPerform(command, from: self)
            guard available != self.commandAvailable else { return }

            self.commandAvailable = available
            untracked { self.interactivityChanged() }
        }
    }

    /// The control was turned on or off: it gives up the focus it can no longer have, and
    /// shows it.
    private func interactivityChanged() {
        if !isInteractive, isFocused {
            host?.focus(nil)
        }
        refreshState()
        host?.setNeedsRender()
    }

    private func refreshState() {
        var next: ControlState = []
        if !isInteractive {
            next.insert(.disabled)
        } else {
            if isPressedNow { next.insert(.pressed) }
            if isHovered { next.insert(.hovered) }
        }
        if isFocused { next.insert(.focused) }
        if isSelected { next.insert(.selected) }
        guard next != state || !hasShownState else { return }

        let previous = state
        state = next
        hasShownState = true
        stateChanged(from: previous)
    }

    /// Whether `stateChanged(from:)` ran once, so that a control shows its first state.
    private var hasShownState = false
}

/// A node's tip and where it shows.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ToolTipItem: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let node: NodeID
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let text: String
    /// The part of the node that shows, in the root's coordinates.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect
}
