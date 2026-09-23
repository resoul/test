import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T07 acceptance (implementation-plan-4.md §5): "смена темы перерисовывает цвет" — a theme
// change with no `TextNode` field touched still reaches a new committed `DisplayArtifact`,
// through `DisplayKey.environmentRevision` (T06, D52's "typography/theme inputs").

private let alternateTheme = Theme(
    id: "alternate",
    colors: ThemeColors(
        background: ThemeColor(red: 0, green: 0, blue: 0),
        surface: ThemeColor(red: 0.1, green: 0.1, blue: 0.1),
        primary: ThemeColor(red: 0.8, green: 0.2, blue: 0.1),
        secondary: ThemeColor(red: 0.7, green: 0.7, blue: 0.65),
        accent: ThemeColor(red: 1, green: 0.5, blue: 0.2),
        text: ThemeColor(red: 1, green: 1, blue: 1),
        textSecondary: ThemeColor(red: 0.7, green: 0.7, blue: 0.7),
        border: ThemeColor(red: 0.2, green: 0.2, blue: 0.2),
        error: ThemeColor(red: 1, green: 0.3, blue: 0.3),
        success: ThemeColor(red: 0.3, green: 0.9, blue: 0.4),
        warning: ThemeColor(red: 1, green: 0.7, blue: 0.2)
    )
)

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func waitForArtifact(_ bridge: NodeHostBridge, _ id: NodeID) async {
    for _ in 0..<20_000 where bridge.displayArtifact(for: id) == nil { await Task.yield() }
}

@Test @MainActor
func t07_themeChangeWithNoAuthoredColorEventuallyProducesANewArtifact() async {
    let root = Node()
    let label = TextNode(text: "Hello")
    root.style.flexDirection = .column
    root.style.width = 120
    root.addSubnode(label)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 320, height: 240), scale: 2))
    await waitForCommits(bridge, 1)
    await waitForArtifact(bridge, label.id)
    let completedBefore = bridge.displayStatistics.completed

    root.setEnvironment(ThemeKey.self, to: alternateTheme)
    await waitForCommits(bridge, 2)
    for _ in 0..<20_000 where bridge.displayStatistics.completed <= completedBefore {
        await Task.yield()
    }

    #expect(bridge.displayStatistics.completed > completedBefore)
}
