import TrellisCore

@MainActor enum S08 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode);
        root.style {
            $0.flexDirection = .row; $0.height = 96
        }
        let fixed = ScenarioNodes.fixed("fixed", width: 60, height: 60, color: Palette.orange)
        let grow1 = ScenarioNodes.fixed("grow1", width: 20, height: 60, color: Palette.blue);
        grow1.style {
            $0.flexGrow = 1; $0.flexBasis = 20
        }
        let grow2 = ScenarioNodes.fixed("grow2", width: 20, height: 60, color: Palette.green);
        grow2.style {
            $0.flexGrow = 2; $0.flexBasis = 20
        }
        [fixed, grow1, grow2].forEach(root.addSubnode)
        return ScenarioNodes.instance(
            .s08,
            root: root,
            inputs: "grow=1:2, basis=20, fixed=60",
            expected: "free main-axis space splits 1:2 after bases",
            paths: ["root", "root/fixed", "root/grow1", "root/grow2"]
        )
    }
}
