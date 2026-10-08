import TrellisCore

@MainActor enum S13 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode, direction: .rightToLeft);
        root.style {
            $0.flexDirection = .row;
            $0.padding = DirectionalEdgeInsets(top: 16, leading: 40, bottom: 16, trailing: 12);
            $0.gap = 8
        }
        for name in ["leading", "middle", "trailing"] {
            root.addSubnode(ScenarioNodes.fixed(name, width: 52, height: 52, color: Palette.blue))
        }
        return ScenarioNodes.instance(
            .s13,
            root: root,
            inputs: "RTL, logical leading=40 trailing=12",
            expected: "leading/trailing resolve right/left; row order follows RTL direction",
            paths: ["root", "root/leading", "root/middle", "root/trailing"]
        )
    }
}
