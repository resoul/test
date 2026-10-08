import TrellisCore

@MainActor enum S02 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode);
        root.style {
            $0.flexDirection = .row; $0.gap = 8
        }
        for (name, color) in [
            ("one", Palette.blue), ("two", Palette.green), ("three", Palette.orange),
        ] { root.addSubnode(ScenarioNodes.fixed(name, width: 72, height: 72, color: color)) }
        return ScenarioNodes.instance(
            .s02,
            root: root,
            inputs: "row, 3×72, gap=8",
            expected: "three equal siblings increase on X with 8pt gaps",
            paths: ["root", "root/one", "root/two", "root/three"]
        )
    }
}
