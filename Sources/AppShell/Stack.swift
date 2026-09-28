import Nodes
import StateCore

/// One entry of a stack: an instance of a screen. Two equal routes in a path are two
/// entries, with a screen each.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct StackEntryID: Hashable, Sendable {
    let value: UInt64
}

/// What became of a request to a stack.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum NavigationResult: Hashable, Sendable {
    /// The path is the one asked for; its screens show when the move to them ends.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case accepted
    /// The path already was the one asked for: nothing changes, no screen is made.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case unchanged
    /// The path stays as it was.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case rejected(NavigationRejection)
}

/// Why a stack did not take a request.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum NavigationRejection: Hashable, Sendable {
    /// `pop()` on the root: the root stays.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case atRoot
    /// A path with no routes: a stack always shows its root.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case emptyPath
    /// The screen made for a route is already in a stack.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case screenInUse
    /// The stack was closed with its window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case closed
}

/// For platform adapters: a move of a stack's screens from `from` to `to`, as the adapter is
/// to show it and report its end (`Stack.moveEnded`).
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct StackMove: Hashable, Sendable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: UInt64
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let from: [StackEntryID]
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let to: [StackEntryID]
}

/// For platform adapters: what shows a stack — a navigation controller, or the Mac's own
/// stack. It shows one move at a time and reports its end to the stack.
///
/// Ownership: the stack does not keep it. Isolation: MainActor. Errors: none. Cancellation:
/// not applicable.
@MainActor
public protocol StackPresenter: AnyObject {
    /// Shows `move`: the entries of `move.to`, whose screens `Stack.screen(for:)` gives, in
    /// place of those of `move.from`. When the move ends — at once, or after its animation —
    /// the presenter calls `moveEnded(move.id, completed:)`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: a move the platform cannot make ends
    /// with `completed: false`. Cancellation: not applicable.
    func present(_ move: StackMove)
}

/// A navigation stack of screens, one for each route of its path, the last one shown:
///
///     let stack = Stack(root: MailRoute.inbox) { route in
///         switch route {
///         case .inbox: NodeScreen(InboxNode(store: store), title: "Inbox")
///         case .message(let id): MessageScreen(id: id, store: store)
///         }
///     }
///     stack.push(.message(id))
///
/// `path` is the path asked for, `presentedPath` the one the platform last confirmed; they
/// differ while a move goes on. Requests during a move change `path` and wait: when the move
/// ends, the stack moves on to the latest path. The user going back — a swipe, the back
/// button, Menu on the remote, Command-[ — changes both once the move ends; a swipe let go
/// early changes nothing.
///
/// A screen is made once for its entry, when the entry joins the path, and let go when the
/// entry has left the path and no move needs it. It carries out `Command.back` while the
/// path has more than the root; at the root, the command goes on to `outer`.
///
/// Ownership: keeps the screens of its entries and the closure making them. Isolation:
/// MainActor. Errors: requests return `NavigationResult`. Cancellation: `close()`.
@MainActor
public final class Stack<Route: Hashable>: CommandResponder {
    private struct Entry {
        let id: StackEntryID
        let route: Route
        let screen: Screen
    }

    /// A move the presenter is showing: where it goes, and at which revision it began.
    private struct Move {
        let move: StackMove
        let revision: UInt64
        let target: [Entry]
        /// Begun by the user going back, not by a request.
        let isBack: Bool
    }

    private let makeScreen: @MainActor (Route) -> Screen
    private var desired: [Entry] = []
    private var confirmed: [Entry] = []
    private var moving: Move?
    private let pathState: State<[Route]>
    private let presentedState = State<[Route]>([])
    private var nextEntry: UInt64 = 0
    private var nextMove: UInt64 = 0
    private var isClosed = false

    /// Counts the changes of `path`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var revision: UInt64 = 0

    /// What shows the stack; until there is one, nothing shows and no move ends.
    ///
    /// Ownership: not kept. Isolation: MainActor. Errors: none. Cancellation: set to `nil`.
    public weak var presenter: (any StackPresenter)? {
        didSet { reconcile() }
    }

