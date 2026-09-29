#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Notes: Node {
        let editor = TextEditor(placeholder: "Notes")

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { editor }
        }
    }

    /// A 300-point-wide view of the notes, laid out until the editor's height settles: the
    /// editor tells its size once its view is made, and again as its text is laid out.
    @MainActor
    private func view(of notes: Notes) -> NodeView {
        let view = NodeView(root: notes)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 800)
        settle(view)
        return view
    }

    @MainActor
    private func settle(_ view: NodeView) {
        for _ in 0..<5 {
            StateUpdates.flush()
            view.layoutIfNeeded()
        }
    }

    @MainActor
    private func textView(of notes: Notes, in view: NodeView) throws -> EditorView {
        try #require(view.embeddedView(of: notes.editor.id) as? EditorView)
    }

    /// The height of `lines` lines in `text`, as the text view spaces them: one line and two,
    /// measured.
    @MainActor
    private func height(of lines: Int, in text: EditorView) -> Double {
        let metrics = text.lineMetrics(width: 300)
        return metrics.lineHeight * Double(lines) + metrics.insets
    }

    @Test @MainActor
    func anEmptyEditorIsItsLeastLinesHighAndShowsItsPlaceholder() throws {
        let notes = Notes()
        let view = view(of: notes)
        let text = try textView(of: notes, in: view)

        #expect(abs(notes.editor.preferredSize.height - height(of: 3, in: text)) < 2)
        #expect(!text.placeholderLabel.isHidden)
        #expect(text.placeholderLabel.text == "Notes")
        #expect(text.accessibilityIdentifier == "Notes")
        #expect(!text.isScrollEnabled)

        notes.editor.text = "Something"
        settle(view)
        #expect(text.placeholderLabel.isHidden)
        view.host.detach()
    }

    @Test @MainActor
    func theEditorGrowsWithItsTextUpToItsMostLinesAndScrollsBeyond() throws {
        let notes = Notes()
        notes.editor.minLines = 2
        notes.editor.maxLines = 5
        let view = view(of: notes)
        let text = try textView(of: notes, in: view)

        notes.editor.text = Array(repeating: "line", count: 4).joined(separator: "\n")
        settle(view)
        #expect(abs(notes.editor.preferredSize.height - height(of: 4, in: text)) < 2)
        #expect(!text.isScrollEnabled)

        notes.editor.text = Array(repeating: "line", count: 12).joined(separator: "\n")
        settle(view)
        #expect(abs(notes.editor.preferredSize.height - height(of: 5, in: text)) < 2)
        #expect(text.isScrollEnabled)

        notes.editor.text = "one line"
        settle(view)
        #expect(abs(notes.editor.preferredSize.height - height(of: 2, in: text)) < 2)
        #expect(!text.isScrollEnabled)
        view.host.detach()
    }

    @Test @MainActor
    func whatIsTypedBeyondTheLimitIsCutInTheViewAsInTheEditor() throws {
        let notes = Notes()
        notes.editor.maxLength = 5
        let view = view(of: notes)
        let text = try textView(of: notes, in: view)
        var changes: [String] = []
        notes.editor.onChange = { changes.append($0) }

        text.text = "abcdefgh"
        text.delegate?.textViewDidChange?(text)
        #expect(text.text == "abcde")
        #expect(notes.editor.text == "abcde")
        #expect(changes == ["abcde"])
        view.host.detach()
    }

    @MainActor
    private final class Boxed: Node {
        let field = TextField(placeholder: "Search")

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { field }
        }
    }

    @Test @MainActor
    func aTextFieldCutsWhatIsTypedAndShowsItsClearButton() throws {
        let boxed = Boxed()
        boxed.field.maxLength = 3
        boxed.field.clearButton = .whileEditing
        let view = NodeView(root: boxed)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        view.layoutIfNeeded()
        let text = try #require(view.embeddedView(of: boxed.field.id) as? UITextField)
        #expect(text.clearButtonMode == .whileEditing)

        text.text = "123456"
        (text as? FieldView)?.changed()
        #expect(text.text == "123")
        #expect(boxed.field.text == "123")
        view.host.detach()
    }
#endif
