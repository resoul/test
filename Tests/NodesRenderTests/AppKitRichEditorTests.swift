#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import RichTextCore
    import StateCore
    import Testing

    @testable import NodesAppKit

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

    /// A 300-point-wide view of the note in a window that never shows, laid out until the
    /// editor's height settles.
    @MainActor
    private func made(_ note: Note) -> (NodeNSView, RichEditorTextView, NSWindow) {
        let view = NodeNSView(root: note)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 800)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        for _ in 0..<6 {
            StateUpdates.flush()
            view.layout()
        }
        let scroll = view.embeddedView(of: note.editor.id) as! RichEditorScrollView
        return (view, scroll.textView, window)
    }

    /// What the keyboard does.
    @MainActor private func type(_ string: String, in text: RichEditorTextView) {
        text.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private let site = URL(string: "https://example.com")!

    @MainActor private func keyEvent(
        _ characters: String,
        _ flags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Suite(.serialized) @MainActor struct AppKitRichEditorTests {
        private let sample = RichText(
            blocks: [
                .paragraph([
                    Run("plain "), Run("bold", marks: .bold), Run(" "), Run("link", link: site),
                ]),
                .quote([Run("quoted")]), .code("let a = 1", language: "swift"),
            ]
        )

        @Test func theViewShowsTheStyledTextAndReadsItBackAsTheSameValue() {
            let note = Note(sample)
            let (view, text, _) = made(note)
            #expect(text.string == sample.platformText)
            #expect(text.model == sample)
            view.host.detach()
        }

        @Test func anEmptyEditorShowsItsPlaceholderAndTextSetByCodeReplacesTheContent() throws {
            let note = Note()
            let (view, text, _) = made(note)
            let scroll = try #require(text.enclosingScrollView as? RichEditorScrollView)
            #expect(!scroll.placeholderLabel.isHidden)
            #expect(scroll.placeholderLabel.stringValue == "Write")
            #expect(text.accessibilityIdentifier() == "Write")

            var changes = 0
            note.editor.onChange = { _ in changes += 1 }
            note.editor.richText = sample
            for _ in 0..<4 {
                StateUpdates.flush()
                view.layout()
            }
            #expect(text.model == sample)
            #expect(scroll.placeholderLabel.isHidden)
            #expect(changes == 0, "a change by code is not the user's")
            view.host.detach()
        }

        @Test func whatTheUserTypesIsReadBackIntoTheNodeOnce() {
            let note = Note(RichText(blocks: [.paragraph([Run("ab", marks: .bold)])]))
            let (view, text, _) = made(note)
            var changes: [RichText] = []
            note.editor.onChange = { changes.append($0) }

            text.setSelectedRange(NSRange(location: 2, length: 0))
            type("c", in: text)
            #expect(note.editor.richText.blocks == [.paragraph([Run("abc", marks: .bold)])])
            #expect(changes.count == 1)
            StateUpdates.flush()
            #expect(text.string == "abc")
            #expect(text.selectedRange() == NSRange(location: 3, length: 0))
            view.host.detach()
        }

        @Test func returnInAParagraphMakesANewParagraph() {
            let note = Note(RichText(plain: "ab"))
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 1, length: 0))
            text.insertNewline(nil)
            #expect(
                note.editor.richText.blocks == [.paragraph([Run("a")]), .paragraph([Run("b")])]
            )
            view.host.detach()
        }

        @Test func returnInAQuoteAddsALineAndOnAnEmptyLastLineLeavesIt() {
            let note = Note(RichText(blocks: [.quote([Run("Quoted")])]))
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 6, length: 0))

            text.insertNewline(nil)
            #expect(note.editor.richText.blocks == [.quote([Run("Quoted\n")])])
            #expect(text.selectedRange() == NSRange(location: 7, length: 0))

            text.insertNewline(nil)
            #expect(note.editor.richText.blocks == [.quote([Run("Quoted")]), .paragraph([])])
            #expect(text.selectedRange() == NSRange(location: 7, length: 0))

            type("x", in: text)
            #expect(
                note.editor.richText.blocks == [.quote([Run("Quoted")]), .paragraph([Run("x")])]
            )
            view.host.detach()
        }

        @Test func backspaceAtTheStartOfAQuoteOrCodeMakesItAParagraphAndKeepsTheText() {
            let note = Note(
                RichText(blocks: [
                    .paragraph([Run("p")]), .quote([Run("q", marks: .bold)]),
                    .code("c", language: nil),
                ])
            )
            let (view, text, _) = made(note)

            text.setSelectedRange(NSRange(location: 2, length: 0))
            text.deleteBackward(nil)
            #expect(
                note.editor.richText.blocks == [
                    .paragraph([Run("p")]), .paragraph([Run("q", marks: .bold)]),
                    .code("c", language: nil),
                ]
            )
            text.setSelectedRange(NSRange(location: 4, length: 0))
            text.deleteBackward(nil)
            #expect(note.editor.richText.blocks[2] == .paragraph([Run("c")]))
            view.host.detach()
        }

        @Test func backspaceAtTheStartOfAParagraphJoinsItToTheBlockAbove() {
            let note = Note(RichText(blocks: [.quote([Run("q")]), .paragraph([Run("p")])]))
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 2, length: 0))
            text.deleteBackward(nil)
            #expect(note.editor.richText.blocks == [.quote([Run("qp")])])
            view.host.detach()
        }

        @Test func aWordBeingComposedIsNotTheTextYet() {
            let note = Note(RichText(plain: "ab"))
            let (view, text, _) = made(note)
            var changes: [RichText] = []
            note.editor.onChange = { changes.append($0) }
            text.setSelectedRange(NSRange(location: 2, length: 0))

            text.setMarkedText(
                "ka",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            #expect(changes.isEmpty)
            #expect(note.editor.richText.plainText == "ab")

            text.unmarkText()
            text.didChangeText()
            #expect(changes.count == 1)
            #expect(note.editor.richText.plainText == "abka")
            view.host.detach()
        }

        // MARK: Undo

        @Test func aChangeMadeByTheRulesCanBeUndoneAndRedone() throws {
            let note = Note(RichText(blocks: [.quote([Run("Quoted")])]))
            let (view, text, _) = made(note)
            let undo = try #require(text.undoManager)
            undo.groupsByEvent = false
            text.setSelectedRange(NSRange(location: 6, length: 0))

            undo.beginUndoGrouping()
            text.insertNewline(nil)
            undo.endUndoGrouping()
            #expect(note.editor.richText.blocks == [.quote([Run("Quoted\n")])])

            undo.undo()
            #expect(note.editor.richText.blocks == [.quote([Run("Quoted")])])
            #expect(text.selectedRange() == NSRange(location: 6, length: 0))

            undo.redo()
            #expect(note.editor.richText.blocks == [.quote([Run("Quoted\n")])])
            view.host.detach()
        }

        // MARK: Formats

        @Test func aMarkFormatMarksTheSelectionAndOneUndoTakesItBack() throws {
            let note = Note(RichText(plain: "abcd"))
            let (view, text, _) = made(note)
            let undo = try #require(text.undoManager)
            undo.groupsByEvent = false
            text.setSelectedRange(NSRange(location: 1, length: 2))
            #expect(text.isAvailable(.bold))
            #expect(!text.isOn(.bold))

            undo.beginUndoGrouping()
            text.perform(.bold)
            undo.endUndoGrouping()
            #expect(
                note.editor.richText.blocks == [
                    .paragraph([Run("a"), Run("bc", marks: .bold), Run("d")])
                ]
            )
            #expect(text.selectedRange() == NSRange(location: 1, length: 2))
            #expect(text.isOn(.bold))
            #expect(undo.undoActionName == "Bold")

            undo.undo()
            #expect(note.editor.richText.blocks == [.paragraph([Run("abcd")])])
            undo.redo()
            #expect(
                note.editor.richText.blocks == [
                    .paragraph([Run("a"), Run("bc", marks: .bold), Run("d")])
                ]
            )
            view.host.detach()
        }

        @Test func aMarkAtACaretIsWhatTheNextTypedTextGetsAndTogglesOff() {
            let note = Note(RichText(plain: "ab"))
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 2, length: 0))
            text.perform(.bold)
            #expect(text.isOn(.bold))
            #expect(note.editor.richText == RichText(plain: "ab"), "nothing typed yet")

            type("c", in: text)
            text.perform(.italic)
            type("d", in: text)
            text.perform(.bold)
            text.perform(.italic)
            type("e", in: text)
            #expect(
                note.editor.richText.blocks == [
                    .paragraph([
                        Run("ab"), Run("c", marks: .bold), Run("d", marks: [.bold, .italic]),
                        Run("e"),
                    ])
                ]
            )
            view.host.detach()
        }

        @Test func everyMarkFormatIsReadBackAsItsMark() {
            for format in RichFormat.allCases {
                guard let mark = format.mark else { continue }

                let note = Note(RichText(plain: "ab"))
                let (view, text, _) = made(note)
                text.setSelectedRange(NSRange(location: 0, length: 2))
                text.perform(format)
                #expect(
                    note.editor.richText.blocks == [.paragraph([Run("ab", marks: mark)])],
                    "\(format)"
                )
                #expect(text.model == note.editor.richText, "\(format)")
                view.host.detach()
            }
        }

        @Test func codeTakesNoMarksAndALinkNeedsASelection() {
            let note = Note(
                RichText(blocks: [.paragraph([Run("ab")]), .code("let", language: nil)])
            )
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 3, length: 3))
            #expect(!text.isAvailable(.bold))
            #expect(!text.isAvailable(.link))
            #expect(text.isAvailable(.quote))
            text.perform(.bold)
            #expect(note.editor.richText.blocks[1] == .code("let", language: nil))

            text.setSelectedRange(NSRange(location: 1, length: 0))
            #expect(text.isAvailable(.bold))
            #expect(!text.isAvailable(.link))
            view.host.detach()
        }

        @Test func aKindFormatChangesTheBlocksOfTheSelectionAndTakesItOffAgain() {
            let note = Note(RichText(blocks: [.paragraph([Run("a")]), .paragraph([Run("b")])]))
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 0, length: 3))
            text.perform(.quote)
            #expect(note.editor.richText.blocks == [.quote([Run("a")]), .quote([Run("b")])])
            #expect(text.isOn(.quote))
            #expect(text.model == note.editor.richText)

            text.perform(.code)
            #expect(
                note.editor.richText.blocks == [
                    .code("a", language: nil), .code("b", language: nil),
                ]
            )
            text.perform(.code)
            #expect(
                note.editor.richText.blocks == [.paragraph([Run("a")]), .paragraph([Run("b")])]
            )
            view.host.detach()
        }

        @Test func aQuoteOnTheEmptyLastLineSurvivesReadingAndIsWhatIsTypedThere() throws {
            let note = Note(RichText(blocks: [.paragraph([Run("a")]), .paragraph([])]))
            let (view, text, _) = made(note)
            let undo = try #require(text.undoManager)
            undo.groupsByEvent = false
            func grouped(_ body: () -> Void) {
                undo.beginUndoGrouping()
                body()
                undo.endUndoGrouping()
            }
            text.setSelectedRange(NSRange(location: 2, length: 0))

            grouped { text.perform(.quote) }
            #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([])])
            #expect(text.model == note.editor.richText)
            StateUpdates.flush()
            #expect(text.selectedRange() == NSRange(location: 2, length: 0))

            grouped { type("x", in: text) }
            #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([Run("x")])])

            grouped { text.deleteBackward(nil) }
            #expect(
                note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([])],
                "deleting its text leaves the quote empty, as it does in the middle of the text"
            )
            grouped { text.deleteBackward(nil) }
            #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .paragraph([])])

            undo.undo()
            #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([])])
            view.host.detach()
        }

        @Test func aQuoteOnAnEmptyEditorIsKept() {
            let note = Note()
            let (view, text, _) = made(note)
            text.perform(.quote)
            #expect(note.editor.richText.blocks == [.quote([])])
            type("q", in: text)
            #expect(note.editor.richText.blocks == [.quote([Run("q")])])
            view.host.detach()
        }

        @Test func textCodeSetsWithAnEmptyQuoteAtTheEndShowsItAndReadsItBack() {
            let note = Note()
            let (view, text, _) = made(note)
            let value = RichText(blocks: [.paragraph([Run("a")]), .quote([])])
            note.editor.richText = value
            for _ in 0..<4 {
                StateUpdates.flush()
                view.layout()
            }
            #expect(text.model == value)
            view.host.detach()
        }

        @Test func aCaretOnAnEmptyLineTypesThatLinesOwnKindNotTheLineAbovesKind() {
            let note = Note(
                RichText(blocks: [.quote([Run("q")]), .paragraph([]), .paragraph([Run("z")])])
            )
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 2, length: 0))
            type("x", in: text)
            #expect(
                note.editor.richText.blocks == [
                    .quote([Run("q")]), .paragraph([Run("x")]), .paragraph([Run("z")]),
                ]
            )
            view.host.detach()
        }

        @Test func aLinkIsAskedForAndAppliedOrTakenOff() {
            let note = Note(RichText(blocks: [.paragraph([Run("ab"), Run("cd", link: site)])]))
            let (view, text, _) = made(note)
            var asked: [URL?] = []
            let other = URL(string: "https://new.example")
            var answer: URL? = other
            text.askForLink = { current, apply in
                asked.append(current)
                apply(answer)
            }

            text.setSelectedRange(NSRange(location: 0, length: 2))
            text.perform(.link)
            #expect(asked == [nil])
            #expect(
                note.editor.richText.blocks == [
                    .paragraph([Run("ab", link: other), Run("cd", link: site)])
                ]
            )

            text.setSelectedRange(NSRange(location: 2, length: 2))
            answer = nil
            text.perform(.link)
            #expect(asked == [nil, site], "the address there is offered to change")
            #expect(
                note.editor.richText.blocks == [.paragraph([Run("ab", link: other), Run("cd")])]
            )
            view.host.detach()
        }

        // MARK: Shortcuts and menus

        @Test func theShortcutsFormatTheSelectionWhileTheViewHasTheKeyboard() {
            let note = Note(RichText(plain: "ab"))
            let (view, text, window) = made(note)
            let commandB = keyEvent("b", .command, keyCode: 11, window: window)
            let quote = keyEvent("9", [.command, .shift], keyCode: 25, window: window)
            text.setSelectedRange(NSRange(location: 0, length: 2))

            #expect(!text.performKeyEquivalent(with: commandB), "not while it has no keyboard")
            #expect(window.makeFirstResponder(text))
            #expect(text.performKeyEquivalent(with: commandB))
            #expect(note.editor.richText.blocks == [.paragraph([Run("ab", marks: .bold)])])
            #expect(text.performKeyEquivalent(with: quote))
            #expect(note.editor.richText.blocks == [.quote([Run("ab", marks: .bold)])])

            // Code takes no marks: the key is left to the system.
            note.editor.richText = RichText(blocks: [.code("c", language: nil)])
            StateUpdates.flush()
            text.setSelectedRange(NSRange(location: 0, length: 1))
            #expect(!text.performKeyEquivalent(with: commandB))
            view.host.detach()
        }

        @Test func aMenuItemOfTheFormatMenuAppliesTheFormatAndShowsItsState() throws {
            let note = Note(RichText(blocks: [.paragraph([Run("ab", marks: .bold)])]))
            let (view, text, _) = made(note)
            text.setSelectedRange(NSRange(location: 0, length: 2))

            let menu = NSMenu.richTextFormat
            let items = menu.items.filter { !$0.isSeparatorItem }
            #expect(items.count == RichFormat.allCases.count)
            let bold = try #require(items.first { $0.title == "Bold" })
            #expect(bold.keyEquivalent == "b")
            #expect(bold.keyEquivalentModifierMask == .command)
            #expect(text.validateMenuItem(bold))
            #expect(bold.state == .on)
            let italic = try #require(items.first { $0.title == "Italic" })
            #expect(text.validateMenuItem(italic))
            #expect(italic.state == .off)

            text.performFormat(italic)
            #expect(
                note.editor.richText.blocks == [.paragraph([Run("ab", marks: [.bold, .italic])])]
            )

            note.editor.richText = RichText(blocks: [.code("c", language: nil)])
            StateUpdates.flush()
            text.setSelectedRange(NSRange(location: 0, length: 1))
            #expect(!text.validateMenuItem(bold), "code takes no marks")
            view.host.detach()
        }

        // MARK: Size

        @Test func theEditorIsItsLeastLinesHighAndGrowsWithItsText() throws {
            let note = Note()
            note.editor.minLines = 2
            note.editor.maxLines = 5
            let (view, text, _) = made(note)
            let scroll = try #require(text.enclosingScrollView as? RichEditorScrollView)
            let metrics = scroll.lineMetrics()
            #expect(
                abs(note.editor.preferredSize.height - (metrics.lineHeight * 2 + metrics.insets))
                    < 2
            )

            note.editor.richText = RichText(
                blocks: (0..<12).map { _ in .paragraph([Run("line")]) }
            )
            for _ in 0..<6 {
                StateUpdates.flush()
                view.layout()
            }
            #expect(
                abs(note.editor.preferredSize.height - (metrics.lineHeight * 5 + metrics.insets))
                    < 12
            )
            #expect(scroll.hasVerticalScroller)
            view.host.detach()
        }
    }
#endif
