import TrellisCore

/// Financial/Analytics dashboard with KPI cards and activity list using Arrangement DSL.
final class AnalyticsDashboardNode: Node {
    let titleHeader = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let balanceVal = Node(
        appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 6)
    )
    let badgePill = Node(
        appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 11)
    )

    // KPI Card 1
    let kpi1Bg = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 12)
    )
    let kpi1Lbl = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let kpi1Val = Node(appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 4))
    let kpi1Bar = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 3))

    // KPI Card 2
    let kpi2Bg = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 12)
    )
    let kpi2Lbl = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let kpi2Val = Node(appearance: VisualStyle(background: .color(Palette.orange), cornerRadius: 4))
    let kpi2Bar = Node(appearance: VisualStyle(background: .color(Palette.pink), cornerRadius: 3))

    // Activity Section
    let activityTitle = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let activityMore = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 3)
    )

    // List items
    let tx1Icon = Node(
        appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 10)
    )
    let tx1Text = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 4))
    let tx1Amt = Node(appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 4))

    let tx2Icon = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 10))
    let tx2Text = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 4)
    )
    let tx2Amt = Node(appearance: VisualStyle(background: .color(Palette.orange), cornerRadius: 4))

    let tx3Icon = Node(appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 10))
    let tx3Text = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 4)
    )
    let tx3Amt = Node(appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 4))

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 20))
        style.width = .points(360)
        style.alignSelf = .center
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 18,
            padding: DirectionalEdgeInsets(top: 24, leading: 22, bottom: 24, trailing: 22)
        ) {
            // Header
            Column(spacing: 6) {
                Leaf(titleHeader).size(width: 70, height: 10)
                Row(justify: .spaceBetween, align: .center) {
                    Leaf(balanceVal).size(width: 140, height: 26)
                    Leaf(badgePill).size(width: 65, height: 22)
                }
            }

            // 2-Column KPI Cards
            Row(spacing: 12) {
                Column(
                    spacing: 6,
                    padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
                ) {
                    Leaf(kpi1Lbl).size(width: 48, height: 10)
                    Leaf(kpi1Val).size(width: 70, height: 18)
                    Leaf(kpi1Bar).size(height: 6)
                }
                .grow(1)

                Column(
                    spacing: 6,
                    padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
                ) {
                    Leaf(kpi2Lbl).size(width: 48, height: 10)
                    Leaf(kpi2Val).size(width: 70, height: 18)
                    Leaf(kpi2Bar).size(height: 6)
                }
                .grow(1)
            }

            // Transactions Header
            Row(justify: .spaceBetween, align: .center) {
                Leaf(activityTitle).size(width: 100, height: 12)
                Leaf(activityMore).size(width: 40, height: 10)
            }

            // Transactions List
            Column(spacing: 10) {
                Row(spacing: 12, align: .center) {
                    Leaf(tx1Icon).size(width: 36, height: 36)
                    Leaf(tx1Text).size(height: 16).grow(1)
                    Leaf(tx1Amt).size(width: 55, height: 16)
                }

                Row(spacing: 12, align: .center) {
                    Leaf(tx2Icon).size(width: 36, height: 36)
                    Leaf(tx2Text).size(height: 16).grow(1)
                    Leaf(tx2Amt).size(width: 55, height: 16)
                }

                Row(spacing: 12, align: .center) {
                    Leaf(tx3Icon).size(width: 36, height: 36)
                    Leaf(tx3Text).size(height: 16).grow(1)
                    Leaf(tx3Amt).size(width: 55, height: 16)
                }
            }
        }
    }
}

@MainActor enum S17 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style.justifyContent = .center
        root.style.alignItems = .center
        let dashboard = AnalyticsDashboardNode()
        root.addSubnode(dashboard)

        return ScenarioNodes.instance(
            .s17,
            root: root,
            inputs: "Analytics Dashboard with KPI row, balance banner, and activity feed",
            expected:
                "multi-tier responsive arrangement with nested rows, columns, and metric bars",
            paths: [
                "root",
                "root/dashboard",
                "root/dashboard/balanceRow",
                "root/dashboard/kpiGrid",
                "root/dashboard/activityList",
            ]
        )
    }
}
