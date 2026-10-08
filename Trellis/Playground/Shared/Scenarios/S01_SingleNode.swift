import TrellisCore

@MainActor enum S01 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.addSubnode(ScenarioNodes.fixed("card", width: 120, height: 80, color: Palette.blue))
        return ScenarioNodes.instance(
            .s01,
            root: root,
            inputs: "card=120×80",
            expected: "root/card is visible at root padding",
            paths: ["root", "root/card"]
        )
    }
}
