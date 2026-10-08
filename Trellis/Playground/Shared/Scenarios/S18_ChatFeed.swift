import TrellisCore

/// Realistic messenger / chat thread with incoming & outgoing message bubbles and input bar.
final class ChatFeedNode: Node {
    // Header
    let headerAvatar = Node(
        appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 19)
    )
    let headerTitle = Node(
        appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 4)
    )
    let headerStatus = Node(
        appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 3)
    )
    let headerAction = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 12)
    )

    // Message 1 (Incoming)
    let msg1Avatar = Node(
        appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 14)
    )
    let msg1Bubble = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 12)
    )
    let msg1Time = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 2)
    )

    // Message 2 (Outgoing)
    let msg2Bubble = Node(
        appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 12)
    )
    let msg2Time = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 2)
    )

    // Message 3 (Incoming)
    let msg3Avatar = Node(
        appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 14)
    )
    let msg3Bubble = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 12)
    )

    // Message 4 (Outgoing)
    let msg4Bubble = Node(
        appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 12)
    )

    // Input Bar
    let attachBtn = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 17)
    )
    let inputBar = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 18)
    )
    let sendBtn = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 18))

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 20))
        style.width = .points(360)
        style.alignSelf = .center
        style.flexGrow = 1.0
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 16,
            padding: DirectionalEdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)
        ) {
            // Header Bar
            Row(spacing: 10, align: .center) {
                Leaf(headerAvatar).size(width: 38, height: 38)
                Column(spacing: 4) {
                    Leaf(headerTitle).size(width: 110, height: 14)
                    Leaf(headerStatus).size(width: 65, height: 8)
                }
                .grow(1)
                Leaf(headerAction).size(width: 28, height: 28)
            }

            // Chat Messages Feed
            Column(spacing: 12) {
                // Incoming 1
                Row(spacing: 8, align: .start) {
                    Leaf(msg1Avatar).size(width: 28, height: 28)
                    Column(spacing: 4) {
                        Leaf(msg1Bubble).size(width: 175, height: 38)
                        Leaf(msg1Time).size(width: 40, height: 8)
                    }
                }

                // Outgoing 2
                Column(spacing: 4, align: .end) {
                    Leaf(msg2Bubble).size(width: 195, height: 44)
                    Leaf(msg2Time).size(width: 40, height: 8)
                }

                // Incoming 3
                Row(spacing: 8, align: .start) {
                    Leaf(msg3Avatar).size(width: 28, height: 28)
                    Leaf(msg3Bubble).size(width: 135, height: 32)
                }

                // Outgoing 4
                Column(align: .end) {
                    Leaf(msg4Bubble).size(width: 160, height: 32)
                }
            }
            .grow(1)

            // Input Bar
            Row(spacing: 8, align: .center) {
                Leaf(attachBtn).size(width: 34, height: 34)
                Leaf(inputBar).size(height: 36).grow(1)
                Leaf(sendBtn).size(width: 36, height: 36)
            }
        }
    }
}

@MainActor enum S18 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style.alignItems = .center
        let chat = ChatFeedNode()
        root.addSubnode(chat)

        return ScenarioNodes.instance(
            .s18,
            root: root,
            inputs: "Messenger Chat Feed with incoming/outgoing bubbles, avatar rows & input bar",
            expected:
                "complex alignment (alignItems/alignSelf), variable bubble widths & nested layouts",
            paths: [
                "root",
                "root/chat",
                "root/chat/header",
                "root/chat/messages",
                "root/chat/inputBar",
            ]
        )
    }
}
