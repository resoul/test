import Foundation
import Nodes
import StateCore
import Testing

@testable import AppShell

private enum Route: Hashable {
    case inbox
    case message(Int)
}

extension Command {
    fileprivate static let newMessage = Command("newMessage", title: "New Message")
}

/// Records what the shell asks of it.
@MainActor
private final class Record {
    static let shared = Record()
    var opened: [String] = []
    var started = 0
    var stacks: [Stack<Route>] = []
    var newMessages = 0
}

@MainActor
private struct MailApp: Application {
    init() {}

    var scenes: [WindowScene] {
        WindowScene("main", title: "Mail") {
            let stack = Stack(root: Route.inbox) { _ in NodeScreen(Node()) }
            Record.shared.stacks.append(stack)
            return stack
        }
        WindowScene("compose") { NodeScreen(Node(), title: "New Message") }
    }

    func started(_ shell: Shell) {
        Record.shared.started += 1
        shell.handle(.newMessage) { Record.shared.newMessages += 1 }
    }

    func open(_ request: OpenRequest) -> OpenResult {
        Record.shared.opened.append(request.url.path)
        guard let stack = request.session?.content as? Stack<Route>,
            let id = Int(request.url.lastPathComponent)
        else { return .unsupported }

        stack.setPath([.inbox, .message(id)])
        return .opened
    }
}

@MainActor
private func reset() {
    Record.shared.opened = []
    Record.shared.started = 0
    Record.shared.stacks = []
    Record.shared.newMessages = 0
}

@Test @MainActor
func eachSessionMakesItsContentAnewInTheChainOfCommands() throws {
    reset()
    let shell = Shell(application: MailApp())
    let first = try #require(shell.makeSession())
    let second = try #require(shell.makeSession("main"))
    let compose = try #require(shell.makeSession("compose"))

    #expect(shell.makeSession("nowhere") == nil)
    #expect(shell.sessions.count == 3)
    #expect(first.content !== second.content)
    #expect(compose.content is NodeScreen)
    #expect(first.kind.title == "Mail")
    // Content, window, app.
    #expect(first.content.outer === first)
    #expect(first.outer === shell)
    shell.firstSceneShown()
    let stack = try #require(first.content as? Stack<Route>)
    #expect(stack.perform(.newMessage))
    #expect(Record.shared.newMessages == 1)
    #expect(Record.shared.started == 1)
}

@Test @MainActor
func linksWaitForTheFirstSceneInTheOrderTheyCame() throws {
    reset()
    let shell = Shell(application: MailApp())
    shell.linkQueueLimit = 2

    #expect(shell.open(URL(string: "mail:/messages/1")!) == .queued)
    #expect(shell.open(URL(string: "mail:/messages/2")!) == .queued)
    #expect(shell.open(URL(string: "mail:/messages/3")!) == .queueFull)
    let window = try #require(shell.makeSession())
    #expect(Record.shared.opened.isEmpty)

    shell.firstSceneShown()
    #expect(Record.shared.opened == ["/messages/1", "/messages/2"])
    let stack = try #require(window.content as? Stack<Route>)
    #expect(stack.path == [.inbox, .message(2)])
    // Once ready, a link goes at once — the same one again too.
    #expect(shell.open(URL(string: "mail:/messages/2")!) == .opened)
    #expect(shell.open(URL(string: "mail:/elsewhere")!) == .unsupported)
}

@Test @MainActor
func theAppIsAsActiveAsItsMostActiveScene() throws {
    reset()
    let shell = Shell(application: MailApp())
    let first = try #require(shell.makeSession())
    let second = try #require(shell.makeSession())
    #expect(shell.activation == .background)

    first.setActivation(.background)
    second.setActivation(.background)
    #expect(shell.activation == .background)
    second.setActivation(.active)
    #expect(shell.activation == .active)
}

@Test @MainActor
func aClosedSceneLetsGoOfItsContentAndOnlyAClosableSceneCloses() throws {
    reset()
    let shell = Shell(application: MailApp())
    let window = try #require(shell.makeSession())
    var closes = 0
    window.closePlatformScene = { closes += 1 }

    // On iPhone and TV a window cannot close: the command goes on.
    #expect(!window.canPerform(.closeWindow))
    window.close()
    #expect(closes == 0)
    window.canClose = true
    #expect(window.perform(.closeWindow))
    #expect(closes == 1)

    let stack = try #require(window.content as? Stack<Route>)
    shell.sessionClosed(window)
    #expect(shell.sessions.isEmpty)
    #expect(stack.push(.message(1)) == .rejected(.closed))
    #expect(stack.outer == nil)
}

@MainActor
private struct WindowedApp: Application {
    init() {}

    var scenes: [WindowScene] {
        // The settings scene comes first: it must still not be the one that opens at launch.
        WindowScene("settings", title: "Settings", role: .settings) {
            NodeScreen(Node(), title: "Settings")
        }
        WindowScene("main", title: "Notes") {
            Stack(root: Route.inbox) { _ in NodeScreen(Node()) }
        }
        WindowScene("library", allowsMultiple: false) { NodeScreen(Node(), title: "Library") }
    }
}

/// What the platform was asked for, and what it takes.
@MainActor
private final class Platform {
    var opened: [String] = []
    var takes = true

    func attach(to shell: Shell) {
        shell.platformScenes = PlatformScenes(
            canOpen: { [unowned self] _ in takes },
            open: { [unowned self] kind in opened.append(kind.id) }
        )
    }
}

