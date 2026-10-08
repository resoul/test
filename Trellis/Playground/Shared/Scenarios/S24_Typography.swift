import Foundation
import TrellisCore

/// First Playground scene with real `TextNode`s (T12) — S01–S23 never used one (plan-4 §1).
/// Five independent boxes, each isolating one contract this plan's text cards built:
/// mixed-run styling (D55/T04), paragraph alignment, RTL (D49's physical-edge resolution),
/// `maxLines`/tail truncation (D56/T05), and the empty-string edge case.
@MainActor enum S24 {
    private static func box(_ content: Node, height: Double? = nil) -> Node {
        let wrapper = ScenarioNodes.node("box", color: Palette.card)
        wrapper.style {
            $0.width = 288
            if let height { $0.height = .points(height) }
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            // `flexShrink = 0`: on a device screen (nativeBounds) root's own height is the real,
            // shorter viewport — unlike a Mac window's — so five stacked boxes plus the nav bar
            // can exceed it. Default flexShrink=1 would then compress every box below its
            // content's natural size, which for a text leaf doesn't just crop — it forces the
            // height-limit truncation branch (D56) or crushes to near-zero, exactly the S25
            // "TextListNode" mistake repeated per-box. Keeping natural size and letting genuine
            // overflow run past the visible screen (never clipped internally) is correct here;
            // an evidence screenshot showing the top boxes right and the last one off-screen is
            // honest, a bottom box silently rendering blank text is not.
            $0.flexShrink = 0
        }
        wrapper.addSubnode(content)
        return wrapper
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style { $0.gap = 12 }

        // 1. Mixed runs in one document: weight, point size, and color overrides (D55) — the
        // "bold word, bigger word, colored word" shape T04/T05 were built to measure and raster
        // through one `CTFrameDraw` pass, not three separate `TextNode`s pretending to be one
        // paragraph.
        var mixed = TextDocument("Regular, ")
        var bold = AttributedString("bold")
        bold.trellisText.weight = .bold
        mixed.append(bold)
        mixed.append(AttributedString(", "))
        var big = AttributedString("big")
        big.trellisText.pointSize = 28
        mixed.append(big)
        mixed.append(AttributedString(", and "))
        var colored = AttributedString("colored")
        colored.trellisText.color = Palette.orange
        mixed.append(colored)
        mixed.append(AttributedString(" runs, one document."))
        let styles = TextNode(document: mixed)
        root.addSubnode(box(styles))

        // 2. Paragraph alignment (leading/center/trailing) — each against the same fixed-width
        // box, so the difference is only `TextStyle.alignment`, not layout.
        let alignments = ScenarioNodes.node("alignments", color: Palette.card)
        alignments.style {
            $0.flexDirection = .column; $0.gap = 6; $0.width = 288
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            $0.flexShrink = 0
        }
        for (name, alignment) in [
            ("Leading", TextAlignment.leading), ("Center", .center), ("Trailing", .trailing),
        ] {
            let label = TextNode(text: name, textStyle: TextStyle(alignment: alignment))
            label.style.width = 264
            alignments.addSubnode(label)
        }
        root.addSubnode(alignments)

        // 3. RTL: physical alignment resolves against `LayoutDirection` (D49), not the string's
        // own script — `.leading` in a right-to-left node lands on the right edge, the same
        // physical-edge contract `LayoutStyle`'s own padding/margin already follow.
        let rtl = TextNode(
            text: "שלום עולם — hello in Hebrew",
            textStyle: TextStyle(alignment: .leading)
        )
        rtl.style.width = 264
        rtl.setLayoutDirection(.rightToLeft)
        root.addSubnode(box(rtl))

        // 4. `maxLines`/tail truncation (D56): a paragraph too long for two lines at this width
        // ends with a real CoreText-built ellipsis (T06), not a character-count guess (W01).
        let long = TextNode(
            text:
                "This paragraph is deliberately much longer than two lines can hold at this "
                + "column width, so the truncation policy below has real overflow to act on "
                + "instead of an edge case that never triggers.",
            maxLines: 2,
            truncation: .tail
        )
        long.style.width = 264
        root.addSubnode(box(long))

        // 5. Empty string (D55/T04 edge case): a `TextNode` with no characters must measure and
        // commit without crashing or producing a NaN/negative frame — shown next to a fixed-size
        // sibling so a regression (e.g. zero height collapsing the row) is visible, not just
        // "did it throw".
        let emptyRow = ScenarioNodes.node("emptyRow", color: Palette.card)
        emptyRow.style {
            $0.flexDirection = .row; $0.alignItems = .center; $0.gap = 8; $0.width = 288
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            $0.flexShrink = 0
        }
        let empty = TextNode(text: "")
        let marker = ScenarioNodes.fixed("marker", width: 12, height: 12, color: Palette.pink)
        emptyRow.addSubnode(empty)
        emptyRow.addSubnode(marker)
        root.addSubnode(emptyRow)

        return ScenarioNodes.instance(
            .s24,
            root: root,
            inputs:
                "mixed-run paragraph (bold/big/colored); three alignments; RTL string; "
                + "maxLines=2 + tail truncation on an overlong paragraph; empty-string TextNode",
            expected:
                "one CTFrameDraw pass renders all three run overrides in the first paragraph; "
                + "alignment box shows the three physical alignments; the RTL line's text hugs "
                + "the right edge; the long paragraph ends in an ellipsis at exactly two lines; "
                + "the empty TextNode commits with zero/near-zero width next to its marker, no crash",
            paths: [
                "root", "root/box(styles)", "root/alignments", "root/box(rtl)", "root/box(long)",
                "root/emptyRow",
            ]
        )
    }
}
