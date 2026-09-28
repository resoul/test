import Nodes
import StateCore
import Testing

@testable import AppShellModel

private enum Route: Hashable {
    case inbox
    case message(String)
}

/// A screen that writes down what it is told, and how many were made.
@MainActor
private final class Watched: NodeScreen {
    let route: Route
    let log: Log

    init(_ route: Route, log: Log) {
        self.route = route
        self.log = log
        super.init(Node())
        log.made.append(route)
    }

    override func appeared() { log.events.append("appeared \(route)") }
    override func disappeared() { log.events.append("disappeared \(route)") }
}

@MainActor
private final class Log {
    var made: [Route] = []
    var events: [String] = []
    /// Keeps the presenter, which the stack does not.
    var presenter: AnyObject?
}

/// Shows moves when the test says they end.
@MainActor
private final class Presenter: StackPresenter {
    var moves: [StackMove] = []
    /// Ends each move at once, as a move without animation does.
    var endsAtOnce = false
    weak var stack: Stack<Route>?

    func present(_ move: StackMove) {
        moves.append(move)
        if endsAtOnce {
            stack?.moveEnded(move.id, completed: true)
        }
    }
}

@MainActor
private func makeStack(_ log: Log, endsAtOnce: Bool = true) -> (Stack<Route>, Presenter) {
    let stack = Stack(root: Route.inbox) { Watched($0, log: log) }
    let presenter = Presenter()
    presenter.endsAtOnce = endsAtOnce
    presenter.stack = stack
    log.presenter = presenter
    stack.presenter = presenter
    return (stack, presenter)
}

@Test @MainActor
func equalRoutesAreEntriesOfTheirOwnAndAnEqualPathMakesNothing() {
    let log = Log()
    let (stack, _) = makeStack(log)

    stack.push(.message("A"))
    stack.push(.message("A"))
    let first = stack.screen(for: presentedIDs(stack)[1])
    #expect(stack.path == [.inbox, .message("A"), .message("A")])
    #expect(first !== stack.screen(for: presentedIDs(stack)[2]))

    // The longest equal beginning stays, with its screens.
    #expect(stack.setPath([.inbox, .message("A")]) == .accepted)
    #expect(stack.screen(for: presentedIDs(stack)[1]) === first)
    #expect(stack.setPath([.inbox, .message("A")]) == .unchanged)
    #expect(stack.setPath([.inbox, .message("B")]) == .accepted)
    #expect(log.made == [.inbox, .message("A"), .message("A"), .message("B")])
}

/// The entries the stack shows, from the last move.
@MainActor
private func presentedIDs(_ stack: Stack<Route>) -> [StackEntryID] {
    ((stack.presenter as? Presenter)?.moves.last?.to) ?? []
}

@Test @MainActor
func theRootStaysAndAnEmptyPathIsTurnedDown() {
    let log = Log()
    let (stack, _) = makeStack(log)

    #expect(stack.pop() == .rejected(.atRoot))
    #expect(stack.setPath([]) == .rejected(.emptyPath))
    #expect(stack.path == [.inbox])
    #expect(!stack.canPerform(.back))
    stack.push(.message("A"))
    #expect(stack.canPerform(.back))
    #expect(stack.perform(.back))
    #expect(stack.path == [.inbox])
}

@Test @MainActor
func aScreenAlreadyInAStackIsTurnedDown() {
    let shared = NodeScreen(Node())
    let other = Stack(root: Route.inbox) { _ in shared }
    let stack = Stack(root: Route.inbox) { route in
        route == .inbox ? NodeScreen(Node()) : shared
    }

    #expect(stack.push(.message("A")) == .rejected(.screenInUse))
    #expect(stack.path == [.inbox])
    // Let go by its stack, it can go in another.
    other.close()
    #expect(stack.push(.message("A")) == .accepted)
}

@Test @MainActor
func requestsDuringAMoveWaitAndTheStackMovesOnToTheLatest() {
    let log = Log()
    let (stack, presenter) = makeStack(log, endsAtOnce: false)
    stack.moveEnded(presenter.moves[0].id, completed: true)

    stack.push(.message("A"))
    stack.push(.message("B"))
    stack.pop()
    stack.push(.message("C"))
    // One move at a time: the first push is on its way.
    #expect(presenter.moves.count == 2)
    #expect(stack.presentedPath == [.inbox])
    #expect(stack.path == [.inbox, .message("A"), .message("C")])

    stack.moveEnded(presenter.moves[1].id, completed: true)
    #expect(stack.presentedPath == [.inbox, .message("A")])
    #expect(presenter.moves.count == 3)
    #expect(presenter.moves[2].from == presenter.moves[1].to)
    stack.moveEnded(presenter.moves[2].id, completed: true)
    #expect(stack.presentedPath == stack.path)
    // B was made, and let go without showing.
    #expect(log.made == [.inbox, .message("A"), .message("B"), .message("C")])
    #expect(
        log.events == [
            "appeared inbox", "disappeared inbox", "appeared message(\"A\")",
            "disappeared message(\"A\")", "appeared message(\"C\")",
        ]
    )
}

