import TrellisCore

/// Visible captions for a sample of S22/S23's accessibility elements (T12) — those two scenes
/// prove VoiceOver/native AX *hears* the right thing (A11), entirely through colored
/// placeholder rectangles and `accessibility.label`/`.value`, with no `TextNode` anywhere (S23's
/// own `expected` says so explicitly). This scene reuses their exact node classes unmodified —
/// `FocusCardNode`/`SelectableCardNode`/`VolumeCardNode` are `internal`, so this file can
/// construct them directly — and adds a real `TextNode` caption next to each, so a sighted
/// reviewer can also *see* what the label says, without touching S22/S23's own trees or
/// invalidating their existing screenshot references.
@MainActor enum S26 {
    private static func caption(_ text: String, width: Double) -> TextNode {
        // Explicit width, not auto: defect #48 (defects.md) — an auto-width leaf centered
        // (non-stretch) under a real UIKit host can measure a knife-edge natural width that
        // CoreText's own raster pass then can't quite fit on one line, truncating text a
        // correct measurement said would fit. S24's alignment labels already sidestep the same
        // auto-width class with an explicit `style.width`; captions do the same here so this
        // scene's evidence isn't obscured by an unrelated, already-filed defect. Width is wide
        // enough for each caption's own text to stay on one line — not a shared constant — so
        // no caption here exercises wrap/truncation, which isn't what this scene is about.
        let node = TextNode(
            text: text,
            textStyle: TextStyle(pointSize: 13, color: Palette.textSecondary)
        )
        node.style.width = .points(width)
        return node
    }

    private static func labeled(_ content: Node, caption text: String, captionWidth: Double) -> Node
    {
        let column = ScenarioNodes.node("labeled", color: Palette.card)
        column.style {
            $0.flexDirection = .column; $0.alignItems = .center; $0.gap = 6
            $0.padding = DirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            // See S24_Typography.box's comment: on a device screen root's own height is the
            // real, shorter viewport, so this column plus its siblings can exceed it — without
            // this, default flexShrink=1 crushes the caption (and can blank it) to force a fit
            // that a Mac window's taller root never needed.
            $0.flexShrink = 0
        }
        column.addSubnode(content)
        column.addSubnode(caption(text, width: captionWidth))
        return column
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style { $0.gap = 12 }

        // S22: two focus-grid cards with their `accessibility.label` shown underneath.
        let focusRow = ScenarioNodes.node("focusRow", color: Palette.card)
        focusRow.style {
            $0.flexDirection = .row; $0.gap = 12; $0.justifyContent = .center
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            $0.flexShrink = 0
        }
        let cardOne = FocusCardNode(label: "Card 1", color: Palette.blue)
        let cardTwo = FocusCardNode(label: "Card 2", color: Palette.green)
        focusRow.addSubnode(labeled(cardOne, caption: "Card 1", captionWidth: 90))
        focusRow.addSubnode(labeled(cardTwo, caption: "Card 2", captionWidth: 90))
        root.addSubnode(focusRow)

        // S23: the selectable and adjustable cards, each with a caption describing what
        // VoiceOver reads for it (label, and for the adjustable card, its role).
        let selectable = SelectableCardNode()
        root.addSubnode(
            labeled(selectable, caption: "Notifications (toggles selected)", captionWidth: 240)
        )

        let volume = VolumeCardNode()
        root.addSubnode(labeled(volume, caption: "Volume, adjustable 0 to 10", captionWidth: 240))

        return ScenarioNodes.instance(
            .s26,
            root: root,
            inputs:
                "S22's FocusCardNode ×2 and S23's SelectableCardNode/VolumeCardNode, unmodified, "
                + "each with a TextNode caption showing its accessibility label",
            expected:
                "every caption's text matches the VoiceOver label of the element above it; "
                + "S22/S23 themselves are untouched — their own screenshots are unaffected by this scene",
            paths: ["root", "root/focusRow", "root/labeled(selectable)", "root/labeled(volume)"]
        )
    }
}
