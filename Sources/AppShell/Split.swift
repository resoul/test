import Nodes
import StateCore

/// What a split can show beside its sidebar: a `Stack` or a `Screen`.
///
/// Ownership: the split keeps its content. Isolation: MainActor. Errors: none. Cancellation:
/// not applicable.
@MainActor
public protocol SplitContent: CommandResponder {}

extension Stack: SplitContent {}
extension Screen: SplitContent {}

/// A split as the adapters see it.
@MainActor
package protocol PresentedSplit: CommandResponder {
    var presentedSidebar: Screen { get }
    var presentedContent: any SplitContent { get }
    /// Whether the content, not the sidebar, is what shows when room is short for both;
    /// reading it under tracking depends on it.
    var isContentShown: Bool { get }
    /// The user went to the sidebar or to the content.
    func setContentShown(_ shown: Bool)
    /// The room is short for both: only one shows at a time. The adapter tells.
    func setCollapsed(_ collapsed: Bool)
    /// The container showing the split is on screen or not.
    func setOnScreen(_ onScreen: Bool)
    var platformContainer: AnyObject? { get set }
}

/// A sidebar beside a content: the sidebar's own screen — folders, sections — and the stack or
/// screen the sidebar's choice opens.
///
///     let split = Split(sidebar: NodeScreen(MailboxesNode(store: store), title: "Mailboxes"),
///                       content: inboxStack)
///     split.showContent()          // where room is short, after the choice
///
/// Both show where there is room. Where there is not — an iPhone, a narrow window —
/// `isContentShown` says which one shows: the sidebar first, the content after
/// `showContent()`, the sidebar again after `showSidebar()` and when the user goes back from
/// the content's first screen. The choice stays through turning and resizing.
///
/// The sidebar and the content are in the chain of commands between them and the window, and
/// commands go out from the focus: `Command.back` from the content's first screen returns to
/// the sidebar while only one shows.
///
/// Ownership: keeps the sidebar and the content. Isolation: MainActor. Errors: none.
/// Cancellation: `closeContent()` through the scene.
@MainActor
public final class Split: CommandResponder, SceneContent, TabContent {
    /// Ownership: kept. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let sidebar: Screen

    /// Ownership: kept. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let content: any SplitContent

    private let contentShownState = State(false)
    private var isCollapsed = false
    private var isOnScreen = false

    /// Whether the content, not the sidebar, shows where room is short for both. Reading it
    /// under tracking depends on it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isContentShown: Bool { contentShownState.value }

    /// The platform's container showing the split, while there is one.
    package weak var platformContainer: AnyObject?

    /// Ownership: keeps `sidebar` and `content` and takes them into the chain of commands.
    /// Isolation: MainActor. Errors: traps when the sidebar or the content is already in
    /// another place. Cancellation: not applicable.
    public init(sidebar: Screen, content: any SplitContent) {
        precondition(sidebar.owner == nil && sidebar.outer == nil, "The sidebar is in a place")
        precondition(
            content.outer == nil && (content as? Screen)?.owner == nil,
            "The content is already in another place"
        )
        self.sidebar = sidebar
        self.content = content
        super.init()
        sidebar.outer = self
        content.outer = self
        sidebar.setShown(false)
        (content as? any ShownByContainer)?.setShown(false)
        handle(.back, isEnabled: { [weak self] in
            guard let self else { return false }

            return isCollapsed && isContentShown
        }) { [weak self] in
            self?.showSidebar()
        }
    }

    /// Shows the content where room is short for both.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func showContent() {
        setContentShown(true)
    }

    /// Shows the sidebar where room is short for both.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func showSidebar() {
        setContentShown(false)
    }

    /// Lets go of the screens: the sidebar of what it presents, the content as its kind does.
    ///
    /// Ownership: releases what they keep. Isolation: MainActor. Errors: none. Cancellation:
    /// this is the cancellation.
    package func closeContent() {
        sidebar.presentation?.dismiss()
        (content as? any ClosableContent)?.closeContent()
        sidebar.outer = nil
        content.outer = nil
    }

    private func updateShown() {
        sidebar.setShown(isOnScreen && (!isCollapsed || !isContentShown))
        (content as? any ShownByContainer)?.setShown(
            isOnScreen && (!isCollapsed || isContentShown)
        )
    }
}

extension Split: ShownByContainer {
    func setShown(_ shown: Bool) {
        setOnScreen(shown)
    }
}

extension Split: PresentedSplit {
    package var presentedSidebar: Screen { sidebar }
    package var presentedContent: any SplitContent { content }

    package func setContentShown(_ shown: Bool) {
        guard shown != contentShownState.value else { return }

        contentShownState.value = shown
        updateShown()
    }

    package func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }

        isCollapsed = collapsed
        updateShown()
    }

    package func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }

        isOnScreen = onScreen
        updateShown()
    }
}
