import LayoutCore
import Testing

@testable import Nodes

extension Command {
    fileprivate static let flag = Command(
        "flag",
        title: "Flag",
        shortcut: Shortcut("f", [.command, .shift])
    )
    fileprivate static let archive = Command("archive", title: "Archive")
}

/// A row that can be focused and pressed.
@MainActor
private final class Row: Node {
    override init() {
        super.init()
        onTap = {}
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 20)) }
}

/// A list of two rows, inside a screen.
@MainActor
private final class List: Node {
    let first = Row()
    let second = Row()

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            first; second
        }
    }
}

@MainActor
private final class Screen: Node {
    let list = List()
    let aside = Row()

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            list; aside
        }
        .alignItems(.start)
    }
}

@MainActor
private func host(_ screen: Screen) -> NodeHost {
    let host = NodeHost(root: screen, size: LayoutSize(width: 200, height: 200))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func aCommandGoesFromTheFocusedNodeOutToTheFirstThatCanCarryItOut() {
    let screen = Screen()
    let host = host(screen)
    var done: [String] = []
    var listCan = false
    screen.handle(.flag) { done.append("screen") }
    screen.list.handle(.flag, isEnabled: { listCan }) { done.append("list") }
    host.focus(screen.list.second.id)

    // The list cannot yet: the screen around it can.
    #expect(host.canPerform(.flag))
    #expect(host.perform(.flag))
    listCan = true
    #expect(host.perform(.flag))
    // From a row outside the list, the list's handler is not on the way out.
    host.focus(screen.aside.id)
    #expect(host.perform(.flag))
    #expect(done == ["screen", "list", "screen"])

    #expect(!host.canPerform(.archive))
    #expect(!host.perform(.archive))
    host.detach()
}

@Test @MainActor
func withoutTheFocusACommandGoesToTheNodeLastPressedElseToTheRoot() {
    let screen = Screen()
    let host = host(screen)
    var done: [String] = []
    screen.handle(.archive) { done.append("screen") }
    screen.list.handle(.archive) { done.append("list") }

    host.perform(.archive)
    // The second row of the list is at 20 from the top.
    host.pointerDown(at: LayoutPoint(x: 10, y: 30))
    host.pointerUp(at: LayoutPoint(x: 10, y: 30))
    host.perform(.archive)
    host.pointerDown(at: LayoutPoint(x: 10, y: 50))
    host.pointerCancelled()
    host.perform(.archive)
    #expect(done == ["screen", "list", "screen"])
    host.detach()
}

@Test @MainActor
func aShortcutCarriesOutTheCommandItBelongsTo() {
    let screen = Screen()
    let host = host(screen)
    var flags = 0
    screen.list.handle(.flag) { flags += 1 }
    host.focus(screen.list.first.id)

    // A capital letter is its small one: Shift is a modifier.
    #expect(Shortcut("F", [.command, .shift]) == Command.flag.shortcut)
    #expect(host.canPerform(Shortcut("f", [.command, .shift])))
    #expect(host.perform(Shortcut("f", [.command, .shift])))
    #expect(!host.perform(Shortcut("f", [.command])))
    #expect(flags == 1)

    screen.list.removeHandler(for: .flag)
    #expect(!host.perform(Shortcut("f", [.command, .shift])))
    host.detach()
}

@Test @MainActor
func theAvailableCommandsAreTheNearestHandlersEachOnce() {
    let screen = Screen()
    let host = host(screen)
    screen.handle(.archive) {}
    screen.handle(.flag) {}
    screen.list.handle(.flag, isEnabled: { false }) {}
    screen.list.second.handle(.back) {}
    host.focus(screen.list.second.id)

    #expect(host.availableCommands().map(\.id) == ["back", "flag", "archive"])
    #expect(host.handlesCommands)
    // A second handler replaces the first.
    screen.list.second.handle(.back) {}
    #expect(screen.list.second.handledCommands == [.back])
    host.detach()
}

@Test
func aMenuIsBuiltFromCommandsDividersAndMenus() {
    let archives = true
    let bar = MenuBar {
        Menu("Message") {
            Command.flag
            if archives { Command.archive }
            Divider()
            Menu("More") { Command.back }
        }
        Menu("View") {}
    }

    #expect(bar.menus.map(\.title) == ["Message", "View"])
    #expect(
        bar.menus[0].items == [
            .command(.flag), .command(.archive), .divider,
            .menu(Menu("More") { Command.back }),
        ]
    )
}
