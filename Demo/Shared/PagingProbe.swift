import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import StateCore

/// `PAGING_PROBE=1`: a list that asks for its next page as the end comes near. Each page is 30 rows
/// and takes a moment to arrive; the fourth is the last. The line above the list says how many rows
/// are loaded and what the paging is doing. Left alone the list loads three pages — the limit
/// of pages it asks for without scrolling — and stops; scrolling makes it ask again, until the
/// last page.
@MainActor
enum PagingProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Paging")
    }

    private struct Row: Identifiable {
        let id: Int
    }

    private final class Page: Node {
        private let status = Text("loaded: 0 · idle", style: TextStyle(size: 17))
        private let cells = NodeCache<Int, Text> { id in
            let text = Text("Row \(id)", style: TextStyle(size: 17))
            return text
        }
        private lazy var stack = LazyStack<Row>(estimatedLength: 44) { [cells] row in
            cells[row.id]
        }
        private lazy var list = Scroll(.vertical, content: stack)

        override init() {
            super.init()
            stack.pagination = PaginationPolicy(pageSize: 30)
            stack.loadMore = { [weak self] request in
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }

                stack.items += (request.loadedCount..<request.loadedCount + 30).map(Row.init)
                if stack.items.count >= 120 { stack.reachedEnd = true }
            }
        }

        override func update() {
            let state =
                switch stack.pageLoadState {
                case .idle: "idle"
                case .loading: "loading"
                case .failed: "failed"
                case .endReached: "end"
                }
            status.text = "loaded: \(stack.items.count) · \(state)"
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                status
                list
            }
            .gap(12)
            .padding(16)
        }
    }
}
