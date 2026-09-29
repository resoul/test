import Nodes
import StateCore
import Testing

@testable import AppShell

private enum Route: Hashable {
    case root
    case detail
}

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
    var presenter: AnyObject?
}

@MainActor
private final class Presenter: StackPresenter {
    weak var stack: Stack<Route>?
    func present(_ move: StackMove) { stack?.moveEnded(move.id, completed: true) }
}

@MainActor
private func makeSplit(_ log: Log) -> (Split, Watched, Stack<Route>) {
    let sidebar = Watched("sidebar", log: log)
    let stack = Stack(root: Route.root) { route in
        Watched(route == .root ? "content" : "detail", log: log)
    }
    let presenter = Presenter()
    presenter.stack = stack
    log.presenter = presenter
    let split = Split(sidebar: sidebar, content: stack)
    // As an adapter does once its container shows the stack.
    stack.presenter = presenter
    return (split, sidebar, stack)
}

@Test @MainActor
func aSplitShowsTheSidebarFirstAndTheChoiceOfTheContentIsKept() {
    let (split, _, _) = makeSplit(Log())

    #expect(!split.isContentShown)
    split.showContent()
    #expect(split.isContentShown)
    split.showSidebar()
    #expect(!split.isContentShown)
}

@Test @MainActor
func withRoomForBothBothAreShownWithoutRoomOnlyTheChosenOne() {
    let log = Log()
    let (split, _, _) = makeSplit(log)

    split.setOnScreen(true)
    // Room for both, as on a Mac or an iPad: both appear.
    #expect(Set(log.events) == ["appeared sidebar", "appeared content"])
    log.events = []

    // Room shrinks to one: the sidebar shows, the content goes.
    split.setCollapsed(true)
    #expect(log.events == ["disappeared content"])
    split.showContent()
    #expect(log.events.suffix(2) == ["disappeared sidebar", "appeared content"])
    log.events = []
    // Room grows again: both show, the choice stays for the next shrinking.
    split.setCollapsed(false)
    #expect(log.events == ["appeared sidebar"])
    #expect(split.isContentShown)
}

@Test @MainActor
func backFromTheContentGoesToTheSidebarOnlyWhileOneShows() {
    let (split, _, stack) = makeSplit(Log())
    split.setOnScreen(true)
    let root = stack.screen(for: stack.presentedEntries[0])

    // With room for both there is nothing to go back to.
    split.showContent()
    #expect(root?.canPerform(.back) == false)
    split.setCollapsed(true)
    #expect(root?.canPerform(.back) == true)
    #expect(root?.perform(.back) == true)
    #expect(!split.isContentShown)
    #expect(root?.canPerform(.back) == false)

    // Deeper in the stack, back is the stack's own.
    split.showContent()
    stack.push(.detail)
    let detail = stack.screen(for: stack.presentedEntries[1])
    #expect(detail?.perform(.back) == true)
    #expect(stack.path == [.root])
    #expect(split.isContentShown)
}

@Test @MainActor
func aSplitInTabsIsShownWhileItsTabIs() {
    let log = Log()
    let (split, _, _) = makeSplit(log)
    let other = Watched("other", log: log)
    let tabs = Tabs(
        selection: "split",
        [
            Tab("split", title: "Split", content: split),
            Tab("other", title: "Other", content: other),
        ]
    )
    tabs.setOnScreen(true)
    #expect(log.events.contains("appeared sidebar") && log.events.contains("appeared content"))
    log.events = []

    tabs.select("other")
    #expect(Set(log.events) == ["disappeared sidebar", "disappeared content", "appeared other"])
}

@Test @MainActor
func closingASplitLetsGoOfTheContentsScreens() {
    let (split, sidebar, stack) = makeSplit(Log())
    let entry = stack.presentedEntries[0]

    split.closeContent()

    #expect(stack.screen(for: entry) == nil)
    #expect(sidebar.outer == nil)
}
