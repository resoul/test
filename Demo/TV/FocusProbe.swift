import LayoutCore
import Nodes
import NodesRender
import ThemeCore

/// A screen for the remote's reach, set by the launch environment: a button at the top, a
/// block with nothing to focus that many screens tall, and a button under it — in the same
/// column as the top one, or in the other, alone or in a focus section. Select on a button
/// shows which one was pressed.
///
/// `FOCUS_PROBE` is `block=<screens>;column=<same|other>;section=<0|1>;inner=<0|1>`, for
/// example `block=3;column=other;section=1`. With `inner=1` the bottom button is at the end
/// of a scroll across, after blocks with nothing to focus wider than the screen.
@MainActor
final class FocusProbe: Node {
    let top: Button
    let bottom: Button
    let status = Text("Pressed: none", style: TextStyle(size: 15, color: .black))
    private let block = Node()
    private let lower = Lower()
    private let scroll = Scroll(.vertical)
    private let screens: Double
    private let otherColumn: Bool

    init(_ settings: String) {
        var values: [String: String] = [:]
        for pair in settings.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }
        screens = Double(values["block"] ?? "1") ?? 1
        otherColumn = values["column"] == "other"
        top = Button("Top") {}
        bottom = Button("Bottom") {}
        super.init()
        top.onTap = { [unowned self] in pressed("Top") }
        bottom.onTap = { [unowned self] in pressed("Bottom") }
        block.appearance.background = Color(red: 0.85, green: 0.86, blue: 0.90)
        lower.bottom = bottom
        lower.otherColumn = otherColumn
        lower.inner = values["inner"] == "1"
        lower.isFocusSection = values["section"] == "1"
        scroll.content = Content(owner: self)
    }

    private var presses: [String: Int] = [:]

    /// Shows the button pressed, and how many times it was.
    private func pressed(_ name: String) {
        presses[name, default: 0] += 1
        status.text = "Pressed: \(name) \(presses[name]!)"
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            status
            scroll.flex(grow: 1)
        }
        .gap(8)
    }

    /// The part under the block: the bottom button at the left, or at the right — or, with
    /// `inner`, at the end of a scroll across, after blocks with nothing to focus.
    final class Lower: Node {
        var bottom: Button?
        var otherColumn = false
        var inner = false
        private lazy var tiles = (1...8).map { _ in
            let tile = Node()
            tile.appearance.background = Color(red: 0.85, green: 0.86, blue: 0.90)
            return tile
        }
        private lazy var row = Scroll(.horizontal, content: Row(owner: self))

        override func layoutSpec() -> LayoutSpec? {
            if inner {
                return FlexContainer(.row) { row.flex(grow: 1) }
            }
            return FlexContainer(.row) {
                if let bottom { bottom }
            }
            .justifyContent(otherColumn ? .end : .start)
        }

        final class Row: Node {
            unowned let owner: Lower

            init(owner: Lower) {
                self.owner = owner
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.row) {
                    for tile in owner.tiles { tile.size(width: 160, height: 38) }
                    if let bottom = owner.bottom { bottom }
                }
                .gap(24)
            }
        }
    }

    final class Content: Node {
        unowned let owner: FocusProbe

        init(owner: FocusProbe) {
            self.owner = owner
        }

        override func layoutSpec() -> LayoutSpec? {
            // The screen's height in the layout's points: the block is that many of it.
            let window = owner.host?.size.height ?? 480
            return FlexContainer(.column) {
                FlexContainer(.row) { owner.top }
                owner.block.height(.points(window * owner.screens))
                owner.lower
                // Room after the bottom button, so it can come to the middle of the window.
                Node().height(.points(window))
            }
            .gap(16)
            .padding(top: 16, leading: 16, bottom: 16, trailing: 16)
        }
    }
}