@Test @MainActor
func aNewSceneOpensOnlyWhereThePlatformTakesAnotherAndTheLaunchKindIsNotTheSettings() throws {
    let shell = Shell(application: WindowedApp())
    let platform = Platform()

    // Before the adapter says what it can open, nothing does; the commands are off.
    #expect(shell.openScene() == .unsupported)
    #expect(!shell.canPerform(.newWindow))
    #expect(!shell.canPerform(.openSettings))

    platform.attach(to: shell)
    #expect(shell.openScene() == .opened)
    #expect(shell.openScene("main") == .opened)
    #expect(shell.openScene("nowhere") == .unsupported)
    #expect(platform.opened == ["main", "main"])
    #expect(try #require(shell.makeSession()).kind.id == "main")

    // An iPhone: one screen, no other scene, and the commands say so.
    platform.takes = false
    #expect(shell.openScene() == .unsupported)
    #expect(!shell.canPerform(.newWindow))
    #expect(platform.opened == ["main", "main"])
}

@Test @MainActor
func theCommandsOpenTheLaunchKindAndTheSettings() {
    let shell = Shell(application: WindowedApp())
    let platform = Platform()
    platform.attach(to: shell)

    #expect(shell.perform(.newWindow))
    #expect(shell.perform(.openSettings))
    #expect(platform.opened == ["main", "settings"])
}

@Test @MainActor
func aKindThatTakesOneAtATimeBringsItsSceneForwardAndTheSettingsAreOne() throws {
    let shell = Shell(application: WindowedApp())
    let platform = Platform()
    platform.attach(to: shell)
    #expect(!(shell.application.scenes.first { $0.id == "settings" }?.allowsMultiple ?? true))

    // None yet: it opens.
    #expect(shell.openScene("library") == .opened)
    let library = try #require(shell.makeSession("library"))
    var brought = 0
    library.activatePlatformScene = { brought += 1 }
    #expect(shell.openScene("library") == .activated)
    #expect(brought == 1)
    #expect(platform.opened == ["library"])

    let settings = try #require(shell.makeSession("settings"))
    var shown = 0
    settings.activatePlatformScene = { shown += 1 }
    #expect(shell.perform(.openSettings))
    #expect(shown == 1)
    #expect(platform.opened == ["library"])

    // Closed for good, it opens again.
    shell.sessionClosed(library)
    #expect(shell.openScene("library") == .opened)
    #expect(platform.opened == ["library", "library"])
}

@Test @MainActor
func scenesOfOneKindKeepTheirOwnPathsAndALinkGoesToTheSceneItCameTo() throws {
    reset()
    let shell = Shell(application: MailApp())
    let first = try #require(shell.makeSession("main"))
    let second = try #require(shell.makeSession("main"))
    shell.firstSceneShown()
    let firstStack = try #require(first.content as? Stack<Route>)
    let secondStack = try #require(second.content as? Stack<Route>)

    firstStack.setPath([.inbox, .message(1)])
    #expect(secondStack.path == [.inbox])
    #expect(shell.open(URL(string: "mail:/messages/7")!, in: second) == .opened)
    #expect(firstStack.path == [.inbox, .message(1)])
    #expect(secondStack.path == [.inbox, .message(7)])

    // Closing one for good leaves the other as it was.
    shell.sessionClosed(first)
    #expect(shell.sessions.count == 1)
    #expect(secondStack.path == [.inbox, .message(7)])
    // Without a scene named, a link goes to the first one left.
    #expect(shell.open(URL(string: "mail:/messages/8")!) == .opened)
    #expect(secondStack.path == [.inbox, .message(8)])
}

@Test @MainActor
func theActivationsSequenceStartsWithTheCurrentValueAndFollowsChanges() async throws {
    reset()
    let shell = Shell(application: MailApp())
    let first = try #require(shell.makeSession())
    let second = try #require(shell.makeSession())
    var iterator = shell.activations().makeAsyncIterator()

    #expect(await iterator.next() == .background)
    first.setActivation(.active)
    StateUpdates.flush()
    #expect(await iterator.next() == .active)

    // Another scene going inactive while the first stays active changes nothing for the app, so
    // nothing is delivered; the next value that is delivered is the one that differs.
    second.setActivation(.inactive)
    StateUpdates.flush()
    first.setActivation(.background)
    StateUpdates.flush()
    #expect(await iterator.next() == .inactive)
}

@Test @MainActor
func backgroundSessionEventsGoToTheHandlerWithTheirCompletion() {
    reset()
    let shell = Shell(application: MailApp())
    var heard: [String] = []
    var completed = 0
    shell.backgroundSessionHandler = { identifier, completion in
        heard.append(identifier)
        completion()
    }

    shell.backgroundSessionEvents(identifier: "uploads") { completed += 1 }

    #expect(heard == ["uploads"])
    #expect(completed == 1)
}

@Test @MainActor
func backgroundSessionEventsThatCameBeforeTheHandlerWaitForItInOrder() {
    reset()
    let shell = Shell(application: MailApp())
    var heard: [String] = []
    var completed = 0

    // The system calls before the app has had time to say what it does.
    shell.backgroundSessionEvents(identifier: "one") { completed += 1 }
    shell.backgroundSessionEvents(identifier: "two") { completed += 1 }
    #expect(heard.isEmpty)
    #expect(completed == 0)

    shell.backgroundSessionHandler = { identifier, completion in
        heard.append(identifier)
        completion()
    }
    #expect(heard == ["one", "two"])
    #expect(completed == 2)

    // They are given once: setting the handler again does not repeat them.
    shell.backgroundSessionHandler = { identifier, _ in heard.append("again " + identifier) }
    #expect(heard == ["one", "two"])
}
