import LayoutCore
import Nodes
import NodesRender
import ThemeCore

/// A screen for moving rows with the remote, for UI tests: an edited table of six rows,
/// under a line that reads their order. `MOVE_PROBE` in the launch environment shows it.
@MainActor
final class MoveProbe: Node {
    struct Row: Identifiable {
        let id: Int
    }

    let status = Text("", style: TextStyle(size: 15))
    private var order = Array(0..<6)
    private let labels = NodeCache<Int, Label> { Label("Row \($0)") }
    private(set) lazy var table = Table<Row> { [labels] row in labels[row.id] }

    override init() {
        super.init()
        table.onMove = { [weak self] move in
            guard let self, let from = order.firstIndex(of: move.item) else { return }

            order.insert(order.remove(at: from), at: move.to.index)
            show()
        }
        table.isEditing = true
        show()
    }

    private func show() {
        table.sections = [TableSection(id: "rows", items: order.map(Row.init))]
        status.text = "Order: " + order.map(String.init).joined(separator: " ")
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            status
            table.flex(grow: 1)
        }
        .gap(16)
    }
}

/// A row's text, with room around it.
@MainActor
private final class Label: Node {
    let text: Text

    init(_ string: String) {
        text = Text(string, style: TextStyle(size: 17))
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer { text }
            .padding(16)
    }
}
