import TrellisCore

/// R09 consumer page: a long article has its own vertical reader and an inline horizontal
/// gallery of short editorial cards. The horizontal rail must keep its axis while the article
/// remains independently scrollable above and below it.
@MainActor enum S34 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let article = ScrollNode()
        article.configuration.axis = .vertical
        article.style {
            $0.flexDirection = .column
            $0.gap = 18
            $0.width = .fraction(1)
            $0.flexGrow = 1
            $0.flexShrink = 1
            $0.padding = DirectionalEdgeInsets(top: 20, leading: 20, bottom: 24, trailing: 20)
        }

        article.addSubnode(
            paragraph(
                "A city is easiest to read at walking pace. Streets that look interchangeable on a map "
                    + "begin to show their own rhythm when the shopfronts, trees, and small detours "
                    + "are allowed to tell the story.",
                pointSize: 17,
                height: 124
            )
        )

        let gallery = ScrollNode()
        gallery.configuration.axis = .horizontal
        gallery.style {
            $0.flexDirection = .row
            $0.gap = 12
            $0.width = .fraction(1)
            $0.height = .points(150)
            $0.flexShrink = 0
        }
        for (title, color) in [
            ("The old arcade", Palette.blue),
            ("A market at noon", Palette.purple),
            ("Along the canal", Palette.green),
            ("The last bookshop", Palette.orange),
        ] {
            let card = TextNode(
                text: title,
                textStyle: TextStyle(
                    pointSize: 18,
                    weight: .semibold,
                    color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
                )
            )
            card.appearance.background = .color(color)
            card.style {
                $0.width = .points(210)
                $0.height = .points(150)
                $0.padding = DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
                $0.flexShrink = 0
            }
            gallery.addSubnode(card)
        }
        article.addSubnode(gallery)

        article.addSubnode(
            paragraph(
                "The route continues beyond the gallery. Local histories sit beside present-day "
                    + "voices, so a reader can move through the article without losing the place "
                    + "where a detail first appeared.",
                pointSize: 17,
                height: 156
            )
        )
        article.addSubnode(
            paragraph(
                "At the end of the walk, the view opens onto the river. The article is long enough "
                    + "to scroll on its own, while the cards form a separate horizontal strip inside it.",
                pointSize: 17,
                height: 144
            )
        )
        root.addSubnode(article)

        return ScenarioNodes.instance(
            .s34,
            root: root,
            inputs: "vertical article ScrollNode with nested horizontal gallery of four text cards",
            expected:
                "horizontal drags stay in the gallery; vertical drags scroll the article; at boundaries one gesture has one scroll owner",
            paths: ["root/article", "root/article/gallery"]
        )
    }

    private static func paragraph(_ text: String, pointSize: Double, height: Double) -> TextNode {
        let node = TextNode(
            text: text,
            textStyle: TextStyle(
                pointSize: pointSize,
                weight: .regular,
                color: ThemeColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1)
            )
        )
        node.style {
            $0.width = .fraction(1)
            $0.height = .points(height)
            $0.flexShrink = 0
        }
        return node
    }
}
