import TrellisCore

@MainActor enum S06 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode);
        root.style {
            $0.flexDirection = .row; $0.flexWrap = .wrap; $0.gap = 14; $0.crossGap = 20
        }
        for index in 1...6 {
            root.addSubnode(
                ScenarioNodes.fixed(
                    "tile\(index)",
                    width: 84,
                    height: 44,
                    color: index.isMultiple(of: 2) ? Palette.green : Palette.blue
                )
            )
        }
        return ScenarioNodes.instance(
            .s06,
            root: root,
            inputs: "wrap, gap=14, crossGap=20",
            expected: "main and wrapped-line gaps differ",
            paths: ["root"] + (1...6).map { "root/tile\($0)" }
        )
    }
}
