import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender

/// `DEBUG_OVERLAY=1` to look at the debug overlay: a header, two buttons and a scrolling list of
/// rows, each outlined with a label of its identity and size. The overlay starts on; the "Overlay"
/// button switches it, as an app would while hunting a layout problem. Scrolling the list moves
/// the outlines with it. Nodes that take focus (the buttons, the rows) are outlined in green and
/// the rest in blue.
@MainActor
enum DebugOverlayProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Debug overlay")
    }

    private final class Rows: Node {
        let rows = (1...30).map { number -> Text in
            let row = Text("Row \(number)", style: TextStyle(size: 15))
            row.onTap = {}
            return row
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for row in rows { row }
            }
            .gap(6)
            .padding(8)
            .alignItems(.start)
        }
    }

    private final class Page: Node {
        private let title = Text("Layout, outlined", style: TextStyle(size: 20))
        private let toggle = Button("Overlay") {}
        private let other = Button("Other") {}
        private lazy var list = Scroll(.vertical, content: Rows())

        override init() {
            super.init()
            toggle.onTap = { [weak self] in
                guard let host = self?.host else { return }

                host.showsDebugOverlay.toggle()
            }
        }

        override func mountedChanged(_ isMounted: Bool) {
            if isMounted { host?.showsDebugOverlay = true }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                title
                FlexContainer(.row) {
                    toggle
                    other
                }
                .gap(8)
                list
            }
            .gap(12)
            .padding(16)
        }
    }
}
