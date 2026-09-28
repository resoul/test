import Nodes
import StateCore
import Testing

@testable import AppShell

private enum Route: Hashable {
    case inbox
    case message
}

extension Command {
    fileprivate static let send = Command("send", title: "Send")
}

/// A screen that writes down when it shows.
@MainActor
private final class Watched: NodeScreen {
    let name: String
    let log: Log

    init(_ name: String, log: Log) {
        self.name = name
        self.log = log
        super.init(Node())
    }

    override func appeared() { log.events.append("appeared \(name)") }
    override func disappeared() { log.events.append("disappeared \(name)") }
}

@MainActor
private final class Log {
    var events: [String] = []
}

/// Shows and hides presentations when the test says they end.
@MainActor
private final class Presenter: PresentationPresenter {
    var shown: [Presentation] = []
    var hidden: [Presentation] = []
    var endsAtOnce = true

    func show(_ presentation: Presentation) {
        shown.append(presentation)
        if endsAtOnce { presentation.showEnded(completed: true) }
    }

    func hide(_ presentation: Presentation) {
        hidden.append(presentation)
        if endsAtOnce { presentation.hideEnded() }
    }
}

@Test @MainActor
func aPresentationWaitsForItsScreenToShowAndLetsGoOfItsContentWhenGone() {
    let log = Log()
    let screen = Watched("inbox", log: log)
    let compose = Watched("compose", log: log)
    let presentation = Presentation(compose)
    var dismissed = 0
    presentation.onDismissed = { dismissed += 1 }

    #expect(screen.present(presentation) == .accepted)
    #expect(screen.presentation === presentation)
    #expect(!presentation.isShown)
    let presenter = Presenter()
    screen.presentationPresenter = presenter
    #expect(presenter.shown.count == 1)
    #expect(presentation.isShown)
    #expect(compose.isPresented)

    presentation.dismiss()
    #expect(presenter.hidden.count == 1)
    #expect(!presentation.isShown)
    #expect(screen.presentation == nil)
    #expect(compose.outer == nil)
    #expect(log.events == ["appeared compose", "disappeared compose"])
    #expect(dismissed == 1)
    // A presentation is shown once.
    #expect(screen.present(presentation) == .rejected(.screenInUse))
}

@Test @MainActor
func aScreenPresentsOneAtATimeAndContentInOnePlace() {
    let log = Log()
    let screen = Watched("inbox", log: log)
    let other = Watched("other", log: log)
    let compose = Watched("compose", log: log)

    #expect(screen.present(Presentation(compose)) == .accepted)
    let second = Presentation(Watched("second", log: log))
    #expect(screen.present(second) == .rejected(.alreadyPresenting))
    #expect(other.present(Presentation(compose)) == .rejected(.screenInUse))
    #expect(screen.present(Presentation(screen)) == .rejected(.alreadyPresenting))
    #expect(other.present(Presentation(other)) == .rejected(.screenInUse))
    // Dismissed before it showed, it never shows.
    screen.presentation?.dismiss()
    #expect(screen.presentation == nil)
    #expect(log.events.isEmpty)
}

@Test @MainActor
func theContentsCommandsGoToThePresentationAndTheWindowNotTheScreenUnder() throws {
    let shell = Shell(application: EmptyApp())
    let session = try #require(shell.makeSession())
    let stack = try #require(session.content as? Stack<Route>)
    stack.presenter = AtOnce(stack)
    let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))
    var sent = 0
    inbox.handle(.send) { sent += 1 }
    stack.push(.message)
    let message = try #require(stack.screen(for: stack.presentedEntries[1]))
    let presenter = Presenter()
    message.presentationPresenter = presenter

    let compose = NodeScreen(Node(), title: "New Message")
    let presentation = Presentation(compose)
    message.present(presentation)
    #expect(compose.outer === presentation)
    #expect(presentation.outer === session)
    // Neither the stack's going back nor the screen's commands under it.
    #expect(!compose.canPerform(.send))
    #expect(compose.canPerform(.closeWindow) == session.canPerform(.closeWindow))
    #expect(compose.perform(.back))
    #expect(stack.path == [.inbox, .message])
    #expect(presenter.hidden.count == 1)
    #expect(sent == 0)
}

@Test @MainActor
func aPresentationTheUserCannotCloseAsksInsteadAndClosesByCode() {
    let log = Log()
    let screen = Watched("inbox", log: log)
    let presenter = Presenter()
    screen.presentationPresenter = presenter
    let presentation = Presentation(Watched("draft", log: log))
    var attempts = 0
    presentation.onDismissAttempt = { attempts += 1 }
    presentation.isDismissible = false
    screen.present(presentation)

    #expect(!presentation.canBeginUserDismiss)
    #expect(presentation.content.perform(.cancel))
    presentation.userDismissAttempted()
    #expect(attempts == 2)
    #expect(presentation.isShown)

    presentation.isDismissible = true
    #expect(presentation.canBeginUserDismiss)
    presentation.dismiss()
    #expect(!presentation.isShown)
}

