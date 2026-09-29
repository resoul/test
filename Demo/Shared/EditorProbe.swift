import AppShell
import LayoutCore
import Nodes
import NodesRender

/// A screen of `EDITOR_PROBE=1` for UI tests of the multi-line editor: notes that grow from two
/// lines to four and scroll beyond, a line saying how many characters they hold, and a code
/// field that takes four characters at most, with a line saying what it holds.
@MainActor
enum EditorProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Editor")
    }

    private final class Page: Node {
        let notes = TextEditor(placeholder: "Notes")
        let code = TextField(placeholder: "Code", content: .oneTimeCode)
        let notesLength = Text("Notes: 0 characters", style: TextStyle(size: 17))
        let codeValue = Text("Code: none", style: TextStyle(size: 17))

        override init() {
            super.init()
            notes.minLines = 2
            notes.maxLines = 4
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
            FlexContainer(.column) {
                notes
                notesLength
                code
                codeValue
            }
            .gap(16)
            .padding(24)
        }
    }
}
