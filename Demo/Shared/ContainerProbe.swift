import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import StateCore
import ThemeCore

/// Scenes for UI tests of the containers of screens, chosen by the launch environment:
/// `TABS_PROBE=1` shows tabs (an inbox stack, a search screen, a settings screen with a
/// counter), `SPLIT_PROBE=1` a split (folders in the sidebar, a stack of the folder's messages
/// as the content).
@MainActor
enum ContainerProbe {
    static func content(_ environment: [String: String]) -> (any SceneContent)? {
        if environment["TABS_PROBE"] != nil { return tabs() }
        if environment["SPLIT_PROBE"] != nil { return split() }
        return nil
    }

    /// A screen of a title, a line of text and buttons.
    private final class Page: Node {
        let text: Text
        let buttons: [Button]

        init(_ line: String, buttons: [Button] = []) {
            text = Text(line, style: TextStyle(size: 17))
            self.buttons = buttons
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                text
                for button in buttons { button }
            }
            .gap(16)
            .padding(24)
            .alignItems(.start)
        }
    }

    /// A screen that counts taps: what a tab keeps while another is picked.
    private final class CounterPage: Node {
        let text = Text("Count 0", style: TextStyle(size: 17))
        let button = Button("Count up") {}
        private var count = 0

        override init() {
            super.init()
            button.onTap = { [weak self] in
                guard let self else { return }

                count += 1
                text.text = "Count \(count)"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                text
                button
            }
            .gap(16)
            .padding(24)
            .alignItems(.start)
        }
    }

    private enum InboxRoute: Hashable {
        case list
        case detail
    }

    private static func tabs() -> Tabs<String> {
        weak var inbox: Stack<InboxRoute>?
        let stack = Stack(root: InboxRoute.list) { route in
            switch route {
            case .list:
                NodeScreen(
                    Page("Inbox list", buttons: [Button("Open detail") { inbox?.push(.detail) }]),
                    title: "Inbox"
                )
            case .detail:
                NodeScreen(Page("Inbox detail"), title: "Detail")
            }
        }
        inbox = stack
        return Tabs(
            selection: "inbox",
            [
                Tab("inbox", title: "Inbox", symbol: "tray", content: stack),
                Tab(
                    "search",
                    title: "Search",
                    symbol: "magnifyingglass",
                    content: NodeScreen(Page("Search screen"), title: "Search")
                ),
                Tab(
                    "settings",
                    title: "Settings",
                    symbol: "gear",
                    content: NodeScreen(CounterPage(), title: "Settings")
                ),
            ]
        )
    }

    private enum FolderRoute: Hashable {
        case folder(String)
        case message
    }

    private static func split() -> Split {
        weak var content: Stack<FolderRoute>?
        weak var container: Split?
        let stack = Stack(root: FolderRoute.folder("Inbox")) { route in
            switch route {
            case .folder(let name):
                NodeScreen(
                    Page(
                        "\(name) folder",
                        buttons: [Button("Open message") { content?.push(.message) }]
                    ),
                    title: name
                )
            case .message:
                NodeScreen(Page("A message"), title: "Message")
            }
        }
        content = stack
        func choose(_ name: String) {
            content?.setPath([.folder(name)])
            container?.showContent()
        }
        let sidebar = NodeScreen(
            Page(
                "Folders",
                buttons: [
                    Button("Inbox") { choose("Inbox") },
                    Button("Sent") { choose("Sent") },
                ]
            ),
            title: "Mailboxes"
        )
        let split = Split(sidebar: sidebar, content: stack)
        container = split
        return split
    }
}
