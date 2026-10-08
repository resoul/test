import TrellisCore

@MainActor enum S03 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode); root.style { $0.gap = 8 }
        for (name, color) in [
            ("one", Palette.blue), ("two", Palette.green), ("three", Palette.orange),
        ] { root.addSubnode(ScenarioNodes.fixed(name, width: 120, height: 48, color: color)) }
        return ScenarioNodes.instance(
            .s03,
            root: root,
            inputs: "column, 3×120×48, gap=8",
            expected: "siblings increase on Y",
            paths: ["root", "root/one", "root/two", "root/three"]
        )
    }
}
