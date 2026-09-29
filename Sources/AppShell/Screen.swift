import Nodes
import StateCore

/// What a navigation stack, a tab or a window shows as one screen: its title, the commands of
/// its toolbar, and whether it is the one shown. What it shows is its kind's: a tree of nodes
/// (`NodeScreen`), or a view controller of the platform (`ControllerScreen`, in the UIKit and
/// AppKit adapters). It carries out commands as a `CommandResponder`: those its content
/// leaves, before the stack around it.
///
/// A screen belongs to one place at a time: a stack does not take a screen that is already in
/// one.
///
/// Ownership: the stack keeps the screen while its entry is in the path or a move needs it.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
open class Screen: CommandResponder {
    private let titleState: State<String>
    private let toolbarState = State<[Command]>([])

    /// The screen's title, in the navigation bar or the window's title. Reading it under
    /// tracking depends on it: the adapters show a new title at once.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var title: String {
        get { titleState.value }
        set { titleState.value = newValue }
    }

    /// The commands the container shows as buttons around the screen — in its navigation bar,
    /// or the window's toolbar — enabled as the menus are (`canPerform`). Reading it under
    /// tracking depends on it.
    ///
    /// Ownership: values. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var toolbar: [Command] {
        get { toolbarState.value }
        set { toolbarState.value = newValue }
    }

    /// Whether the screen is the one its container shows, as last confirmed: set before
    /// `appeared()`, cleared before `disappeared()`. A screen under a sheet is still the one
    /// its stack shows.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public internal(set) var isPresented = false

    /// The place the screen is in, while it is in one.
    weak var owner: AnyObject?

    /// What the screen presents over itself, from `present(_:)` until it is gone.
    ///
    /// Ownership: kept by the screen. Isolation: MainActor. Errors: none. Cancellation:
    /// `presentation.dismiss()`.
    public internal(set) var presentation: Presentation?

    /// What shows the screen's presentations: set by the adapter showing the screen. A
    /// presentation asked for before waits for it.
    package weak var presentationPresenter: (any PresentationPresenter)? {
        didSet { presentation?.reconcile() }
    }

    /// The container around the screen — tabs, a split — shows it or not now: `appeared()` or
    /// `disappeared()` follow when that changes what the screen is. A screen in a stack is the
    /// stack's to tell; this is for one a container shows by itself.
    func setShown(_ shown: Bool) {
        guard shown != isPresented else { return }

        isPresented = shown
        if shown {
            appeared()
        } else {
            disappeared()
        }
    }

    /// Only the screens of the layer and of its adapters derive from it: the adapters show
    /// each kind their own way.
    package init(title: String) {
        titleState = State(title)
    }

    /// The screen became the one shown, once its move ended. A move taken back — a swipe
    /// back let go early — shows no new screen and calls nothing. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func appeared() {}

    /// The screen stopped being the one shown, once the move away ended. Its content stays
    /// while the screen is in the stack; work only for showing stops with the tree's
    /// `isShown`. The default does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    open func disappeared() {}
}

/// A screen showing a tree of nodes. Showing a node as a screen takes no class of its own:
///
///     NodeScreen(InboxNode(store: store), title: "Inbox")
///
/// The tree's commands go on to the screen and out through the stack around it.
///
/// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
open class NodeScreen: Screen {
    /// Ownership: kept by the screen. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let root: Node

    /// Ownership: keeps `root`, which must not be in another tree. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(_ root: Node, title: String = "") {
        self.root = root
        super.init(title: title)
    }
}
