import TrellisCore

/// M06/M08's scenario: `list.animate(_:) { description.maxLines = ... }` (implementation-
/// plan-5.md §1's own worked example, originally written `.smooth`) — one card's description
/// grows past two lines, and the cards below it shift down in the same transition, since the
/// scope owner is the shared list (`root`), not the individual card (D62: siblings outside a
/// scope snap, D63's "list.animate even if only the description changes"). M09 switched the
/// timing to `.snappy` — a real `CASpringAnimation`, the press/disclosure preset it was tuned
/// against — without touching this scope contract at all: D62/D63 are about the closure's
/// *scope*, orthogonal to which `Animation` value drives it. `pressCount`/`hint` are static
/// per-card signals of what happened (S21's own convention) — the transition itself is native
/// evidence, not something a single screenshot can show.
final class DisclosureCardNode: ControlNode {
    private let list: Node
    let title: TextNode
    let description: TextNode
    private let hint: TextNode
    private(set) var isExpanded = false
    private(set) var pressCount = 0

    init(list: Node, title: String, body: String) {
        self.list = list
        self.title = TextNode(
            text: title,
            textStyle: TextStyle(pointSize: 15, weight: .bold)
        )
        description = TextNode(
            text: body,
            textStyle: TextStyle(pointSize: 13, color: Palette.textSecondary),
            maxLines: 2,
            truncation: .tail
        )
        hint = TextNode(
            text: "Tap to expand",
            textStyle: TextStyle(pointSize: 11, weight: .medium, color: Palette.cyan)
        )
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style {
            $0.flexDirection = .column
            $0.gap = 4
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        }
        addSubnode(self.title)
        addSubnode(description)
        addSubnode(hint)
        activation = { [weak self] in self?.toggle() }
    }

    private func toggle() {
        pressCount += 1
        isExpanded.toggle()
        let expanded = isExpanded
        hint.text = expanded ? "Tap to collapse" : "Tap to expand"
        // The scope is `list`, not `self`: this card grows in place and every card below it
        // must shift down in the same transition, which only a common-ancestor scope covers
        // (D62) — animating `self` here would move this card's own content smoothly but snap
        // its siblings, the exact distinction D63's scope table exists to make explicit.
        // `.snappy` (M09): this is exactly the press/disclosure interaction the preset was
        // tuned against — a real `CASpringAnimation`, not `.smooth`'s fixed ease-in-out.
        list.animate(.snappy) {
            self.description.maxLines = expanded ? nil : 2
        }
    }
}

@MainActor enum S27 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.flexDirection = .column; $0.gap = 12
        }

        let cards = [
            (
                "Card 1",
                "Short teaser line that already fits on one line."
            ),
            (
                "Card 2",
                "A longer description that wraps onto more than two lines once expanded, "
                    + "so the difference between collapsed and expanded is visible rather than "
                    + "a one-word truncation edge case."
            ),
            (
                "Card 3",
                "A third paragraph about something else entirely, also long enough to "
                    + "truncate at two lines by default and reveal the rest on tap."
            ),
        ].map { title, body in DisclosureCardNode(list: root, title: title, body: body) }
        for card in cards { root.addSubnode(card) }

        return ScenarioNodes.instance(
            .s27,
            root: root,
            inputs: "3 disclosure cards in a column; each description starts at maxLines=2",
            expected:
                "tapping a card's own control animates `list.animate(.snappy)` (M09 spring): its description "
                + "grows to its full natural height and every card below it shifts down in the "
                + "same transition (D62 scope), not just the tapped card; the raster clears "
                + "immediately on the maxLines change and a fresh one lands without stretching "
                + "the old bitmap (D65); a second tap before the first transition settles "
                + "retargets from the live value, not the pre-press one (D66)",
            paths: ["root", "root/card0", "root/card1", "root/card2"]
        )
    }
}
