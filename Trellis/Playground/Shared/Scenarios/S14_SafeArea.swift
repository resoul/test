import TrellisCore

@MainActor enum S14 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.safeAreaBoundary = true
        root.addSubnode(
            ScenarioNodes.fixed("content", width: 220, height: 120, color: Palette.green)
        )
        return ScenarioNodes.instance(
            .s14,
            root: root,
            inputs: "host safe-area, root boundary=true",
            expected:
                "content starts after physical safe-area plus authored padding; use nativeBounds on device",
            paths: ["root", "root/content"]
        )
    }
}
