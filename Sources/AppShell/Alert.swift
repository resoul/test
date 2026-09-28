import Nodes

/// What an alert's action is for: how the platform shows it, and which one Escape and Menu
/// choose.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AlertActionRole: Hashable, Sendable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case normal
    /// Leaves things as they were: Escape and Menu on the remote choose it. An alert has
    /// one; another cancel action counts as a normal one.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case cancel
    /// Destroys something: shown in red.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case destructive
}

/// A button of an alert, and what choosing it does.
///
/// Ownership: value; it keeps `perform`. Isolation: MainActor. Errors: none. Cancellation:
/// not applicable.
@MainActor
public struct AlertAction {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let title: String

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let role: AlertActionRole

    let perform: @MainActor () -> Void

    /// Ownership: keeps `perform`, which must not keep the alert. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(
        _ title: String,
        role: AlertActionRole = .normal,
        perform: @escaping @MainActor () -> Void = {}
    ) {
        self.title = title
        self.role = role
        self.perform = perform
    }

    /// Cancel, doing nothing.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static var cancel: AlertAction { AlertAction("Cancel", role: .cancel) }
}

/// Builds the actions of an `Alert`.
///
/// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
@resultBuilder
public enum AlertActionBuilder {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ action: AlertAction) -> [AlertAction] {
        [action]
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildBlock(_ parts: [AlertAction]...) -> [AlertAction] {
        parts.flatMap { $0 }
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildOptional(_ part: [AlertAction]?) -> [AlertAction] {
        part ?? []
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildEither(first part: [AlertAction]) -> [AlertAction] {
        part
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildEither(second part: [AlertAction]) -> [AlertAction] {
        part
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildArray(_ parts: [[AlertAction]]) -> [AlertAction] {
        parts.flatMap { $0 }
    }
}

/// How an alert shows.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AlertStyle: Hashable, Sendable {
    /// A box in the middle of the screen, or a sheet of a Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case alert
    /// A list of actions: from the bottom of an iPhone, in a popover on iPad, over the whole
    /// screen of a TV; a Mac shows it as an alert.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case actions
}

/// An alert, or a list of actions, over a screen: a title, a message, and buttons — choosing
/// one closes it and does what the button does:
///
///     let alert = Alert("Delete the message?", message: "This cannot be undone.") {
///         AlertAction("Delete", role: .destructive) { deleteMessage() }
///         AlertAction.cancel
///     }
///     screen.present(alert)
///
/// It is a presentation like a sheet: the screen shows one at a time, its commands go past
/// the screen under it, and `dismiss()` closes it choosing nothing. Escape and Menu on the
/// remote choose the cancel action; an alert without one closes only by its buttons. With no
/// actions, it has an OK button.
///
/// Ownership: the presenting screen keeps it while it shows. Isolation: MainActor. Errors:
/// `Screen.present` returns `NavigationResult`. Cancellation: `dismiss()`.
@MainActor
public final class Alert: CommandResponder, PresentationContent {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let title: String

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let message: String?

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let style: AlertStyle

    /// The buttons, in the order given; at most one of them cancels.
    ///
    /// Ownership: values. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let actions: [AlertAction]

    /// The presentation showing it, while there is one.
    package private(set) weak var presentation: Presentation?
    /// Whether it was presented: an alert shows once.
    private(set) var wasPresented = false

    /// Ownership: keeps the actions. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(
        _ title: String,
        message: String? = nil,
        style: AlertStyle = .alert,
        @AlertActionBuilder actions: () -> [AlertAction] = { [] }
    ) {
        self.title = title
        self.message = message
        self.style = style
        var hasCancel = false
        var kept: [AlertAction] = []
        for action in actions() {
            if action.role == .cancel {
                kept.append(
                    hasCancel ? AlertAction(action.title, perform: action.perform) : action
                )
                hasCancel = true
            } else {
                kept.append(action)
            }
        }
        self.actions = kept.isEmpty ? [AlertAction("OK")] : kept
        super.init()
        for command in [Command.cancel, .back] {
            handle(command, isEnabled: { [weak self] in self?.cancelIndex != nil }) {
                [weak self] in
                guard let self, let index = cancelIndex else { return }

                choose(index)
            }
        }
    }

    /// Closes the alert, choosing nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func dismiss() {
        presentation?.dismiss()
    }

    /// The index of the cancel action, if there is one.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var cancelIndex: Int? {
        actions.firstIndex { $0.role == .cancel }
    }

    // MARK: - For platform adapters

    /// The user chose the action at `index`: the platform closed the alert. It closes, and
    /// the action is done.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func choose(_ index: Int) {
        guard actions.indices.contains(index), let presentation, presentation.isShown else {
            return
        }

        presentation.userDismissed()
        actions[index].perform()
    }

    /// Presents it by `presentation`.
    func begin(by presentation: Presentation) {
        self.presentation = presentation
        wasPresented = true
        presentation.isDismissible = cancelIndex != nil
    }
}

extension Screen {
    /// Shows `alert` over the screen, as `present(_:)` shows a presentation.
    ///
    /// Ownership: the screen keeps the alert until it closes. Isolation: MainActor.
    /// Errors: `.alreadyPresenting` while the screen presents something; `.screenInUse` for
    /// an alert shown before. Cancellation: `alert.dismiss()`.
    @discardableResult
    public func present(_ alert: Alert) -> NavigationResult {
        guard presentation == nil else { return .rejected(.alreadyPresenting) }
        guard !alert.wasPresented else {
            return .rejected(.screenInUse)
        }

        let presentation = Presentation(alert)
        alert.begin(by: presentation)
        return present(presentation)
    }
}
