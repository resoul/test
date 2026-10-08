import TrellisCore

@MainActor enum S07 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let container = ScenarioNodes.node("container", color: Palette.blue);
        container.style {
            $0.padding = DirectionalEdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24);
            $0.width = 240
        }
        let child = ScenarioNodes.fixed("child", width: 100, height: 48, color: Palette.orange);
        child.style {
            $0.margin = DirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        }
        container.addSubnode(child); root.addSubnode(container)
        return ScenarioNodes.instance(
            .s07,
            root: root,
            inputs: "container padding=20/24; child margin=12/16",
            expected: "padding insets child; margin separates it from container edges",
            paths: ["root", "root/container", "root/container/child"]
        )
    }
}
