import TrellisCore

@MainActor enum S11 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let base = ScenarioNodes.fixed("base", width: 240, height: 180, color: Palette.blue)
        let badge = ScenarioNodes.fixed("badge", width: 52, height: 52, color: Palette.pink)
        badge.style {
            $0.positionType = .absolute; $0.offsets = DirectionalEdgeOffsets(top: 12, trailing: 12)
        }
        base.addSubnode(badge); root.addSubnode(base)
        return ScenarioNodes.instance(
            .s11,
            root: root,
            inputs: "absolute top=12, trailing=12",
            expected:
                "badge is pinned to base’s top trailing corner and does not consume flex space",
            paths: ["root", "root/base", "root/base/badge"]
        )
    }
}
