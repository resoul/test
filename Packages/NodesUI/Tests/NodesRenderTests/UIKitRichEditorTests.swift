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

    // MARK: Formats

    @Test @MainActor func aMarkFormatMarksTheSelectionAndOneUndoTakesItBack() throws {
        let note = Note(RichText(plain: "abcd"))
        let (view, text) = made(note)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        text.selectedRange = NSRange(location: 1, length: 2)
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
        #expect(text.selectedRange == NSRange(location: 1, length: 2))
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

        undo.beginUndoGrouping()
        text.perform(.bold)
        undo.endUndoGrouping()
        #expect(note.editor.richText.blocks == [.paragraph([Run("abcd")])])
        view.host.detach()
    }

    @Test @MainActor func aMarkAtACaretIsWhatTheNextTypedTextGetsAndTogglesOff() {
        let note = Note(RichText(plain: "ab"))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 2, length: 0)
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
                    Run("ab"), Run("c", marks: .bold), Run("d", marks: [.bold, .italic]), Run("e"),
                ])
            ]
        )
        view.host.detach()
    }

    @Test @MainActor func everyMarkFormatIsReadBackAsItsMark() {
        for format in RichFormat.allCases {
            guard let mark = format.mark else { continue }

            let note = Note(RichText(plain: "ab"))
            let (view, text) = made(note)
            text.selectedRange = NSRange(location: 0, length: 2)
            text.perform(format)
            #expect(
                note.editor.richText.blocks == [.paragraph([Run("ab", marks: mark)])],
                "\(format)"
            )
            #expect(text.model == note.editor.richText, "\(format)")
            view.host.detach()
        }
    }

    @Test @MainActor func codeTakesNoMarksAndALinkNeedsASelection() {
        let note = Note(RichText(blocks: [.paragraph([Run("ab")]), .code("let", language: nil)]))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 3, length: 3)
        #expect(!text.isAvailable(.bold))
        #expect(!text.isAvailable(.link))
        #expect(text.isAvailable(.quote))
        text.perform(.bold)
        #expect(note.editor.richText.blocks[1] == .code("let", language: nil))

        text.selectedRange = NSRange(location: 1, length: 0)
        #expect(text.isAvailable(.bold))
        #expect(!text.isAvailable(.link))
        view.host.detach()
    }

    @Test @MainActor func aKindFormatChangesTheBlocksOfTheSelectionAndTakesItOffAgain() {
        let note = Note(RichText(blocks: [.paragraph([Run("a")]), .paragraph([Run("b")])]))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 0, length: 3)
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
        #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .paragraph([Run("b")])])
        view.host.detach()
    }

    @Test @MainActor func aQuoteOnTheEmptyLastLineSurvivesReadingAndIsWhatIsTypedThere() throws {
        let note = Note(RichText(blocks: [.paragraph([Run("a")]), .paragraph([])]))
        let (view, text) = made(note)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        func grouped(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        text.selectedRange = NSRange(location: 2, length: 0)

        grouped { text.perform(.quote) }
        #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([])])
        #expect(text.model == note.editor.richText)
        StateUpdates.flush()
        #expect(text.selectedRange == NSRange(location: 2, length: 0))

        grouped { type("x", in: text) }
        #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([Run("x")])])

        grouped { text.deleteBackward() }
        #expect(
            note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([])],
            "deleting its text leaves the quote empty, as it does in the middle of the text"
        )
        grouped { text.deleteBackward() }
        #expect(
            note.editor.richText.blocks == [.paragraph([Run("a")]), .paragraph([])],
            "Backspace at the start of the empty quote makes it a paragraph"
        )

        undo.undo()
        #expect(note.editor.richText.blocks == [.paragraph([Run("a")]), .quote([])])
        view.host.detach()
    }

    @Test @MainActor func aQuoteOnAnEmptyEditorIsKept() {
        let note = Note()
        let (view, text) = made(note)
        text.perform(.quote)
        #expect(note.editor.richText.blocks == [.quote([])])
        type("q", in: text)
        #expect(note.editor.richText.blocks == [.quote([Run("q")])])
        view.host.detach()
    }

    @Test @MainActor func textCodeSetsWithAnEmptyQuoteAtTheEndShowsItAndReadsItBack() {
        let note = Note()
        let (view, text) = made(note)
        let value = RichText(blocks: [.paragraph([Run("a")]), .quote([])])
        note.editor.richText = value
        StateUpdates.flush()
        view.layoutIfNeeded()
        #expect(text.model == value)
        view.host.detach()
    }

    @Test @MainActor func aCaretOnAnEmptyLineTypesThatLinesOwnKindNotTheLineAbovesKind() {
        let note = Note(
            RichText(blocks: [.quote([Run("q")]), .paragraph([]), .paragraph([Run("z")])])
        )
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 2, length: 0)
        type("x", in: text)
        #expect(
            note.editor.richText.blocks == [
                .quote([Run("q")]), .paragraph([Run("x")]), .paragraph([Run("z")]),
            ]
        )
        view.host.detach()
    }

    @Test @MainActor func aLinkIsAskedForAndAppliedOrTakenOff() {
        let note = Note(RichText(blocks: [.paragraph([Run("ab"), Run("cd", link: site)])]))
        let (view, text) = made(note)
        var asked: [URL?] = []
        var answer: URL? = URL(string: "https://new.example")
        text.askForLink = { current, apply in
            asked.append(current)
            apply(answer)
        }

        text.selectedRange = NSRange(location: 0, length: 2)
        text.perform(.link)
        #expect(asked == [nil])
        #expect(
            note.editor.richText.blocks == [
                .paragraph([Run("ab", link: answer), Run("cd", link: site)])
            ]
        )

        text.selectedRange = NSRange(location: 2, length: 2)
        answer = nil
        text.perform(.link)
        #expect(asked == [nil, site], "the address there is offered to change")
        #expect(
            note.editor.richText.blocks == [
                .paragraph([Run("ab", link: URL(string: "https://new.example")), Run("cd")])
            ]
        )
        view.host.detach()
    }

    @Test @MainActor func theShortcutsAreKeyCommandsThatApplyTheFormat() throws {
        let note = Note(RichText(plain: "ab"))
        let (view, text) = made(note)
        let commands = try #require(text.keyCommands)
        let titles = Set(commands.compactMap(\.title))
        for format in RichFormat.allCases {
            #expect(titles.contains(format.command.title), "\(format)")
        }
        let bold = try #require(commands.first { $0.input == "b" })
        #expect(bold.modifierFlags == .command)

        text.selectedRange = NSRange(location: 0, length: 2)
        #expect(
            text.canPerformAction(#selector(RichEditorView.performFormat(_:)), withSender: bold)
        )
        text.performFormat(bold)
        #expect(note.editor.richText.blocks == [.paragraph([Run("ab", marks: .bold)])])

        // With the caret in code, bold is not available: the key is left to the system.
        note.editor.richText = RichText(blocks: [.code("c", language: nil)])
        StateUpdates.flush()
        text.selectedRange = NSRange(location: 0, length: 1)
        #expect(
            !text.canPerformAction(#selector(RichEditorView.performFormat(_:)), withSender: bold)
        )
        view.host.detach()
    }

    @Test @MainActor func everyFormatHasItsOwnShortcut() {
        let shortcuts = RichFormat.allCases.compactMap { $0.command.shortcut }
        #expect(shortcuts.count == RichFormat.allCases.count)
        #expect(Set(shortcuts).count == shortcuts.count)
        for format in RichFormat.allCases {
            #expect(RichFormat(commandID: format.command.id) == format)
        }
        #expect(RichFormat(commandID: "other") == nil)
    }

    @Test @MainActor func theEditMenuOffersTheFormatsWithTheirState() throws {
        let note = Note(RichText(blocks: [.paragraph([Run("ab", marks: .bold)])]))
        let (view, text) = made(note)
        text.selectedRange = NSRange(location: 0, length: 2)
        let menu = try #require(
            text.textView(text, editMenuForTextIn: text.selectedRange, suggestedActions: [])
        )
        let format = try #require(
            menu.children.compactMap { $0 as? UIMenu }.first { $0.title == "Format" }
        )
        let actions = format.children.compactMap { $0 as? UIMenu }.flatMap(\.children).compactMap {
            $0 as? UIAction
        }
        #expect(actions.count == RichFormat.allCases.count)
        let bold = try #require(actions.first { $0.title == "Bold" })
        #expect(bold.state == .on)
        let italic = try #require(actions.first { $0.title == "Italic" })
        #expect(italic.state == .off)
        let link = try #require(actions.first { $0.title == "Link…" })
        #expect(!link.attributes.contains(.disabled))
        view.host.detach()
    }

    @Test @MainActor func theMenuBarMenuHoldsEveryFormatAsACommand() {
        let menu = UIMenu.richTextFormat
        let items = menu.children.compactMap { $0 as? UIMenu }.flatMap(\.children)
            .compactMap { $0 as? UICommand }
        #expect(items.count == RichFormat.allCases.count)
        for item in items {
            #expect(item.action == #selector(RichEditorView.performFormat(_:)))
            #expect(RichEditorView.format(of: item) != nil)
        }
    }

    @Test @MainActor func theBoldAndMonospacedFacesFollowTheReadersTextSize() throws {
        let value = RichText(
            blocks: [
                .paragraph([Run("a"), Run("b", marks: .bold), Run("c", marks: .mono)]),
                .code("d", language: nil),
            ]
        )
        let note = Note(value)
        let (view, text) = made(note)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 800))
        window.addSubview(view)
        window.isHidden = false
        var changes = 0
        note.editor.onChange = { _ in changes += 1 }
        text.selectedRange = NSRange(location: 1, length: 2)

        func size(at index: Int) throws -> CGFloat {
            try #require(
                text.textStorage.attribute(.font, at: index, effectiveRange: nil) as? UIFont
            )
            .pointSize
        }
        let before = (try size(at: 0), try size(at: 1), try size(at: 2), try size(at: 4))

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        for _ in 0..<3 {
            view.layoutIfNeeded()
            window.layoutIfNeeded()
        }
        #expect(try size(at: 0) > before.0)
        #expect(try size(at: 1) > before.1, "bold")
        #expect(try size(at: 2) > before.2, "monospaced")
        #expect(try size(at: 4) > before.3, "code")
        #expect(text.model == value)
        #expect(changes == 0, "the reader's setting is not the user's edit")
        #expect(text.selectedRange == NSRange(location: 1, length: 2))
        view.host.detach()
    }

    // MARK: Bars and plates

    /// The alpha of the pixel at `point` in `image`, measured from its top left.
    private func alpha(of image: UIImage, at point: CGPoint) -> CGFloat {
        guard let cgImage = image.cgImage else { return 0 }

        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            // Core Graphics counts from the bottom: the wanted pixel is put on the one of the
            // context.
            let x = point.x * image.scale
            let y = CGFloat(cgImage.height) - point.y * image.scale - 1
            context?.draw(
                cgImage,
                in: CGRect(
                    x: -x,
                    y: -y,
                    width: CGFloat(cgImage.width),
                    height: CGFloat(cgImage.height)
                )
            )
        }
        return CGFloat(pixel[3]) / 255
    }

    /// What the layout fragment of block `index` draws, in the text container's coordinates.
    @MainActor private func drawn(_ index: Int, in text: RichEditorView) throws -> (
        UIImage, RichBlockFragment
    ) {
        let manager = try #require(text.textLayoutManager)
        var fragments: [RichBlockFragment] = []
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            if let fragment = fragment as? RichBlockFragment { fragments.append(fragment) }
            return true
        }
        let fragment = try #require(fragments.indices.contains(index) ? fragments[index] : nil)
        let frame = fragment.layoutFragmentFrame
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format)
            .image { context in
                fragment.draw(at: frame.origin, in: context.cgContext)
            }
        return (image, fragment)
    }

    @Test @MainActor func aQuoteHasABarBesideItAndNothingElseIsDrawnBehindAParagraph() throws {
        let note = Note(
            RichText(blocks: [.paragraph([Run("Plain")]), .quote([Run("quoted")])])
        )
        let (view, text) = made(note)
        let padding = text.textContainer.lineFragmentPadding

        let (paragraph, _) = try drawn(0, in: text)
        let (quote, fragment) = try drawn(1, in: text)
        let line = try #require(fragment.textLineFragments.first)
        let middle = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
        #expect(alpha(of: quote, at: CGPoint(x: padding + 1, y: middle)) > 0.3, "the bar")
        #expect(alpha(of: quote, at: CGPoint(x: padding + 6, y: middle)) < 0.05, "past the bar")
        #expect(alpha(of: quote, at: CGPoint(x: 250, y: middle)) < 0.05, "far from the bar")
        #expect(alpha(of: paragraph, at: CGPoint(x: 250, y: 10)) < 0.01, "a paragraph has no plate")
        #expect(alpha(of: paragraph, at: CGPoint(x: padding + 1, y: 20)) < 0.05, "and no bar")
        view.host.detach()
    }

    @Test @MainActor func codeHasAPlateThatReachesItsPaddingBeyondTheLines() throws {
        let note = Note(
            RichText(blocks: [.paragraph([Run("Plain")]), .code("let a\nlet b", language: nil)])
        )
        let (view, text) = made(note)
        let padding = text.textContainer.lineFragmentPadding
        let (code, fragment) = try drawn(1, in: text)
        let lines = fragment.textLineFragments
        let top = fragment.layoutFragmentFrame.minY + lines[0].typographicBounds.minY
        let bottom = fragment.layoutFragmentFrame.minY + lines[1].typographicBounds.maxY
        let inset = RichAttributedStyle.standard.codePadding

        #expect(alpha(of: code, at: CGPoint(x: 250, y: (top + bottom) / 2)) > 0.03, "the plate")
        #expect(alpha(of: code, at: CGPoint(x: 250, y: top - inset / 2)) > 0.03, "above the lines")
        #expect(
            alpha(of: code, at: CGPoint(x: 250, y: bottom + inset / 2)) > 0.03,
            "below the lines"
        )
        #expect(alpha(of: code, at: CGPoint(x: 250, y: top - inset - 3)) < 0.01, "beyond the plate")
        #expect(
            alpha(of: code, at: CGPoint(x: padding + 2, y: (top + bottom) / 2)) > 0.03,
            "at its left edge"
        )
        #expect(
            alpha(of: code, at: CGPoint(x: padding - 3, y: (top + bottom) / 2)) < 0.01,
            "left of it"
        )
        #expect(
            fragment.renderingSurfaceBounds.minY <= lines[0].typographicBounds.minY - inset,
            "the surface reaches the plate"
        )
        view.host.detach()
    }

    @Test @MainActor func codeIsNoLongerColoredByATextBackground() throws {
        let note = Note(RichText(blocks: [.code("let a", language: nil)]))
        let (view, text) = made(note)
        var background = false
        text.textStorage.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: text.textStorage.length)
        ) { value, _, _ in
            if value != nil { background = true }
        }
        #expect(!background)
        view.host.detach()
    }
#endif
