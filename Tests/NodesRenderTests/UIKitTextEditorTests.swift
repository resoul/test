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

    @MainActor
    private final class Filler: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 500)) }
    }

    /// A page taller than the view, the editor at its end, in a scroll. The room the keyboard
    /// takes is the page's own: the view follows the system's keyboard, which a test has none
    /// of, and the mechanics under test do not depend on where the number comes from.
    @MainActor
    private final class Page: Node {
        let filler = Filler()
        let editor = TextEditor(placeholder: "Notes")
        let keyboard = State(0.0)
        lazy var scroll = Scroll(.vertical, content: Content(page: self))

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll.flex(grow: 1, shrink: 1) }
                .padding(bottom: keyboard.value)
        }
    }

    @MainActor
    private final class Content: Node {
        unowned let page: Page

        init(page: Page) {
            self.page = page
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                page.filler
                page.editor
            }
            .padding(10)
        }
    }

    @Test @MainActor
    func anEditorBeingEditedIsKeptAboveTheKeyboardAsItGrows() throws {
        let page = Page()
        page.editor.minLines = 1
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let view = NodeView(root: page)
        view.zoom = 1
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        settle(view)

        let frame = { () -> LayoutRect? in
            view.host.embeddedItems().first { $0.node === page.editor }?.frame
        }
        // The keyboard is up, over the bottom 300, and then the editor takes it, as when a field
        // is touched.
        page.keyboard.value = 300
        settle(view)
        page.editor.beginEditing()
        settle(view)
        let before = try #require(frame())
        #expect(page.editor.isEditing)
        #expect(before.origin.y + before.size.height <= 300 + 0.5)

        // Six more lines: the editor is taller, and its end is still above the keyboard.
        page.editor.text = Array(repeating: "line", count: 7).joined(separator: "\n")
        settle(view)
        let after = try #require(frame())
        #expect(after.size.height > before.size.height + 60)
        #expect(after.origin.y + after.size.height <= 300 + 0.5)
        view.host.detach()
        window.isHidden = true
    }
#endif
