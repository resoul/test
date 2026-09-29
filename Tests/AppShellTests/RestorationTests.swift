import Foundation
import Nodes
import StateCore
import Testing

@testable import AppShell

private enum Route: Hashable, Sendable {
    case inbox
    case message(Int)
    case account
    case other
}

private enum Section: Hashable {
    case inbox
    case search
}

private let routes = RouteTable<Route> {
    RoutePattern("/inbox", .inbox)
    RoutePattern(
        "/inbox/:id",
        route: { .message(try $0.value("id")) },
        values: { route in
            guard case .message(let id) = route else { return nil }
            return ["id": String(id)]
        }
    )
    RoutePattern("/inbox/account", .account)
    RoutePattern("/other", .other)
}

/// Ends every move of a stack at once, as a stack without animation does.
@MainActor
private final class Presenter: StackPresenter {
    weak var stack: Stack<Route>?
    func present(_ move: StackMove) { stack?.moveEnded(move.id, completed: true) }
}

@MainActor
private final class Keep {
    var presenters: [Presenter] = []
}

@MainActor
private let keep = Keep()

@MainActor
private func makeStack(
    restorable: Bool = true,
    allowing: @escaping @MainActor (Route) -> Bool = { _ in true }
) -> Stack<Route> {
    let stack = Stack(root: Route.inbox) { _ in NodeScreen(Node()) }
    let presenter = Presenter()
    presenter.stack = stack
    keep.presenters.append(presenter)
    stack.presenter = presenter
    if restorable {
        stack.restorable(using: routes, allowing: allowing)
    }
    return stack
}

@MainActor
private func session(_ content: any SceneContent) -> SceneSession {
    SceneSession(kind: WindowScene("main") { NodeScreen(Node()) }, content: content)
}

/// What a scene's snapshot says, as the platform would keep it.
@MainActor
private func snapshot(of session: SceneSession) throws -> RestorationSnapshot {
    let data = try #require(session.restorationData())
    return try JSONDecoder().decode(RestorationSnapshot.self, from: data)
}

@Test @MainActor
func aStackKeepsTheUrlOfItsPathAndPutsItBackInAFreshOne() throws {
    let stack = makeStack()
    stack.push(.message(7))
    let data = try #require(session(stack).restorationData())
    #expect(try snapshot(of: session(stack)).container == .stack(url: "/inbox/7"))

    let fresh = makeStack()
    let result = session(fresh).restore(from: data)
    #expect(result.isRestored)
    #expect(result.issues.isEmpty)
    // At once, as one path, not as the pushes that made it.
    #expect(fresh.path == [.inbox, .message(7)])
}

@Test @MainActor
func aStackThatDidNotOptInKeepsNothing() {
    let stack = makeStack(restorable: false)
    stack.push(.message(7))

    #expect(session(stack).restorationData() == nil)
}

@Test @MainActor
func aUrlThatDoesNotReadWholeIsCutBackToTheLongestBeginningThatDoes() throws {
    let data = try JSONEncoder().encode(
        RestorationSnapshot(container: .stack(url: "/inbox/7/missing/deeper"))
    )
    let stack = makeStack()

    let result = session(stack).restore(from: data)

    #expect(result.isRestored)
    #expect(result.issues == [.pathTrimmed("/inbox/7/missing/deeper")])
    #expect(stack.path == [.inbox, .message(7)])
}

@Test @MainActor
func aUrlNoBeginningOfWhichReadsLeavesTheStackWhereItIs() throws {
    let data = try JSONEncoder().encode(
        RestorationSnapshot(container: .stack(url: "/nowhere/at/all"))
    )
    let stack = makeStack()

    let result = session(stack).restore(from: data)

    #expect(!result.isRestored)
    #expect(result.issues == [.unknownPath("/nowhere/at/all")])
    #expect(stack.path == [.inbox])
}

@Test @MainActor
func aPathThatDoesNotBeginAtTheStacksRootIsNotItsOwn() throws {
    let data = try JSONEncoder().encode(RestorationSnapshot(container: .stack(url: "/other")))
    let stack = makeStack()

    let result = session(stack).restore(from: data)

    #expect(!result.isRestored)
    #expect(result.issues == [.rootMismatch("/other")])
    #expect(stack.path == [.inbox])
}

@Test @MainActor
func aRouteTheAppKeepsToItselfIsWhereTheSavedPathStops() throws {
    let stack = makeStack { $0 != .account }
    stack.setPath([.inbox, .message(3), .account])

    #expect(try snapshot(of: session(stack)).container == .stack(url: "/inbox/3"))

    // The same limit when a snapshot made by another launch comes back.
    let data = try JSONEncoder().encode(
        RestorationSnapshot(container: .stack(url: "/inbox/account"))
    )
    let fresh = makeStack { $0 != .account }
    let result = session(fresh).restore(from: data)
    #expect(result.issues == [.routeNotAllowed("/inbox/account")])
    #expect(fresh.path == [.inbox])
}

