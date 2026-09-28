import Nodes
import StateCore

/// How a presentation covers the window:
///
///     Presentation(compose)                                         // a sheet
///     Presentation(share, style: .sheet(heights: [.medium, .large])) // half, drawn up to full
///     Presentation(player, style: .fullScreen)
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PresentationStyle: Hashable, Sendable {
    /// Whether it covers the whole window on iPhone, iPad and TV. A Mac shows every
    /// presentation as a sheet of the window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let coversWindow: Bool

    /// The heights a sheet stops at on iPhone and iPad, in the order given; empty for a
    /// presentation over the whole window. A TV shows a sheet over the whole screen, a Mac
    /// as a sheet of its window, whatever its heights.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let heights: [SheetHeight]

    /// The largest height at which the screen under the sheet stays usable — not dimmed,
    /// taking touches, and its commands where the user is — as the map under a sheet of
    /// places does; `nil` when the screen under is covered at every height. On iPhone and
    /// iPad only.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let usableBelow: SheetHeight?

    /// A sheet over the screen, which shows around it: a page sheet on iPhone and iPad, a
    /// sheet of the window on a Mac. A TV shows it over the whole screen.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let sheet = PresentationStyle(coversWindow: false, heights: [.large])

    /// Over the whole window on iPhone, iPad and TV; a sheet of the window on a Mac.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let fullScreen = PresentationStyle(coversWindow: true, heights: [])

    /// A sheet that stops at `heights` — the user drags it from one to another by its
    /// grabber, which shows while there are two or more. It opens at the first. No heights
    /// is `.large`; a height given twice counts once. Up to `usableBelow`, one of the
    /// heights, the screen under it stays usable; a height not among them counts as none.
    ///
    ///     .sheet(heights: [.fraction(0.2), .medium, .large], usableBelow: .medium)
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func sheet(
        heights: [SheetHeight],
        usableBelow: SheetHeight? = nil
    ) -> PresentationStyle {
        var unique: [SheetHeight] = []
        for height in heights where !unique.contains(height) {
            unique.append(height)
        }
        let all = unique.isEmpty ? [SheetHeight.large] : unique
        return PresentationStyle(
            coversWindow: false,
            heights: all,
            usableBelow: usableBelow.flatMap { all.contains($0) ? $0 : nil }
        )
    }

    private init(coversWindow: Bool, heights: [SheetHeight], usableBelow: SheetHeight? = nil) {
        self.coversWindow = coversWindow
        self.heights = heights
        self.usableBelow = usableBelow
    }
}

/// A height a sheet stops at on iPhone and iPad.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SheetHeight: Hashable, Sendable {
    /// About half the screen.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case medium
    /// The full height of a sheet.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case large
    /// This many points, at most the full height.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case points(Double)
    /// This part of the full height, from 0 to 1.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case fraction(Double)
}

/// For platform adapters: what shows a screen's presentations over it — the container the
/// screen is in, or the screen's own controller.
///
/// Ownership: the screen does not keep it. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public protocol PresentationPresenter: AnyObject {
    /// Shows `presentation` over the screen; when it shows — at once, or after its
    /// animation — calls `presentation.showEnded(completed: true)`, or `false` when the
    /// platform cannot show it now.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: `showEnded(completed: false)`.
    /// Cancellation: not applicable.
    func show(_ presentation: Presentation)

    /// Takes `presentation` away; when it is gone, calls `presentation.hideEnded()`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func hide(_ presentation: Presentation)
}

