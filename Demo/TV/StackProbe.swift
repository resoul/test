import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import ThemeCore

/// A stack of screens for UI tests: three buttons that each open a message over them.
/// `STACK_PROBE` in the launch environment shows it, and `OPEN_MESSAGES=0,1` opens messages
/// at launch. With `OWN_MENU` a message is a screen whose node takes the first Menu itself, to
/// close its panel, and only the second goes back.
@MainActor
final class StackProbe: Node {
    enum Route: Hashable {
        case list
        case message(Int)
    }

    let buttons: [Button]

    init(open: @escaping @MainActor (Int) -> Void) {
        buttons = (0..<3).map { index in Button("Open \(index)") { open(index) } }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for button in buttons { button }
        }
        .gap(16)
        .padding(24)
        .alignItems(.start)
    }

    static func makeStack() -> Stack<Route> {
        weak var opener: Stack<Route>?
        let stack = Stack(root: Route.list) { route in
            switch route {
            case .list:
                NodeScreen(StackProbe { opener?.push(.message($0)) }, title: "Messages")
            case .message(let index) where ProcessInfo.processInfo.environment["OWN_MENU"] != nil:
                NodeScreen(PanelNode(), title: "Message \(index)")
            case .message(let index):
                NodeScreen(
                    MessageNode(
                        Mail(id: index, sender: "Sender \(index)", subject: "Subject \(index)")
                    ),
                    title: "Message \(index)"
                )
            }
        }
        opener = stack
        if let ids = ProcessInfo.processInfo.environment["OPEN_MESSAGES"] {
            stack.setPath(
                [.list] + ids.split(separator: ",").compactMap { Int($0) }.map(Route.message)
            )
        }
        return stack
    }
}

/// A screen with a panel that Menu closes: the node takes Menu itself while the panel is
/// open, and when it is closed leaves it to the stack.
@MainActor
final class PanelNode: Node {
    let status = Text("Panel open", style: TextStyle(size: 15))
    private var isOpen = true

    override init() {
        super.init()
        handle(.back, isEnabled: { [weak self] in self?.isOpen ?? false }) { [weak self] in
            self?.isOpen = false
            self?.status.text = "Panel closed"
        }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { status }
            .padding(24)
    }
}
