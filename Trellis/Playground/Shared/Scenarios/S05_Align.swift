import TrellisCore

@MainActor enum S05 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode);
        root.style {
            $0.flexDirection = .row; $0.alignItems = .center; $0.height = 160; $0.gap = 12
        }
        let start = ScenarioNodes.fixed("start", width: 52, height: 40, color: Palette.blue);
        start.style { $0.alignSelf = .start }
        let center = ScenarioNodes.fixed("center", width: 52, height: 70, color: Palette.green)
        let end = ScenarioNodes.fixed("end", width: 52, height: 40, color: Palette.pink);
        end.style { $0.alignSelf = .end }
        [start, center, end].forEach(root.addSubnode)
        return ScenarioNodes.instance(
            .s05,
            root: root,
            inputs: "alignItems=center; alignSelf=start/end",
            expected: "alignSelf overrides container cross-axis alignment",
            paths: ["root", "root/start", "root/center", "root/end"]
        )
    }
}