/// A screen or a stack shown modally over a screen — a sheet, or over the whole window —
/// until it is dismissed:
///
///     let compose = Presentation(NodeScreen(ComposeNode(), title: "New Message"))
///     inboxScreen.present(compose)
///     …
///     compose.dismiss()
///
/// It is not an entry of the stack under it: the stack's path stays as it was, and a stack
/// inside the presentation is a stack of its own. While it shows, the commands of its
/// content go on to the presentation and then to the window around — not to the screen or
/// the stack under it. A sheet whose style leaves the screen under usable
/// (`PresentationStyle.usableBelow`) lets the user work there too: the commands then go
/// from where the user is. The user closes it with Escape (`Command.cancel`), Menu on the remote
/// (`Command.back`, when the content does not go back itself) or a swipe down of a sheet —
/// while `isDismissible`; a swipe let go early leaves it as it was. `dismiss()` closes it
/// always.
///
/// Once dismissed, it lets go of its content — a stack is closed — and cannot be presented
/// again: a new one is made for the next time.
///
/// Ownership: the presenting screen keeps it while it is presented; it keeps its content.
/// Isolation: MainActor. Errors: `Screen.present` returns `NavigationResult`. Cancellation:
/// `dismiss()`.
@MainActor
public final class Presentation: CommandResponder {
    /// Where a presentation is between being asked for and gone.
    enum Phase {
        /// Asked for, not shown yet: no presenter, or the presenter could not start.
        case waiting
        case showing
        case shown
        case hiding
        case gone
    }

    /// Ownership: kept by the presentation until it is gone. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    public let content: any PresentationContent

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let style: PresentationStyle

    private let dismissibleState = State(true)
    private let shownState = State(false)
    private let heightState: State<SheetHeight>
    private(set) var phase = Phase.waiting
    /// Whether it is still asked for: `dismiss()` clears it.
    package private(set) var isWanted = true
    /// The screen it is presented over, while it is.
    package private(set) weak var presenting: Screen?

