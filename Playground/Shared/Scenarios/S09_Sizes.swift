import TrellisCore

@MainActor enum S09 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let points = ScenarioNodes.fixed("points", width: 100, height: 40, color: Palette.blue)
        let fraction = ScenarioNodes.node("fraction", color: Palette.green);
        fraction.style {
            $0.width = .fraction(0.5); $0.height = 40
        }
        let bounded = ScenarioNodes.fixed("bounded", width: 180, height: 40, color: Palette.orange);
        bounded.style { $0.maxWidth = 120 }
        [points, fraction, bounded].forEach(root.addSubnode)
        return ScenarioNodes.instance(
            .s09,
            root: root,
            inputs: "100pt, 50%, 180pt max=120",
            expected: "points stay exact; fraction resolves from parent; maximum clamps",
            paths: ["root", "root/points", "root/fraction", "root/bounded"]
        )
    }
}