@Test @MainActor
func onlyASwipeDownAllTheWayClosesAPresentation() {
    let log = Log()
    let screen = Watched("inbox", log: log)
    let presenter = Presenter()
    screen.presentationPresenter = presenter
    let presentation = Presentation(Watched("sheet", log: log))
    screen.present(presentation)

    // A swipe let go early is not reported: nothing changes.
    #expect(presentation.canBeginUserDismiss)
    #expect(presentation.isShown)
    presentation.userDismissed()
    #expect(!presentation.isShown)
    #expect(presenter.hidden.isEmpty)
    #expect(screen.presentation == nil)
    #expect(log.events == ["appeared sheet", "disappeared sheet"])
}

@Test @MainActor
func aDismissDuringTheShowHidesOnceItShows() {
    let log = Log()
    let screen = Watched("inbox", log: log)
    let presenter = Presenter()
    presenter.endsAtOnce = false
    screen.presentationPresenter = presenter
    let presentation = Presentation(Watched("sheet", log: log))
    screen.present(presentation)

    presentation.dismiss()
    #expect(presenter.hidden.isEmpty)
    presentation.showEnded(completed: true)
    #expect(presenter.hidden.count == 1)
    // A late report changes nothing.
    presentation.showEnded(completed: true)
    presentation.hideEnded()
    #expect(!presentation.isShown)
    #expect(log.events == ["appeared sheet", "disappeared sheet"])
}

@Test @MainActor
func aScreenLeavingItsStackDismissesWhatItPresentsAndAStackPresentedIsClosed() throws {
    let log = Log()
    let stack = Stack(root: Route.inbox) { Watched("\($0)", log: log) }
    let atOnce = AtOnce(stack)
    stack.presenter = atOnce
    stack.push(.message)
    let message = try #require(stack.screen(for: stack.presentedEntries[1]))
    let presenter = Presenter()
    message.presentationPresenter = presenter
    let inner = Stack(root: Route.inbox) { _ in NodeScreen(Node()) }
    let presentation = Presentation(inner, style: .fullScreen)
    message.present(presentation)
    #expect(presentation.isShown)

    stack.pop()
    #expect(!presentation.isShown)
    #expect(inner.push(.message) == .rejected(.closed))
}

@MainActor
private struct EmptyApp: Application {
    init() {}

    var scenes: [WindowScene] {
        WindowScene("main") {
            Stack(root: Route.inbox) { _ in NodeScreen(Node()) }
        }
    }
}

/// Ends each move of a stack at once.
@MainActor
private final class AtOnce: StackPresenter {
    weak var stack: (any PresentedStack)?
    /// Kept by the test's objects: the stack does not keep its presenter.
    private static var kept: [AtOnce] = []

    init(_ stack: any PresentedStack) {
        self.stack = stack
        AtOnce.kept.append(self)
    }

    func present(_ move: StackMove) {
        stack?.moveEnded(move.id, completed: true)
    }
}

@Test @MainActor
func aSheetStopsAtItsHeightsOpeningAtTheFirst() {
    #expect(PresentationStyle.sheet(heights: []).heights == [.large])
    let twice = PresentationStyle.sheet(heights: [.medium, .large, .medium])
    #expect(twice.heights == [.medium, .large])
    #expect(PresentationStyle.sheet == .sheet(heights: [.large]))
    #expect(PresentationStyle.fullScreen.heights.isEmpty)
    let usable = PresentationStyle.sheet(heights: [.medium], usableBelow: .medium)
    #expect(usable.usableBelow == .medium)
    // Only one of its heights.
    #expect(PresentationStyle.sheet(heights: [.medium], usableBelow: .large).usableBelow == nil)
    #expect(PresentationStyle.sheet.usableBelow == nil)

    let log = Log()
    let presentation = Presentation(
        Watched("share", log: log),
        style: .sheet(heights: [.medium, .points(300), .large])
    )
    #expect(presentation.height == .medium)
    presentation.height = .large
    #expect(presentation.height == .large)
    // Only its own heights.
    presentation.height = .fraction(0.3)
    #expect(presentation.height == .large)
    presentation.userMoved(to: .points(300))
    #expect(presentation.height == .points(300))

    let whole = Presentation(Watched("player", log: log), style: .fullScreen)
    #expect(whole.height == .large)
    whole.height = .medium
    #expect(whole.height == .large)
}
