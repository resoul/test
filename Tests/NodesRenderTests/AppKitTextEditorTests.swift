#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import Testing

    @testable import NodesAppKit

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
    private func view(of notes: Notes) -> NodeNSView {
        let view = NodeNSView(root: notes)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 800)
        settle(view)
        return view
    }

    @MainActor
    private func settle(_ view: NodeNSView) {
        for _ in 0..<6 {
            StateUpdates.flush()
            view.layout()
        }
    }

    @MainActor
    private func scroll(of notes: Notes, in view: NodeNSView) throws -> EditorScrollView {
        try #require(view.embeddedView(of: notes.editor.id) as? EditorScrollView)
    }

    private func lines(_ count: Int) -> String {
        Array(repeating: "line", count: count).joined(separator: "\n")
    }

    @Test @MainActor
    func anEmptyEditorShowsItsPlaceholderAndTheNodeTakesItsLeastLinesHeight() throws {
        let notes = Notes()
        let view = view(of: notes)
        let scroll = try scroll(of: notes, in: view)

        #expect(!scroll.placeholderLabel.isHidden)
        #expect(scroll.placeholderLabel.stringValue == "Notes")
        #expect(scroll.textView.accessibilityIdentifier() == "Notes")
        let least = notes.editor.preferredSize.height
        // Three lines of the text view's own spacing, and its insets.
        let metrics = scroll.lineMetrics()
        #expect(abs(least - (metrics.lineHeight * 3 + metrics.insets)) < 1)
        #expect(!scroll.hasVerticalScroller)

        notes.editor.text = "Something"
        settle(view)
        #expect(scroll.placeholderLabel.isHidden)
        view.host.detach()
    }

    @Test @MainActor
    func theEditorGrowsWithItsTextUpToItsMostLinesAndScrollsBeyond() throws {
        let notes = Notes()
        notes.editor.minLines = 2
        notes.editor.maxLines = 5
        let view = view(of: notes)
        let scroll = try scroll(of: notes, in: view)
        let least = notes.editor.preferredSize.height

        notes.editor.text = lines(4)
        settle(view)
        let four = notes.editor.preferredSize.height
        #expect(four > least)
        #expect(!scroll.hasVerticalScroller)

        notes.editor.text = lines(12)
        settle(view)
        let most = notes.editor.preferredSize.height
        #expect(most > four)
        #expect(scroll.hasVerticalScroller)
        notes.editor.text = lines(30)
        settle(view)
        #expect(notes.editor.preferredSize.height == most)

        notes.editor.text = "one line"
        settle(view)
        #expect(notes.editor.preferredSize.height == least)
        #expect(!scroll.hasVerticalScroller)
        view.host.detach()
    }

    @Test @MainActor
    func whatIsTypedBeyondTheLimitIsCutInTheViewAsInTheEditor() throws {
        let notes = Notes()
        notes.editor.maxLength = 5
        let view = view(of: notes)
        let scroll = try scroll(of: notes, in: view)
        var changes: [String] = []
        notes.editor.onChange = { changes.append($0) }

        scroll.textView.string = "abcdefgh"
        scroll.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(scroll.textView.string == "abcde")
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
    func aTextFieldCutsWhatIsTypedToItsLimit() throws {
        let boxed = Boxed()
        boxed.field.maxLength = 3
        let view = NodeNSView(root: boxed)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        view.layout()
        view.layout()
        let text = try #require(view.embeddedView(of: boxed.field.id) as? NSTextField)

        text.stringValue = "123456"
        (text.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: text)
        )
        #expect(text.stringValue == "123")
        #expect(boxed.field.text == "123")
        view.host.detach()
    }
#endif
