import TrellisCore

/// One padded level of the S10 nesting as a self-arranging node: a `Column(padding: 12)`
/// around whatever it is given. Three of these nested — each an `Arrangement` owner placed as
/// the `Leaf` of the one above — are the declarative twin of the imperative tree below, and
/// the host resolves them top-down without a single manual call (C32). The implicit-wrapper
/// form of the same scene (`Column { Column { Column { Leaf } } }`) is covered by
/// `ArrangementEquivalenceTests`; a wrapper has no appearance of its own, so a scene that
/// wants each level painted needs real nodes.
final class S10PaddedLevel: Node {
    let content: Node

    init(content: Node, color: ThemeColor) {
        self.content = content
        super.init(appearance: VisualStyle(background: .color(color), cornerRadius: 8))
        style.minHeight = 24
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            Leaf(content)
        }
    }
}

@MainActor enum S10 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        makeSubclass(mode: mode)
    }

    /// Classic imperative construction — the same `Column` nesting as the subclass, written by
    /// hand (`flexDirection = .column` on every level, matching `Column(padding:)`).
    static func makeImperative(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let a = ScenarioNodes.node("level1", color: Palette.blue)
        a.style {
            $0.flexDirection = .column
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        let b = ScenarioNodes.node("level2", color: Palette.green)
        b.style {
            $0.flexDirection = .column
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        let c = ScenarioNodes.node("level3", color: Palette.orange)
        c.style {
            $0.flexDirection = .column
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        c.addSubnode(ScenarioNodes.fixed("leaf", width: 100, height: 64, color: Palette.pink))
        b.addSubnode(c); a.addSubnode(b); root.addSubnode(a)
        return ScenarioNodes.instance(
            .s10,
            root: root,
            inputs: "four nested containers, padding=12 (imperative)",
            expected: "each child origin advances by its ancestor padding",
            paths: [
                "root", "root/level1", "root/level1/level2", "root/level1/level2/level3",
                "root/level1/level2/level3/leaf",
            ]
        )
    }

    /// Declarative construction (C24 equivalence, C32 automatic resolve): the same three
    /// padded levels as owners nested through `Leaf`, resolved by the host before the first
    /// snapshot.
    static func makeSubclass(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let leaf = ScenarioNodes.fixed("leaf", width: 100, height: 64, color: Palette.pink)
        let level3 = S10PaddedLevel(content: leaf, color: Palette.orange)
        let level2 = S10PaddedLevel(content: level3, color: Palette.green)
        let level1 = S10PaddedLevel(content: level2, color: Palette.blue)
        root.addSubnode(level1)

        return ScenarioNodes.instance(
            .s10,
            root: root,
            inputs: "Arrangement subclass: four nested containers, padding=12",
            expected: "subclass geometry exactly matches imperative tree",
            paths: [
                "root", "root/level1", "root/level1/level2", "root/level1/level2/level3",
                "root/level1/level2/level3/leaf",
            ]
        )
    }
}
