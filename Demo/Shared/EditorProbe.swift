import AppShell
import LayoutCore
import Nodes
import NodesRender

/// A screen of `EDITOR_PROBE=1` for UI tests of the multi-line editor: notes that grow from two
/// lines to four and scroll beyond, a line saying how many characters they hold, and a code
/// field that takes four characters at most, with a line saying what it holds. With
/// `EDITOR_LOW=1` the notes stand low in a scroll, where the keyboard would cover them.
@MainActor
enum EditorProbe {
    static func content(low: Bool = false) -> any SceneContent {
        NodeScreen(Page(low: low), title: "Editor")
    }

    private final class Page: Node {
        let notes = TextEditor(placeholder: "Notes")
        let code = TextField(placeholder: "Code", content: .oneTimeCode)
        let notesLength = Text("Notes: 0 characters", style: TextStyle(size: 17))
        let codeValue = Text("Code: none", style: TextStyle(size: 17))

        let low: Bool
        lazy var scroll = Scroll(.vertical, content: Below(page: self))

        init(low: Bool) {
            self.low = low
            super.init()
            // The notes standing low grow by five lines, more than the room the keyboard's
            // scroll leaves under them.
            notes.minLines = low ? 1 : 2
            notes.maxLines = low ? 6 : 4
            code.maxLength = 4
            code.clearButton = .whileEditing
            notes.onChange = { [weak self] text in
                self?.notesLength.text = "Notes: \(text.count) characters"
            }
            code.onChange = { [weak self] text in
                self?.codeValue.text = "Code: \(text)"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            guard low else {
                return FlexContainer(.column) {
                    notes
                    notesLength
                    code
                    codeValue
                }
                .gap(16)
                .padding(24)
            }

            // The keyboard shortens the page from below; the scroll shows what is above it.
            return FlexContainer(.column) { scroll.flex(grow: 1, shrink: 1) }
                .padding(bottom: keyboardInset)
        }
    }

    /// The notes after room enough to put them where the keyboard comes.
    private final class Below: Node {
        unowned let page: Page
        let room = Room()

        init(page: Page) {
            self.page = page
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                room.size(width: 50, height: 560)
                page.notes
                page.notesLength
                page.code
                page.codeValue
            }
            .gap(16)
            .padding(24)
        }
    }

    private final class Room: Node {}
}
