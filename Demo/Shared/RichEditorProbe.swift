import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import RichTextCore

/// `RICH_EDITOR_PROBE=1` for UI tests of the rich text editor: the editor, and a line that
/// shows what it holds as Markdown after each change. `RICH_EDITOR_QUOTE=1` starts with a
/// quote "Quoted"; `RICH_EDITOR_SAMPLE=1` with a paragraph, a quote, code and another quote, to
/// look at how blocks are drawn; otherwise with the paragraph "Start".
@MainActor
enum RichEditorProbe {
    static func content(quote: Bool, sample: Bool = false) -> any SceneContent {
        NodeScreen(Page(quote: quote, sample: sample), title: "Rich editor")
    }

    private final class Page: Node {
        let editor: RichTextEditor
        let markdown: Text
        /// The same text as `Text` draws it, under the editor: what the blocks should look like.
        let reference: Text?

        init(quote: Bool, sample: Bool) {
            let start =
                sample
                ? RichText(blocks: [
                    .paragraph([Run("Plain "), Run("bold", marks: .bold), Run(" text.")]),
                    .quote([Run("A quotation over\ntwo lines.")]),
                    .quote([Run("Another one.")]),
                    .code("let a = 1\nlet b = 2", language: "swift"),
                    .paragraph([Run("After the code.")]),
                ])
                : quote
                ? RichText(blocks: [.quote([Run("Quoted")])])
                : RichText(blocks: [.paragraph([Run("Start")])])
            editor = RichTextEditor(start, placeholder: "Write here")
            markdown = Text("MD:" + start.markdown, style: TextStyle(size: 17))
            reference = sample ? Text(rich: start, style: TextStyle(size: 17)) : nil
            super.init()
            editor.onChange = { [weak self] text in
                self?.markdown.text = "MD:" + text.markdown
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                editor
                markdown
                if let reference { reference }
            }
            .gap(16)
            .padding(24)
            .alignItems(.stretch)
        }
    }
}