    /// A stack showing `root`, whose screens `screen` makes: once for each entry, at once,
    /// without loading anything — a screen that needs data shows it loading and loads it.
    ///
    /// Ownership: keeps `screen`, which must not keep the stack. Isolation: MainActor.
    /// Errors: traps when the root's screen is already in a stack. Cancellation: `close()`.
    public init(root: Route, screen: @escaping @MainActor (Route) -> Screen) {
        makeScreen = screen
        pathState = State([root])
        super.init()
        guard let entry = makeEntry(root) else {
            preconditionFailure("The root's screen is already in a stack")
        }

        desired = [entry]
        handle(.back, isEnabled: { [weak self] in (self?.desired.count ?? 0) > 1 }) {
            [weak self] in
            self?.pop()
        }
    }

    /// The path asked for, the root first. Reading it under tracking depends on it.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var path: [Route] { pathState.value }

    /// The path the platform last confirmed showing; empty until a presenter showed the
    /// stack. Reading it under tracking depends on it.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var presentedPath: [Route] { presentedState.value }

    /// Adds a screen for `route` on top — a new one, even when the top already shows an
    /// equal route.
    ///
    /// Ownership: the stack keeps the new screen. Isolation: MainActor. Errors: see
    /// `NavigationRejection`. Cancellation: not applicable.
    @discardableResult
    public func push(_ route: Route) -> NavigationResult {
        guard !isClosed else { return .rejected(.closed) }
        guard let entry = makeEntry(route) else { return .rejected(.screenInUse) }

        return request(desired + [entry])
    }

    /// Takes the top screen off.
    ///
    /// Ownership: the screen is let go once no move needs it. Isolation: MainActor. Errors:
    /// `.atRoot` on the root. Cancellation: not applicable.
    @discardableResult
    public func pop() -> NavigationResult {
        guard !isClosed else { return .rejected(.closed) }
        guard desired.count > 1 else { return .rejected(.atRoot) }

        return request(Array(desired.dropLast()))
    }

    /// Puts a new screen for `route` in place of the top one, even for an equal route.
    ///
    /// Ownership: the stack keeps the new screen. Isolation: MainActor. Errors: see
    /// `NavigationRejection`. Cancellation: not applicable.
    @discardableResult
    public func replaceTop(with route: Route) -> NavigationResult {
        guard !isClosed else { return .rejected(.closed) }
        guard let entry = makeEntry(route) else { return .rejected(.screenInUse) }

        return request(desired.dropLast() + [entry])
    }

    /// Makes `routes` the path — a deep link, a restored state. The entries of the longest
    /// equal beginning of both paths stay, with their screens; the rest is made anew. An
    /// equal path changes nothing.
    ///
    /// Ownership: the stack keeps the new screens. Isolation: MainActor. Errors: see
    /// `NavigationRejection`; the path then stays as it was. Cancellation: not applicable.
    @discardableResult
    public func setPath(_ routes: [Route]) -> NavigationResult {
        guard !isClosed else { return .rejected(.closed) }
        guard !routes.isEmpty else { return .rejected(.emptyPath) }

        var kept = 0
        while kept < min(routes.count, desired.count), desired[kept].route == routes[kept] {
            kept += 1
        }
        if kept == routes.count, kept == desired.count { return .unchanged }

        var made: [Entry] = []
        for route in routes.dropFirst(kept) {
            guard let entry = makeEntry(route) else {
                release(made)
                return .rejected(.screenInUse)
            }

            made.append(entry)
        }
        return request(Array(desired.prefix(kept)) + made)
    }

    /// Lets go of every screen; the stack takes no more requests, and a move still going on
    /// ends unheard.
    ///
    /// Ownership: releases the screens. Isolation: MainActor. Errors: none. Cancellation:
    /// this is the cancellation.
    public func close() {
        guard !isClosed else { return }

        isClosed = true
        if let top = confirmed.last, top.screen.isPresented {
            top.screen.isPresented = false
            top.screen.disappeared()
        }
        let all = desired + confirmed + (moving?.target ?? [])
        desired = []
        confirmed = []
        moving = nil
        release(all)
    }

    // MARK: - For platform adapters

    /// The platform's container showing the stack, while there is one: a stack is shown in
    /// one place, and asking the adapter again gives the same container.
    package weak var platformContainer: AnyObject?

