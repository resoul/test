import AppShell
import LayoutCore
import Nodes
import NodesRender

/// A screen of `SELECT_PROBE=1` for UI tests of the option menu: a select of how a list is
/// sorted, and a line saying what was chosen.
@MainActor
enum SelectProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Select")
    }

    private enum Sort: String, CaseIterable {
        case date, sender, subject

        var title: String { rawValue.capitalized }
    }

    private final class Page: Node {
        let sort = Select(options: Sort.allCases, selection: .date, placeholder: "Sort by") {
            $0.title
        }
        let chosen = Text("Sorted by Date", style: TextStyle(size: 17))

        override init() {
            super.init()
            sort.onChange = { [weak self] option in
                self?.chosen.text = "Sorted by \(option.title)"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                sort
                chosen
            }
            .gap(16)
            .padding(24)
            .alignItems(.start)
        }
    }
}