    /// Whether the user can close it — Escape, Menu, a swipe down. While not, a swipe down
    /// holds back, and those tries call `onDismissAttempt` instead: a draft can ask whether
    /// to throw itself away. Reading it under tracking depends on it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isDismissible: Bool {
        get { dismissibleState.value }
        set { dismissibleState.value = newValue }
    }

    /// Called when the user tries to close a presentation that is not `isDismissible`.
    ///
    /// Ownership: the presentation keeps the closure; it must not keep the presentation.
    /// Isolation: MainActor. Errors: none. Cancellation: set to `nil`.
    public var onDismissAttempt: (@MainActor () -> Void)?

    /// Called once when the presentation is gone — dismissed by the user or by `dismiss()`,
    /// or never shown because the platform could not.
    ///
    /// Ownership: the presentation keeps the closure; it must not keep the presentation.
    /// Isolation: MainActor. Errors: none. Cancellation: set to `nil`.
    public var onDismissed: (@MainActor () -> Void)?

    /// The height the sheet stops at now, one of its style's `heights`: the first when it
    /// opens, then where the user drags it. Setting it moves the sheet there; a height the
    /// style does not have is ignored. Reading it under tracking depends on it. A
    /// presentation over the whole window has none: `.large`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var height: SheetHeight {
        get { heightState.value }
        set {
            guard style.heights.contains(newValue) else { return }

            heightState.value = newValue
        }
    }

    /// Whether the presentation shows, as the platform last confirmed. Reading it under
    /// tracking depends on it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isShown: Bool { shownState.value }

    /// A presentation of `content`: a screen, or a stack of screens. An alert is presented
    /// by `Screen.present(_: Alert)`.
    ///
    /// Ownership: keeps `content`, which must not be shown elsewhere. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(_ content: any PresentationContent, style: PresentationStyle = .sheet) {
        self.content = content
        self.style = style
        heightState = State(style.heights.first ?? .large)
        super.init()
        for command in [Command.cancel, .back] {
            handle(command, isEnabled: { [weak self] in self?.phase == .shown }) {
                [weak self] in
                self?.userAsked()
            }
        }
    }

    /// Closes the presentation, whether the user can or not. A presentation not shown yet
    /// is not shown at all.
    ///
    /// Ownership: lets go of the content once it is gone. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    public func dismiss() {
        guard isWanted else { return }

        isWanted = false
        reconcile()
    }

    // MARK: - For platform adapters

    /// Whether the user can begin closing it now: it shows, and `isDismissible`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var canBeginUserDismiss: Bool {
        phase == .shown && isDismissible
    }

    /// The presenter's show ended: `completed` when the presentation shows.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func showEnded(completed: Bool) {
        guard phase == .showing else { return }

        guard completed else {
            isWanted = false
            finish()
            return
        }

        phase = .shown
        shownState.value = true
        if let screen = content as? Screen {
            screen.isPresented = true
            screen.appeared()
        }
        reconcile()
    }

    /// The presenter's hide ended: the presentation is gone.
    ///
    /// Ownership: lets go of the content. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func hideEnded() {
        guard phase == .hiding else { return }

        finish()
    }

    /// The user closed the presentation by the platform's own means — a sheet swiped down
    /// all the way. A swipe let go early is not reported, and changes nothing.
    ///
    /// Ownership: lets go of the content. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func userDismissed() {
        guard phase == .shown else { return }

        isWanted = false
        finish()
    }

    /// The user dragged the sheet to `height`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func userMoved(to height: SheetHeight) {
        self.height = height
    }

    /// The user tried to close it by the platform's own means while it cannot be closed.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func userDismissAttempted() {
        guard phase == .shown else { return }

        onDismissAttempt?()
    }

    // MARK: - Package

    /// Presents it over `screen`.
    func begin(over screen: Screen) {
        presenting = screen
        // Commands of the content go past the presentation to the window, not the screen
        // or the stack under it.
        var around = screen.outer
        while let current = around, !(current is SceneSession) {
            around = current.outer
        }
        outer = around
        content.outer = self
        if let screen = content as? Screen {
            screen.owner = self
        }
        reconcile()
    }

    /// Whether it was presented before — it is presented once.
    var hasBegun: Bool { presenting != nil || phase == .gone }

    /// Starts showing or hiding, when the presenter is free and the presentation is not
    /// where it is asked to be.
    func reconcile() {
        switch (isWanted, phase) {
        case (true, .waiting):
            guard let presenter = presenting?.presentationPresenter else { return }

            phase = .showing
            presenter.show(self)
        case (false, .waiting):
            finish()
        case (false, .shown):
            guard let presenter = presenting?.presentationPresenter else {
                finish()
                return
            }

            phase = .hiding
            presenter.hide(self)
        default:
            break
        }
    }

    private func userAsked() {
        if isDismissible {
            dismiss()
        } else {
            onDismissAttempt?()
        }
    }

    private func finish() {
        let wasShown = phase == .shown || phase == .hiding
        phase = .gone
        shownState.value = false
        if let screen = content as? Screen {
            if wasShown, screen.isPresented {
                screen.isPresented = false
                screen.disappeared()
            }
            if screen.owner === self {
                screen.owner = nil
            }
            screen.presentation?.dismiss()
        }
        (content as? any PresentedStack)?.close()
        content.outer = nil
        outer = nil
        if let presenting, presenting.presentation === self {
            presenting.presentation = nil
        }
        presenting = nil
        let done = onDismissed
        onDismissed = nil
        onDismissAttempt = nil
        done?()
    }
}

extension Screen {
    /// Shows `presentation` over the screen: at once when the screen shows, else when it
    /// does. A screen presents one at a time.
    ///
    /// Ownership: the screen keeps the presentation until it is gone. Isolation:
    /// MainActor. Errors: `.alreadyPresenting` while the screen presents another;
    /// `.screenInUse` for a presentation presented before or content shown elsewhere.
    /// Cancellation: `presentation.dismiss()`.
    @discardableResult
    public func present(_ presentation: Presentation) -> NavigationResult {
        guard self.presentation == nil else { return .rejected(.alreadyPresenting) }
        guard !presentation.hasBegun else { return .rejected(.screenInUse) }
        if let screen = presentation.content as? Screen, screen.owner != nil || screen === self {
            return .rejected(.screenInUse)
        }

        self.presentation = presentation
        presentation.begin(over: self)
        return .accepted
    }
}
