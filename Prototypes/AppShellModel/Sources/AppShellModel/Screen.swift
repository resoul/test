import Nodes

/// What a navigation stack, a tab or a window shows as one screen: its title, the commands of
/// its toolbar, and whether it is the one shown. What it shows is its kind's: a tree of nodes
/// (`NodeScreen`), or a view controller of the platform (`ControllerScreen`). It carries out
/// commands as a `CommandResponder`: those its content leaves, before the stack around it.
///
/// A screen belongs to one place at a time: a stack does not take a screen that is already in
/// one.
///
/// Ownership: the stack keeps the screen while its entry is in the path or a move needs it.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
open class Screen: CommandResponder {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var title: String

    /// The commands the container shows as buttons around the screen — in its navigation bar,
    /// or the window's toolbar — enabled as the menus are (`canPerform`).
    ///
    /// Ownership: values. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var toolbar: [Command] = []

    /// Whether the screen is the one its container shows, as last confirmed: set before
    /// `appeared()`, cleared before `disappeared()`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public internal(set) var isPresented = false

    /// The place the screen is in, while it is in one.
    weak var owner: AnyObject?

    // In the module this is `package`: only the screens of the layer and of its adapters
    // (`ControllerScreen`) derive from it, as the adapters show each kind their own way.
    init(title: String) {
        self.title = title
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

/// A screen showing a view controller of the platform — a stand-in here for the adapters'
/// `ControllerScreen(UIViewController)` and `ControllerScreen(NSViewController)`, which own
/// the controller and pass it the screen's life and input.
///
/// Ownership: keeps `controller`. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
open class ControllerScreen: Screen {
    /// Ownership: kept by the screen. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let controller: AnyObject

    /// Ownership: keeps `controller`, which must not be shown elsewhere. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public init(_ controller: AnyObject, title: String = "") {
        self.controller = controller
        super.init(title: title)
    }
}