    /// Whether the user can begin going back now: the stack shows more than its root and no
    /// move goes on. The adapter keeps the platform's swipe back from beginning otherwise.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var canBeginBack: Bool {
        !isClosed && moving == nil && confirmed.count > 1
    }

    /// The entries the platform last confirmed showing, the root first.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var presentedEntries: [StackEntryID] {
        confirmed.map(\.id)
    }

    /// The screen of `entry`, while the stack has it.
    ///
    /// Ownership: returns a screen the stack keeps. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func screen(for entry: StackEntryID) -> Screen? {
        (desired + confirmed + (moving?.target ?? [])).first { $0.id == entry }?.screen
    }

    /// The user began going back — a swipe from the edge, the back button, Menu on the
    /// remote — which the platform animates by itself, to the first `keeping` screens (the
    /// back button's menu jumps several); `nil` goes back one. Returns the move to report the
    /// end of, or `nil` when the stack cannot go back there now: at the root, during another
    /// move, or to nowhere shown; the adapter then keeps the platform from beginning it.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: the move ends
    /// with `completed: false` when the user lets go early.
    public func backBegan(keeping: Int? = nil) -> StackMove? {
        let count = keeping ?? confirmed.count - 1
        guard canBeginBack, count >= 1, count < confirmed.count else { return nil }

        let target = Array(confirmed.prefix(count))
        let move = makeMove(to: target)
        moving = Move(move: move, revision: revision, target: target, isBack: true)
        return move
    }

    /// The move `id` ended: `completed` when its screens show, `false` when the user let go
    /// of a swipe back early or the platform could not make it. The report of a move other
    /// than the one going on — a late one — changes nothing.
    ///
    /// A move ending with no request since: going back, the path loses its top as the
    /// screens did; a request the platform could not show, the path returns to what shows.
    /// Requests since it began: the stack moves on to the latest path.
    ///
    /// Ownership: lets go of screens no path needs any more. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    public func moveEnded(_ id: UInt64, completed: Bool) {
        guard let current = moving, current.move.id == id else { return }

        moving = nil
        let before = desired + confirmed + current.target
        if completed {
            confirm(current.target)
        }
        if current.revision == revision, current.isBack == completed {
            setDesired(confirmed)
        }
        release(before)
        reconcile()
    }

    // MARK: - Private

    private func makeEntry(_ route: Route) -> Entry? {
        let screen = makeScreen(route)
        guard screen.owner == nil else { return nil }

        screen.owner = self
        screen.outer = self
        nextEntry &+= 1
        return Entry(id: StackEntryID(value: nextEntry), route: route, screen: screen)
    }

    private func request(_ entries: [Entry]) -> NavigationResult {
        let before = desired
        setDesired(entries)
        release(before)
        reconcile()
        return .accepted
    }

    private func setDesired(_ entries: [Entry]) {
        desired = entries
        revision &+= 1
        pathState.value = entries.map(\.route)
    }

    /// Starts a move to the path asked for, when the presenter is free and shows another.
    private func reconcile() {
        guard !isClosed, moving == nil, let presenter,
            desired.map(\.id) != confirmed.map(\.id)
        else { return }

        let move = makeMove(to: desired)
        moving = Move(move: move, revision: revision, target: desired, isBack: false)
        presenter.present(move)
    }

    private func makeMove(to target: [Entry]) -> StackMove {
        nextMove &+= 1
        return StackMove(id: nextMove, from: confirmed.map(\.id), to: target.map(\.id))
    }

    /// The platform shows `entries` now: the top screen changed is told.
    private func confirm(_ entries: [Entry]) {
        let top = confirmed.last
        confirmed = entries
        presentedState.value = entries.map(\.route)
        guard top?.id != entries.last?.id else { return }

        if let top, top.screen.isPresented {
            top.screen.isPresented = false
            top.screen.disappeared()
        }
        if let shown = entries.last {
            shown.screen.isPresented = true
            shown.screen.appeared()
        }
    }

    /// Lets go of the screens of `entries` no path or move has any more.
    private func release(_ entries: [Entry]) {
        let live = Set((desired + confirmed + (moving?.target ?? [])).map(\.id))
        for entry in entries where !live.contains(entry.id) && entry.screen.owner === self {
            entry.screen.owner = nil
            entry.screen.outer = nil
        }
    }
}

/// A stack as its adapters see it, whatever its routes: they show its entries' screens and
/// report the moves.
@MainActor
package protocol PresentedStack: CommandResponder {
    var presenter: (any StackPresenter)? { get set }
    var platformContainer: AnyObject? { get set }
    var presentedEntries: [StackEntryID] { get }
    var canBeginBack: Bool { get }
    func screen(for entry: StackEntryID) -> Screen?
    func backBegan(keeping: Int?) -> StackMove?
    func moveEnded(_ id: UInt64, completed: Bool)
    func close()
}

extension Stack: PresentedStack {}
