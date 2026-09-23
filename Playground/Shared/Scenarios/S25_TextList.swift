import TrellisCore

/// 200 single-line `TextNode` rows in a clipped viewport, a handful rewritten every tick
/// (T11's `text-list-1000`/`text-burst-edits` shape, at Playground scale) — the list keeps
/// scrolling-list identity semantics real code needs: rows are stable `TextNode` instances kept
/// in an array, never rebuilt, so an edit reuses the same `NodeID`/`CALayer` (D53/T07) instead
/// of tearing the row down and back up.
final class TextListNode: Node {
    private(set) var rows: [TextNode] = []
    private var tick = 0

    init(count: Int) {
        super.init(appearance: VisualStyle())
        // `flexShrink = 0`: the list's natural content height (200 rows × their own natural
        // height) is far taller than the clipped viewport around it. Flexbox's default
        // `flexShrink = 1` would otherwise compress every row down toward zero height to make
        // the whole list "fit" its container (correct default behavior for an ordinary
        // container, exactly wrong for a scrollable-style list) — opting out keeps every row
        // at its own natural size, so the viewport's `overflow = .hidden` clips the overflow
        // visually instead of every row being crushed to fit.
        style {
            $0.flexDirection = .column; $0.gap = 4; $0.flexShrink = 0
        }
        for index in 0..<count {
            let row = TextNode(text: "Row \(index) of \(count)")
            rows.append(row)
            addSubnode(row)
        }
    }

    /// Rewrites five rows near the top of the list every tick — inside the clipped viewport a
    /// screenshot actually shows, so a live update is visible without scrolling.
    func mutate() {
        tick += 1
        for offset in 0..<5 {
            let index = (tick + offset) % rows.count
            rows[index].text = "Row \(index) — live update #\(tick)"
        }
    }
}

@MainActor enum S25 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let list = TextListNode(count: 200)

        let viewport = ScenarioNodes.node("viewport", color: Palette.card)
        viewport.style {
            $0.flexDirection = .column
            $0.width = 288
            $0.height = 560
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            $0.visual = LayoutVisualProperties(overflow: .hidden)
        }
        viewport.addSubnode(list)
        root.addSubnode(viewport)

        let session = ScenarioSession()
        session.start { [weak list] in list?.mutate() }

        return ScenarioNodes.instance(
            .s25,
            root: root,
            inputs:
                "200 single-line TextNode rows in a clipped 288×560 viewport; 5 rows rewritten every tick",
            expected:
                "all 200 rows measure and raster without a dropped frame; overflow clips at the "
                + "viewport bounds; edited rows keep their NodeID/CALayer identity, no flicker "
                + "from a torn-down-and-rebuilt row",
            paths: ["root", "root/viewport", "root/viewport/list"],
            session: session
        )
    }
}
