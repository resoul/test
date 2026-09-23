import TrellisCore

@MainActor enum S04 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode);
        root.style {
            $0.flexDirection = .row; $0.justifyContent = .spaceEvenly; $0.height = 120
        }
        for name in ["start", "middle", "end"] {
            root.addSubnode(ScenarioNodes.fixed(name, width: 40, height: 40, color: Palette.orange))
        }
        return ScenarioNodes.instance(
            .s04,
            root: root,
            inputs: "row, justify=spaceEvenly",
            expected:
                "remaining main-axis space is divided into four equal spaces; edit justifyContent through six cases",
            paths: ["root", "root/start", "root/middle", "root/end"]
        )
    }
}
