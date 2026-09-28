import Foundation
import Nodes
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
