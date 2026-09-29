import Nodes
import StateCore
import Testing

@testable import AppShell

private enum Section: Hashable {
    case inbox
    case search
    case settings
}

private enum Route: Hashable {
    case root
    case detail
}

/// A screen that writes down what it is told.
@MainActor
private final class Watched: NodeScreen {
    let name: String
    let log: Log

    init(_ name: String, log: Log) {
        self.name = name
        self.log = log
        super.init(Node(), title: name)
    }

    override func appeared() { log.events.append("appeared \(name)") }
    override func disappeared() { log.events.append("disappeared \(name)") }
}

@MainActor
private final class Log {
    var events: [String] = []
    var presenters: [AnyObject] = []
}

/// Ends every move of a stack at once.
@MainActor
private final class Presenter: StackPresenter {
    weak var stack: Stack<Route>?
    func present(_ move: StackMove) { stack?.moveEnded(move.id, completed: true) }
}

extension Command {
    fileprivate static let flag = Command("flag", title: "Flag")
}

@MainActor
private func makeStack(_ name: String, log: Log) -> Stack<Route> {
    let stack = Stack(root: Route.root) { route in
        Watched(route == .root ? name : "\(name) detail", log: log)
    }
    let presenter = Presenter()
    presenter.stack = stack
    log.presenters.append(presenter)
    return stack
}

/// What an adapter does once its container shows the stack: gives it its presenter.
@MainActor
private func attach(_ stack: Stack<Route>, _ log: Log) {
    stack.presenter = log.presenters.first { ($0 as? Presenter)?.stack === stack }
        .flatMap { $0 as? Presenter }
}

@MainActor
private func makeTabs(_ log: Log) -> (Tabs<Section>, Stack<Route>, Stack<Route>, Watched) {
    let inbox = makeStack("inbox", log: log)
    let search = makeStack("search", log: log)
    let settings = Watched("settings", log: log)
    let tabs = Tabs<Section>(
        selection: .inbox,
        [
            Tab(.inbox, title: "Inbox", symbol: "tray", content: inbox),
            Tab(.search, title: "Search", symbol: "magnifyingglass", content: search),
            Tab(.settings, title: "Settings", content: settings),
        ]
    )
    attach(inbox, log)
    attach(search, log)
    return (tabs, inbox, search, settings)
}

@Test @MainActor
func tabsStartOnTheSelectionAndPickingByIdGivesFalseForNoSuchTab() {
    let (tabs, _, _, _) = makeTabs(Log())

    #expect(tabs.selection == .inbox)
    #expect(tabs.ids == [.inbox, .search, .settings])
    #expect(tabs.select(.search))
    #expect(tabs.selection == .search)
    #expect(tabs.select(.search))
    let other = Tabs(selection: 1, [Tab(1, title: "One", content: Watched("one", log: Log()))])
    #expect(!other.select(2))
    #expect(other.selection == 1)
}

@Test @MainActor
func nothingIsShownUntilTheContainerIsOnScreenAndThenOnlyTheSelectedTab() {
    let log = Log()
    let (tabs, _, _, _) = makeTabs(log)

    // Stacks confirmed their roots, but the tabs are not on screen: nobody appeared.
    #expect(log.events.isEmpty)
    tabs.setOnScreen(true)
    #expect(log.events == ["appeared inbox"])
    tabs.select(.search)
    #expect(log.events == ["appeared inbox", "disappeared inbox", "appeared search"])
    tabs.select(.settings)
    #expect(log.events.suffix(2) == ["disappeared search", "appeared settings"])
    tabs.setOnScreen(false)
    #expect(log.events.last == "disappeared settings")
}

@Test @MainActor
func aStackKeepsItsPathWhileAnotherTabIsPickedAndItsNewScreensWaitToShow() {
    let log = Log()
    let (tabs, inbox, _, _) = makeTabs(log)
    tabs.setOnScreen(true)
    tabs.select(.search)

    // A screen that comes while the stack is hidden is not the one shown yet.
    inbox.push(.detail)
    #expect(inbox.path == [.root, .detail])
    #expect(!log.events.contains("appeared inbox detail"))
    tabs.select(.inbox)
    #expect(log.events.contains("appeared inbox detail"))
    #expect(inbox.path == [.root, .detail])
}

@Test @MainActor
func aCommandGoesOutThroughTheTabsToTheWindowAndBackStopsAtTheRoot() {
    let log = Log()
    let (tabs, inbox, _, settings) = makeTabs(log)
    var flagged = 0
    tabs.handle(.flag) { flagged += 1 }

    // From the screen of a tab: the stack, the tabs, then out.
    let root = inbox.screen(for: inbox.presentedEntries[0])
    #expect(root?.canPerform(.flag) == true)
    #expect(settings.canPerform(.flag))
    #expect(settings.perform(.flag))
    #expect(flagged == 1)
    // Back: the stack goes back while it can, and at the root nothing else does.
    #expect(root?.canPerform(.back) == false)
    inbox.push(.detail)
    #expect(inbox.screen(for: inbox.presentedEntries[1])?.canPerform(.back) == true)
}

@Test @MainActor
func aContentTakenByOneTabsCannotBeTakenByAnother() {
    let screen = Watched("one", log: Log())
    let tabs = Tabs(selection: 1, [Tab(1, title: "One", content: screen)])

    // A second `Tabs` over the same content would trap: the check is on `outer`.
    #expect(screen.outer === tabs)
}

@Test @MainActor
func closingTheContentLetsGoOfEveryTabAndItsScreens() {
    let log = Log()
    let (tabs, inbox, search, settings) = makeTabs(log)
    tabs.setOnScreen(true)
    let entry = inbox.presentedEntries[0]

    tabs.closeContent()

    #expect(inbox.screen(for: entry) == nil)
    #expect(search.presentedEntries.isEmpty)
    #expect(settings.outer == nil)
}
