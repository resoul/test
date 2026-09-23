import TrellisCore

@MainActor enum S12 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode);
        root.style {
            $0.flexDirection = .row; $0.flexWrap = .wrap; $0.alignContent = .spaceAround;
            $0.gap = 8; $0.crossGap = 16
        }
        for index in 1...8 {
            root.addSubnode(
                ScenarioNodes.fixed(
                    "item\(index)",
                    width: 88,
                    height: 48,
                    color: index.isMultiple(of: 2) ? Palette.orange : Palette.green
                )
            )
        }
        return ScenarioNodes.instance(
            .s12,
            root: root,
            inputs: "row wrap, alignContent=spaceAround, 8×88",
            expected: "items form several lines; line distribution follows alignContent",
            paths: ["root"] + (1...8).map { "root/item\($0)" }
        )
    }
}