@Test @MainActor
func anUnknownVersionAndDataThatDoNotReadLeaveEverythingAtItsRoot() throws {
    let stack = makeStack()
    let scene = session(stack)
    let future = try JSONEncoder().encode(
        RestorationSnapshot(version: 99, container: .stack(url: "/inbox/7"))
    )

    #expect(scene.restore(from: future).issues == [.unknownVersion(99)])
    #expect(scene.restore(from: Data("not json".utf8)).issues == [.unreadableData])
    #expect(!scene.restore(from: future).isRestored)
    #expect(stack.path == [.inbox])
}

@Test @MainActor
func aStackAskedToShowSomethingBeforeTheSnapshotCameIsLeftAlone() throws {
    let data = try JSONEncoder().encode(
        RestorationSnapshot(container: .stack(url: "/inbox/7"))
    )
    let stack = makeStack()
    // A link that came first.
    stack.setPath([.inbox, .message(99)])

    let result = session(stack).restore(from: data)

    #expect(!result.isRestored)
    #expect(result.issues == [.alreadyNavigated])
    #expect(stack.path == [.inbox, .message(99)])
}

@MainActor
private func makeTabs() -> (Tabs<Section>, Stack<Route>) {
    let stack = makeStack()
    let tabs = Tabs<Section>(
        selection: .inbox,
        [
            Tab(.inbox, title: "Inbox", content: stack),
            Tab(.search, title: "Search", content: NodeScreen(Node())),
        ]
    )
    return (tabs, stack)
}

@Test @MainActor
func tabsKeepTheSelectionAndWhatEachTabKept() throws {
    let (tabs, stack) = makeTabs()
    stack.push(.message(4))
    tabs.select(.search)
    let data = try #require(session(tabs).restorationData())
    #expect(
        try snapshot(of: session(tabs)).container
            == .tabs(selection: "search", tabs: ["inbox": .stack(url: "/inbox/4")])
    )

    let (fresh, freshStack) = makeTabs()
    let result = session(fresh).restore(from: data)

    #expect(result.isRestored)
    #expect(result.issues.isEmpty)
    #expect(fresh.selection == .search)
    #expect(freshStack.path == [.inbox, .message(4)])
}

@Test @MainActor
func aTabTheSnapshotHasAndTheTabsDoNotIsNamedAndTheSelectionStays() throws {
    let data = try JSONEncoder().encode(
        RestorationSnapshot(
            container: .tabs(selection: "gone", tabs: ["gone": .stack(url: "/inbox/1")])
        )
    )
    let (tabs, stack) = makeTabs()

    let result = session(tabs).restore(from: data)

    #expect(result.issues.contains(.unknownTab("gone")))
    #expect(tabs.selection == .inbox)
    #expect(stack.path == [.inbox])
}

@Test @MainActor
func tabsPickedBeforeTheSnapshotCameKeepThePickButTheirStacksAreStillPutBack() throws {
    let (source, sourceStack) = makeTabs()
    sourceStack.push(.message(2))
    source.select(.search)
    let data = try #require(session(source).restorationData())

    let (tabs, stack) = makeTabs()
    tabs.select(.inbox)
    tabs.select(.search)
    tabs.select(.inbox)
    let result = session(tabs).restore(from: data)

    #expect(result.issues == [.alreadyNavigated])
    #expect(tabs.selection == .inbox)
    #expect(stack.path == [.inbox, .message(2)])
}

@Test @MainActor
func aSplitKeepsWhichColumnShowsAndItsContentsPath() throws {
    let content = makeStack()
    let split = Split(sidebar: NodeScreen(Node()), content: content)
    content.push(.message(5))
    split.showContent()
    let data = try #require(session(split).restorationData())

    let freshContent = makeStack()
    let fresh = Split(sidebar: NodeScreen(Node()), content: freshContent)
    let result = session(fresh).restore(from: data)

    #expect(result.isRestored)
    #expect(fresh.isContentShown)
    #expect(freshContent.path == [.inbox, .message(5)])
}

@Test @MainActor
func aSnapshotOfAnotherKindOfContainerIsAShapeMismatch() throws {
    let stack = makeStack()
    let data = try JSONEncoder().encode(
        RestorationSnapshot(container: .tabs(selection: "a", tabs: [:]))
    )

    let result = session(stack).restore(from: data)

    #expect(!result.isRestored)
    #expect(result.issues == [.shapeMismatch])
    #expect(stack.path == [.inbox])
}
