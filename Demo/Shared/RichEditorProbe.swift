import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import RichTextCore

/// `RICH_EDITOR_PROBE=1` for UI tests of the rich text editor: the editor, and a line that
/// shows what it holds as Markdown after each change. `RICH_EDITOR_QUOTE=1` starts with a
/// quote "Quoted"; otherwise with the paragraph "Start".
@MainActor
enum RichEditorProbe {
    static func content(quote: Bool) -> any SceneContent {
        NodeScreen(Page(quote: quote), title: "Rich editor")
    }

    private final class Page: Node {
        let editor: RichTextEditor
        let markdown: Text

        init(quote: Bool) {
            let start =
                quote
                ? RichText(blocks: [.quote([Run("Quoted")])])
                : RichText(blocks: [.paragraph([Run("Start")])])
            editor = RichTextEditor(start, placeholder: "Write here")
            markdown = Text("MD:" + start.markdown, style: TextStyle(size: 17))
            super.init()
            editor.onChange = { [weak self] text in
                self?.markdown.text = "MD:" + text.markdown
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                editor
                markdown
            }
            .gap(16)
            .padding(24)
            .alignItems(.stretch)
        }
    }
}