@Test @MainActor
func goingBackChangesBothPathsOnceAndASwipeLetGoChangesNothing() {
    let log = Log()
    let (stack, presenter) = makeStack(log)
    stack.push(.message("A"))
    log.events = []
    let moves = presenter.moves.count

    // Let go early: the same screens, nothing appeared or disappeared.
    let swipe = stack.backBegan()!
    #expect(stack.backBegan() == nil)
    stack.moveEnded(swipe.id, completed: false)
    #expect(stack.path == [.inbox, .message("A")])
    #expect(stack.presentedPath == [.inbox, .message("A")])
    #expect(log.events.isEmpty)

    let back = stack.backBegan()!
    stack.moveEnded(back.id, completed: true)
    #expect(stack.path == [.inbox])
    #expect(stack.presentedPath == [.inbox])
    // The platform made the move itself: the stack asks for none.
    #expect(presenter.moves.count == moves)
    #expect(log.events == ["disappeared message(\"A\")", "appeared inbox"])
    #expect(stack.backBegan() == nil)
}

@Test @MainActor
func aPathAskedForDuringASwipeFollowsWhatTheSwipeLeft() {
    let log = Log()
    let (stack, presenter) = makeStack(log)
    stack.push(.message("A"))
    presenter.endsAtOnce = false
    let moves = presenter.moves.count

    let back = stack.backBegan()!
    stack.setPath([.inbox, .message("B")])
    #expect(presenter.moves.count == moves)
    stack.moveEnded(back.id, completed: true)

    // What shows is what the swipe left; then the stack moves to the path asked for.
    #expect(stack.presentedPath == [.inbox])
    #expect(stack.path == [.inbox, .message("B")])
    #expect(presenter.moves.last?.from == back.to)
    stack.moveEnded(presenter.moves.last!.id, completed: true)
    #expect(stack.presentedPath == [.inbox, .message("B")])
}

@Test @MainActor
func aLateOrUnknownEndChangesNothingAndAFailedMoveReturnsThePath() {
    let log = Log()
    let (stack, presenter) = makeStack(log)
    presenter.endsAtOnce = false

    stack.push(.message("A"))
    let push = presenter.moves.last!
    stack.moveEnded(push.id &+ 100, completed: true)
    #expect(stack.presentedPath == [.inbox])

    // The platform could not show it, and nothing was asked since: the path returns.
    stack.moveEnded(push.id, completed: false)
    #expect(stack.path == [.inbox])
    stack.moveEnded(push.id, completed: true)
    #expect(stack.presentedPath == [.inbox])
    #expect(presenter.moves.count == 2)
}

@Test @MainActor
func theTopScreenSendsBackOnToTheStackAndAtTheRootBeyondIt() {
    let log = Log()
    let (stack, _) = makeStack(log)
    let window = CommandResponder()
    var closes = 0
    window.handle(.back) { closes += 1 }
    stack.outer = window
    stack.push(.message("A"))
    let top = stack.screen(for: presentedIDs(stack).last!)!

    #expect(top.perform(.back))
    #expect(stack.path == [.inbox])
    let root = stack.screen(for: presentedIDs(stack).last!)!
    #expect(root.perform(.back))
    #expect(closes == 1)
    // Let go by the stack, the screen is out of its chain.
    #expect(top.outer == nil)
}

@Test @MainActor
func thePathIsObservedAndAClosedStackTakesNoRequests() {
    let log = Log()
    let (stack, presenter) = makeStack(log, endsAtOnce: false)
    var seen = 0
    let observer = Observer { seen += 1 }
    _ = observer.track { stack.path }

    stack.push(.message("A"))
    StateUpdates.flush()
    #expect(seen == 1)

    stack.close()
    #expect(stack.push(.message("B")) == .rejected(.closed))
    stack.moveEnded(presenter.moves.last!.id, completed: true)
    #expect(stack.presentedPath == [])
    observer.cancel()
}
