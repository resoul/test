#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import RichTextCore
    import StateCore
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Note: Node {
        let editor: RichTextEditor

        init(_ text: RichText = RichText()) {
            editor = RichTextEditor(text, placeholder: "Write")
            super.init()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { editor }
        }
    }

    @MainActor
    private func made(_ note: Note) -> (NodeView, RichEditorView) {
        let view = NodeView(root: note)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 800)
        for _ in 0..<5 {
            StateUpdates.flush()
            view.layoutIfNeeded()
        }
        return (view, view.embeddedView(of: note.editor.id) as! RichEditorView)
    }

    /// What the keyboard does: asks the delegate whether the change may go on, and makes it if so.
    /// (`insertText` called by code does not ask.)
    @MainActor private func type(_ string: String, in text: RichEditorView) {
        let allowed =
            text.delegate?.textView?(
                text,
                shouldChangeTextIn: text.selectedRange,
                replacementText: string
            )
            ?? true
        if allowed { text.insertText(string) }
    }

    private let site = URL(string: "https://example.com")!

    private let sample = RichText(
        blocks: [
            .paragraph([
                Run("plain "), Run("bold", marks: .bold), Run(" "), Run("link", link: site),
            ]),
            .quote([Run("quoted")]), .code("let a = 1", language: "swift"),
        ]
    )

    @Test @MainActor func theViewShowsTheStyledTextAndReadsItBackAsTheSameValue() {
        let note = Note(sample)
        let (view, text) = made(note)
        #expect(text.text == sample.platformText)
        #expect(text.model == sample)
        #expect(text.placeholderLabel.isHidden)
        view.host.detach()
    }

    @Test @MainActor func anEmptyEditorShowsItsPlaceholderAndTextSetByCodeReplacesTheContent() {
        let note = Note()
        let (view, text) = made(note)
        #expect(!text.placeholderLabel.isHidden)
        #expect(text.placeholderLabel.text == "Write")
        #expect(text.accessibilityIdentifier == "Write")

        var changes = 0
        note.editor.onChange = { _ in changes += 1 }
        note.editor.richText = sample
        StateUpdates.flush()
        view.layoutIfNeeded()
        #expect(text.model == sample)
        #expect(text.placeholderLabel.isHidden)
        #expect(changes == 0, "a change by code is not the user's")
        view.host.detach()
    }

    @Test @MainActor func whatTheUserTypesIsReadBackIntoTheNodeOnce() {
        let note = Note(RichText(blocks: [.paragraph([Run("ab", marks: .bold)])]))
        let (view, text) = made(note)
        var changes: [RichText] = []
        note.editor.onChange = { changes.append($0) }

        text.selectedRange = NSRange(location: 2, length: 0)
        text.insertText("c")
        #expect(note.editor.richText.plainText == "abc")
        #expect(changes.count == 1)
        #expect(changes[0] == note.editor.richText)
        // The node's own value coming back does not disturb what the view shows.
        StateUpdates.flush()
        #expect(text.text == "abc")
        #expect(text.selectedRange == NSRange(location: 3, length: 0))
        view.host.detach()
    }

    @Test @MainActor func textTypedAfterABoldWordIsBold() {
        let note = Note(RichText(blocks: [.paragraph([Run("ab", marks: .bold)])]))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 2, length: 0)
        text.insertText("c")
        #expect(note.editor.richText.blocks == [.paragraph([Run("abc", marks: .bold)])])
        view.host.detach()
    }

    @Test @MainActor func returnInAParagraphMakesANewParagraph() {
        let note = Note(RichText(plain: "ab"))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 1, length: 0)
        #expect(
            text.delegate?.textView?(
                text,
                shouldChangeTextIn: NSRange(location: 1, length: 0),
                replacementText: "\n"
            )
                == true
        )
        type("\n", in: text)
        #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .paragraph([Run("b")])])
        view.host.detach()
    }

    @Test @MainActor func returnInAQuoteAddsALineAndOnAnEmptyLastLineLeavesIt() {
        let note = Note(RichText(blocks: [.quote([Run("Quoted")])]))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 6, length: 0)

        type("\n", in: text)
        #expect(note.editor.richText.blocks == [.quote([Run("Quoted\n")])])
        #expect(text.selectedRange == NSRange(location: 7, length: 0))

        type("\n", in: text)
        #expect(note.editor.richText.blocks == [.quote([Run("Quoted")]), .paragraph([])])
        #expect(text.selectedRange == NSRange(location: 7, length: 0))

        type("x", in: text)
        #expect(note.editor.richText.blocks == [.quote([Run("Quoted")]), .paragraph([Run("x")])])
        view.host.detach()
    }

    @Test @MainActor func aLineBreakInsideAQuoteIsOneBlockOfTheModel() {
        let note = Note(RichText(blocks: [.quote([Run("a\nb")])]))
        let (view, text) = made(note)
        #expect(text.text == "a\u{2028}b")
        #expect(note.editor.richText.blocks == [.quote([Run("a\nb")])])
        view.host.detach()
    }

    @Test @MainActor func backspaceAtTheStartOfAQuoteOrCodeMakesItAParagraphAndKeepsTheText() {
        let note = Note(
            RichText(blocks: [
                .paragraph([Run("p")]), .quote([Run("q", marks: .bold)]), .code("c", language: nil),
            ])
        )
        let (view, text) = made(note)

        text.selectedRange = NSRange(location: 2, length: 0)
        text.deleteBackward()
        #expect(
            note.editor.richText.blocks == [
                .paragraph([Run("p")]), .paragraph([Run("q", marks: .bold)]),
                .code("c", language: nil),
            ]
        )
        #expect(text.selectedRange == NSRange(location: 2, length: 0))

        text.selectedRange = NSRange(location: 4, length: 0)
        text.deleteBackward()
        #expect(note.editor.richText.blocks[2] == .paragraph([Run("c")]))
        view.host.detach()
    }

    @Test @MainActor func backspaceAtTheStartOfAParagraphJoinsItToTheBlockAbove() {
        let note = Note(RichText(blocks: [.quote([Run("q")]), .paragraph([Run("p")])]))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 2, length: 0)
        text.deleteBackward()
        #expect(note.editor.richText.blocks == [.quote([Run("qp")])])
        view.host.detach()
    }

    @Test @MainActor func aChangeMadeByTheRulesCanBeUndoneAndRedone() throws {
        let note = Note(RichText(blocks: [.quote([Run("Quoted")])]))
        let (view, text) = made(note)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        text.selectedRange = NSRange(location: 6, length: 0)

        undo.beginUndoGrouping()
        type("\n", in: text)
        undo.endUndoGrouping()
        #expect(note.editor.richText.blocks == [.quote([Run("Quoted\n")])])

        undo.undo()
        #expect(note.editor.richText.blocks == [.quote([Run("Quoted")])])
        #expect(text.selectedRange == NSRange(location: 6, length: 0))

        undo.redo()
        #expect(note.editor.richText.blocks == [.quote([Run("Quoted\n")])])
        view.host.detach()
    }

    @Test @MainActor func aWordBeingComposedIsNotTheTextYet() {
        let note = Note(RichText(plain: "ab"))
        let (view, text) = made(note)
        var changes: [RichText] = []
        note.editor.onChange = { changes.append($0) }
        text.selectedRange = NSRange(location: 2, length: 0)

        text.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0))
        text.delegate?.textViewDidChange?(text)
        #expect(changes.isEmpty)
        #expect(note.editor.richText.plainText == "ab")

        text.unmarkText()
        text.delegate?.textViewDidChange?(text)
        #expect(changes.count == 1)
        #expect(note.editor.richText.plainText == "abka")
        view.host.detach()
    }

    @Test @MainActor func theEditorIsItsLeastLinesHighAndGrowsWithItsText() {
        let note = Note()
        note.editor.minLines = 2
        note.editor.maxLines = 5
        let (view, text) = made(note)
        let metrics = text.lineMetrics(width: 300)
        #expect(
            abs(note.editor.preferredSize.height - (metrics.lineHeight * 2 + metrics.insets)) < 2
        )

        note.editor.richText = RichText(
            blocks: (0..<12).map { _ in .paragraph([Run("line")]) }
        )
        for _ in 0..<5 {
            StateUpdates.flush()
            view.layoutIfNeeded()
        }
        #expect(
            abs(note.editor.preferredSize.height - (metrics.lineHeight * 5 + metrics.insets)) < 12
        )
        #expect(text.isScrollEnabled)
        view.host.detach()
    }
#endif
