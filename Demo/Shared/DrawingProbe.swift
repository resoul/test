import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import StateCore

/// `DRAWING_PROBE=1`: a long page of 300 lines of text, drawn in the background and only near the
/// screen (`DisplayRange`): a line two windows away holds no bitmap. `DRAWING_PROBE=lazy`: a list of
/// 2000 rows that tells what it prefetched; the line above it says how many rows were announced and
/// how many were called off, so scrolling far shows both numbers grow.
@MainActor
enum DrawingProbe {
    static func content(lazy: Bool) -> any SceneContent {
        let screen = NodeScreen(lazy ? LazyPage() : LongPage(), title: "Drawing")
        screen.drawingMode = .asynchronous
        screen.displayRange = DisplayRange(drawDistance: 1, releaseDistance: 2)
        return screen
    }

    private final class LongPage: Node {
        private let lines = (0..<300).map { Text("Line \($0)", style: TextStyle(size: 22)) }
        private lazy var body = Body(lines)
        private lazy var list = Scroll(.vertical, content: body)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { list.flex(grow: 1) }.padding(16)
        }
    }

    private final class Body: Node {
        let lines: [Text]

        init(_ lines: [Text]) {
            self.lines = lines
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for line in lines { line.flex(shrink: 0) }
            }
            .alignItems(.start)
            .gap(8)
        }
    }

    private struct Row: Identifiable {
        let id: Int
    }

    private final class LazyPage: Node {
        private let status = Text("announced: 0 · called off: 0", style: TextStyle(size: 17))
        private let announced = State(0)
        private let calledOff = State(0)
        private let cells = NodeCache<Int, Text> { id in
            Text("Row \(id)", style: TextStyle(size: 22))
        }
        private lazy var stack = LazyStack<Row>(estimatedLength: 32) { [cells] row in cells[row.id] }
        private lazy var list = Scroll(.vertical, content: stack)

        override init() {
            super.init()
            stack.items = (0..<2000).map(Row.init)
            stack.prefetch = { [weak self] rows in self?.announced.value += rows.count }
            stack.cancelPrefetch = { [weak self] rows in self?.calledOff.value += rows.count }
        }

        override func update() {
            status.text = "announced: \(announced.value) · called off: \(calledOff.value)"
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                status
                list.flex(grow: 1)
            }
            .gap(12)
            .padding(16)
        }
    }
}
