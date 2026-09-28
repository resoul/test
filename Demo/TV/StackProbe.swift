import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import ThemeCore

/// A stack of screens for UI tests: three buttons that each open a message over them.
/// `STACK_PROBE` in the launch environment shows it, and `OPEN_MESSAGES=0,1` opens messages
/// at launch.
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
