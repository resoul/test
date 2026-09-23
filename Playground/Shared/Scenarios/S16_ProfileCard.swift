import TrellisCore

/// Complex social profile card built entirely using the declarative Arrangement DSL.
final class ProfileCardNode: Node {
    let avatar = Node(appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 30))
    let onlineBadge = Node(
        appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 7)
    )

    let name = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 4))
    let verified = Node(appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 8))
    let role = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 4)
    )
    let location = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 4)
    )

    let bioBox = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 8)
    )

    let stat1Num = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 4))
    let stat1Lbl = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let stat2Num = Node(appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 4))
    let stat2Lbl = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let stat3Num = Node(
        appearance: VisualStyle(background: .color(Palette.orange), cornerRadius: 4)
    )
    let stat3Lbl = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )

    let followBtn = Node(
        appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 10)
    )
    let messageBtn = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 10)
    )
    let moreBtn = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 10)
    )

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 18))
        style.width = .points(360)
        style.alignSelf = .center
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 16,
            padding: DirectionalEdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
        ) {
            // Header: Avatar with Online badge overlay + User details
            Row(spacing: 16, align: .center) {
                Overlay {
                    Leaf(avatar).size(width: 60, height: 60)
                    Leaf(onlineBadge)
                        .size(width: 14, height: 14)
                        .offset(DirectionalEdgeOffsets(bottom: 0, trailing: 0))
                }
                .size(width: 60, height: 60)

                Column(spacing: 6) {
                    Row(spacing: 6, align: .center) {
                        Leaf(name).size(width: 130, height: 18)
                        Leaf(verified).size(width: 16, height: 16)
                    }
                    Leaf(role).size(width: 110, height: 14)
                    Leaf(location).size(width: 80, height: 12)
                }
            }

            // Bio description block
            Leaf(bioBox).size(height: 44)

            // Statistics Row: 3 metrics distributed evenly
            Row(spacing: 12) {
                Column(spacing: 4, align: .center) {
                    Leaf(stat1Num).size(width: 44, height: 16)
                    Leaf(stat1Lbl).size(width: 52, height: 10)
                }
                .grow(1)

                Column(spacing: 4, align: .center) {
                    Leaf(stat2Num).size(width: 44, height: 16)
                    Leaf(stat2Lbl).size(width: 52, height: 10)
                }
                .grow(1)

                Column(spacing: 4, align: .center) {
                    Leaf(stat3Num).size(width: 44, height: 16)
                    Leaf(stat3Lbl).size(width: 44, height: 10)
                }
                .grow(1)
            }

            // Action Buttons
            Row(spacing: 10) {
                Leaf(followBtn).size(height: 38).grow(1)
                Leaf(messageBtn).size(height: 38).grow(1)
                Leaf(moreBtn).size(width: 38, height: 38)
            }
        }
    }
}

@MainActor enum S16 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style.justifyContent = .center
        root.style.alignItems = .center
        let card = ProfileCardNode()
        root.addSubnode(card)

        return ScenarioNodes.instance(
            .s16,
            root: root,
            inputs: "Social Profile Card with Overlay badge, header, stats, and actions",
            expected: "complex multi-container composition resolved declaratively via Arrangement",
            paths: [
                "root",
                "root/card",
                "root/card/avatarOverlay",
                "root/card/headerDetails",
                "root/card/statsRow",
                "root/card/actionsRow",
            ]
        )
    }
}
