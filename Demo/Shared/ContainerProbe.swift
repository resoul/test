import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import StateCore
import ThemeCore

/// Scenes for UI tests of the containers of screens and of controls, chosen by the launch
/// environment: `TABS_PROBE=1` shows tabs (an inbox stack, a search screen, a settings screen
/// with a counter), `SPLIT_PROBE=1` a split (folders in the sidebar, a stack of the folder's
/// messages as the content), `TOGGLE_PROBE=1` a switch and a check box, `HOSTED_PROBE=1` a
/// system button inside the tree (`HostedProbe`), `FIELDS_PROBE=1` text fields (`FieldsProbe`; with `KEYBOARD_BAR=1` the
/// bar above the keyboard),
/// `EDITOR_PROBE=1` the multi-line editor (`EditorProbe`), `SELECT_PROBE=1` the option
/// menu (`SelectProbe`), `TOAST_PROBE=1` toasts (`ToastProbe`), `RICH_PROBE=1` styled text and links
/// (`RichProbe`), `RICH_EDITOR_PROBE=1` the rich text editor (`RichEditorProbe`), `VIDEO_PROBE=1` a video
/// (`VideoProbe`), `SYNC_PROBE=1` a list kept in step with a server (`SyncProbe`), `PERMISSION_PROBE=1` what the
/// system says about permissions (`PermissionProbe`), `PERMISSION_LAYER=1` the same through the
/// permission layer (`PermissionLayerProbe`), `PERMISSION_FLOW=1` the explanation and refusal screens around the
/// camera permission (`PermissionFlowProbe`), `DEBUG_OVERLAY=1` the debug overlay over a tree with a scroll
/// (`DebugOverlayProbe`), `BACKGROUND_PROBE=1` background transfers across the app's endings
/// (`BackgroundProbe`), `PAGING_PROBE=1` a list that asks for its next page (`PagingProbe`; `=table` a table with its page footer),
/// `LOCALIZATION_PROBE=1` texts in the system's language (`LocalizationProbe`).
@MainActor
enum ContainerProbe {
    static func content(_ environment: [String: String]) -> (any SceneContent)? {
        if environment["TABS_PROBE"] != nil { return tabs() }
        if environment["SPLIT_PROBE"] != nil { return split() }
        if environment["HOSTED_PROBE"] != nil { return HostedProbe.content() }
        if environment["FIELDS_PROBE"] != nil {
            return FieldsProbe.content(bar: environment["KEYBOARD_BAR"] != nil)
        }
        if environment["SELECT_PROBE"] != nil { return SelectProbe.content() }
        if environment["TOAST_PROBE"] != nil { return ToastProbe.content() }
        if environment["RICH_PROBE"] != nil { return RichProbe.content() }
        if environment["RICH_EDITOR_PROBE"] != nil {
            return RichEditorProbe.content(
                quote: environment["RICH_EDITOR_QUOTE"] != nil,
                sample: environment["RICH_EDITOR_SAMPLE"] != nil
            )
        }
        if environment["SYNC_PROBE"] != nil { return SyncProbe.content() }
        if environment["PERMISSION_LAYER"] != nil { return PermissionLayerProbe.content() }
        if environment["PERMISSION_FLOW"] != nil { return PermissionFlowProbe.content() }
        if environment["DEBUG_OVERLAY"] != nil { return DebugOverlayProbe.content() }
        if environment["BACKGROUND_PROBE"] != nil { return BackgroundProbe.content() }
        if let probe = environment["PAGING_PROBE"] {
            return probe == "table" ? TablePagingProbe.content() : PagingProbe.content()
        }
        if environment["LOCALIZATION_PROBE"] != nil { return LocalizationProbe.content() }
        if let probe = environment["PERMISSION_PROBE"] {
            return PermissionProbe.content(auto: environment["PERMISSION_AUTO"] ?? (probe == "1" ? nil : probe))
        }
        if environment["VIDEO_PROBE"] != nil {
            return VideoProbe.content(
                fill: environment["VIDEO_FILL"] != nil,
                autoplay: environment["VIDEO_AUTOPLAY"] != nil,
                preload: environment["VIDEO_PRELOAD"]
            )
        }
        if environment["EDITOR_PROBE"] != nil {
            let room = environment["EDITOR_LOW"].flatMap(Double.init).flatMap {
                $0 >= 100 ? $0 : nil
            }
            return EditorProbe.content(low: environment["EDITOR_LOW"] != nil, room: room ?? 560)
        }
        if environment["TOGGLE_PROBE"] != nil {
            return NodeScreen(TogglePage(), title: "Toggles")
        }
        return nil
    }

    /// A switch and a check box, and a line saying what each shows.
    private final class TogglePage: Node {
        let status = Text("", style: TextStyle(size: 17))
        let toggle = Switch(label: "Notifications")
        let box = Checkbox(.mixed, label: "Select all")

        override init() {
            super.init()
            toggle.onChange = { [weak self] _ in self?.show() }
            box.onChange = { [weak self] _ in self?.show() }
            show()
        }

        private func show() {
            let all =
                switch box.value {
                case .off: "off"
                case .on: "on"
                case .mixed: "mixed"
                }
            status.text = "Notifications \(toggle.isOn ? "on" : "off"), all \(all)"
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                status
                toggle
                box
            }
            .gap(24)
            .padding(24)
            .alignItems(.start)
        }
    }

    /// A screen of a title, a line of text and buttons.
    final class Page: Node {
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

    private enum InboxRoute: Hashable, Sendable {
        case list
        case detail
    }

    /// The inbox's screens as URLs, for the path to come back after a relaunch.
    private static let inboxRoutes = RouteTable<InboxRoute> {
        RoutePattern("/", .list)
        RoutePattern("/detail", .detail)
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
        stack.restorable(using: inboxRoutes)
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
