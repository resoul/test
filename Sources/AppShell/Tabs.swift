import Nodes
import StateCore

/// What a tab can show: a `Stack`, a `Screen`, or a `Split`. Tabs in tabs are not allowed.
///
/// Ownership: the tabs keep their contents. Isolation: MainActor. Errors: none. Cancellation:
/// not applicable.
@MainActor
public protocol TabContent: CommandResponder {}

extension Stack: TabContent {}
extension Screen: TabContent {}

/// What the container around content shows or hides: the content's top screen is told.
@MainActor
protocol ShownByContainer {
    func setShown(_ shown: Bool)
}

extension Stack: ShownByContainer {}
extension Screen: ShownByContainer {}

/// What goes on when a scene is closed for good: the content lets go of its screens and what
/// they present.
@MainActor
package protocol ClosableContent {
    func closeContent()
}

extension Stack: ClosableContent {
    package func closeContent() { close() }
}

extension Screen: ClosableContent {
    package func closeContent() { presentation?.dismiss() }
}

/// One tab of `Tabs`: how it is picked, and what it shows.
///
///     Tab(MailTab.inbox, title: "Inbox", symbol: "tray", content: inboxStack)
///
/// Ownership: keeps the content until the tabs take it. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public struct Tab<ID: Hashable> {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let id: ID

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let title: String

    /// The name of an SF Symbol shown with the title where the platform shows an image; `nil`,
    /// the title alone.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let symbol: String?

    /// Ownership: kept. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let content: any TabContent

    /// Ownership: keeps `content`, which must not be in another place. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(_ id: ID, title: String, symbol: String? = nil, content: any TabContent) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.content = content
    }
}

/// A tab as the adapters see it, whatever the type of its id.
@MainActor
package struct PresentedTab {
    package let title: String
    package let symbol: String?
    package let content: any TabContent
}

/// Tabs as the adapters see them, whatever the type of their ids.
@MainActor
package protocol PresentedTabs: CommandResponder {
    /// The tabs in order.
    var presentedTabs: [PresentedTab] { get }
    /// The index of the selected tab; reading it under tracking depends on the selection.
    var selectedIndex: Int { get }
    /// The user picked the tab at `index`.
    func pick(index: Int)
    /// The container showing the tabs is on screen or not: the selected tab's content is the
    /// one shown while it is.
    func setOnScreen(_ onScreen: Bool)
    var platformContainer: AnyObject? { get set }
}

/// Tabs: several contents of the scene, one shown at a time, picked in a bar. What a tab
/// shows keeps its state — a stack its path, a screen its tree — while another is picked;
/// only the selected tab's content is the one shown and takes commands.
///
///     let tabs = Tabs(selection: MailTab.inbox, [
///         Tab(.inbox, title: "Inbox", symbol: "tray", content: inboxStack),
///         Tab(.search, title: "Search", symbol: "magnifyingglass", content: searchScreen),
///     ])
///     tabs.select(.search)
///
/// The tabs are in the chain of commands between each tab's content and the window: a command
/// goes out from the focus, so a tab not picked, whose trees have none, takes none.
///
/// Ownership: keeps its tabs and their contents. Isolation: MainActor. Errors: `select` says
/// whether there is such a tab. Cancellation: `closeContent()` through the scene.
@MainActor
public final class Tabs<ID: Hashable>: CommandResponder, SceneContent {
    private let tabs: [Tab<ID>]
    private let selectionState: State<ID>
    private var isOnScreen = false

    /// The platform's container showing the tabs, while there is one: the tabs are shown in
    /// one place, and asking the adapter again gives the same container.
    package weak var platformContainer: AnyObject?

    /// The id of the selected tab. Reading it under tracking depends on it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var selection: ID { selectionState.value }

    /// The ids of the tabs in order.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var ids: [ID] { tabs.map(\.id) }

    /// Tabs with `tabs`, the one of `selection` selected.
    ///
    /// Ownership: keeps the tabs and takes their contents into the chain of commands.
    /// Isolation: MainActor. Errors: traps when `tabs` is empty, an id repeats, `selection` is
    /// not among them, or a content is already in another place. Cancellation: not applicable.
    public init(selection: ID, _ tabs: [Tab<ID>]) {
        precondition(!tabs.isEmpty, "Tabs need a tab")
        precondition(
            Set(tabs.map(\.id)).count == tabs.count,
            "The ids of tabs must differ"
        )
        precondition(tabs.contains { $0.id == selection }, "The selection is not a tab")
        self.tabs = tabs
        selectionState = State(selection)
        super.init()
        for tab in tabs {
            precondition(
                tab.content.outer == nil && (tab.content as? Screen)?.owner == nil,
                "The content of a tab is already in another place"
            )
            tab.content.outer = self
            (tab.content as? any ShownByContainer)?.setShown(false)
        }
    }

    /// Picks the tab of `id`; `false` when there is none. The content of the tab picked before
    /// stops being shown, the new one is.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func select(_ id: ID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }

        guard selectionState.value != id else { return true }

        selectionState.value = id
        updateShown()
        return true
    }

    /// Lets go of the contents: stacks of their screens, screens of what they present.
    ///
    /// Ownership: releases what the contents keep. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation.
    package func closeContent() {
        for tab in tabs {
            (tab.content as? any ClosableContent)?.closeContent()
            tab.content.outer = nil
        }
    }

    private func updateShown() {
        for tab in tabs {
            (tab.content as? any ShownByContainer)?.setShown(isOnScreen && tab.id == selection)
        }
    }
}

extension Tabs: PresentedTabs {
    package var presentedTabs: [PresentedTab] {
        tabs.map { PresentedTab(title: $0.title, symbol: $0.symbol, content: $0.content) }
    }

    package var selectedIndex: Int {
        let id = selection
        return tabs.firstIndex { $0.id == id } ?? 0
    }

    package func pick(index: Int) {
        guard tabs.indices.contains(index) else { return }

        select(tabs[index].id)
    }

    package func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }

        isOnScreen = onScreen
        updateShown()
    }
}
