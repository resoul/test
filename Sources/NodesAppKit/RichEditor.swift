#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import Foundation
    import LayoutCore
    import Nodes
    import NodesRender
    import RichTextCore

    extension RichTextEditor: AppKitEmbedded {
        func makeHolder() -> EmbeddedHolder {
            let view = RichEditorScrollView(self)
            let holder = EmbeddedHolder(node: self, view: view)
            holder.watch { [weak view, weak self] in
                guard let view, let self else { return }

                let text = richText
                // What the user typed comes back here as the node's own value: the view already
                // shows it, and putting it in again would disturb the caret and the input method.
                if view.textView.model != text {
                    view.textView.show(text)
                    setNeedsLayout()
                }
                view.placeholderLabel.stringValue = placeholder
                view.updatePlaceholder()
            }
            onEditingRequest = { [weak view] editing in
                guard let view, let window = view.window else { return }

                if editing {
                    window.makeFirstResponder(view.textView)
                } else if window.firstResponder === view.textView {
                    window.makeFirstResponder(nil)
                }
            }
            holder.fit = { [weak view, weak self] width in
                guard let view, let self else { return false }

                let metrics = view.lineMetrics()
                let fitted = height(
                    forContent: view.contentHeight(),
                    lineHeight: metrics.lineHeight,
                    insets: metrics.insets
                )
                view.hasVerticalScroller = fitted.scrolls
                guard abs(preferredSize.height - fitted.height) > 0.5 else { return false }

                preferredSize = LayoutSize(width: preferredSize.width, height: fitted.height)
                return true
            }
            return holder
        }
    }

    /// A scroll view holding the text view of a `RichTextEditor` node, and the placeholder that
    /// stands where the first line goes while the text is empty.
    final class RichEditorScrollView: NSScrollView {
        let textView: RichEditorTextView
        let placeholderLabel = NSTextField(labelWithString: "")

        init(_ editor: RichTextEditor) {
            textView = RichEditorTextView(editor)
            super.init(frame: .zero)
            documentView = textView
            hasVerticalScroller = false
            borderType = .bezelBorder
            drawsBackground = true
            textView.addSubview(placeholderLabel)
            placeholderLabel.textColor = .placeholderTextColor
            placeholderLabel.font = textView.font
            textView.onContentChange = { [weak self] in self?.updatePlaceholder() }
            updatePlaceholder()
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// How much a line of text adds to the height, and what the height is besides the
        /// lines — worked out by measuring one line and two in a view of the same kind that
        /// never shows, at the width this one has.
        func lineMetrics() -> (lineHeight: Double, insets: Double) {
            let scratch = NSTextView(
                frame: NSRect(x: 0, y: 0, width: textView.frame.width, height: 0)
            )
            scratch.font = textView.font
            scratch.textContainerInset = textView.textContainerInset
            scratch.isVerticallyResizable = true
            scratch.isHorizontallyResizable = false
            func height(of text: String) -> Double {
                scratch.string = text
                guard let layout = scratch.textLayoutManager else { return 0 }

                layout.ensureLayout(for: layout.documentRange)
                return Double(layout.usageBoundsForTextContainer.height)
                    + Double(scratch.textContainerInset.height * 2)
            }
            let one = height(of: "A")
            let two = height(of: "A\nA")
            return (two - one, one - (two - one))
        }

        /// How high the text is at the width the view has, with the insets above and below.
        func contentHeight() -> Double {
            layoutSubtreeIfNeeded()
            guard let layout = textView.textLayoutManager else { return 0 }

            layout.ensureLayout(for: layout.documentRange)
            return Double(layout.usageBoundsForTextContainer.height)
                + Double(textView.textContainerInset.height * 2)
        }

        func updatePlaceholder() {
            placeholderLabel.isHidden = !textView.string.isEmpty
            let inset = textView.textContainerInset
            let padding = textView.textContainer?.lineFragmentPadding ?? 5
            placeholderLabel.sizeToFit()
            placeholderLabel.frame.origin = NSPoint(x: inset.width + padding, y: inset.height)
        }
    }

    /// A text view showing a `RichTextEditor` node. The view's attributed text is the truth
    /// while the user edits: what it holds is read back into a `RichText` after each change,
    /// except while a word is being composed. Return and Backspace in a quote or in code go
    /// through the model's rules, and so do the formats (`RichFormat`) from the menu and the
    /// shortcuts; what they change can be undone.
    final class RichEditorTextView: NSTextView, NSTextViewDelegate {
        weak var editor: RichTextEditor?
        /// Called after the text changed, whoever changed it: the placeholder's turn.
        var onContentChange: (@MainActor () -> Void)?

        init(_ editor: RichTextEditor) {
            self.editor = editor
            super.init(
                frame: NSRect(x: 0, y: 0, width: 200, height: 20),
                textContainer: Self.makeTextContainer()
            )
            delegate = self
            isRichText = true
            allowsUndo = true
            usesFontPanel = false
            importsGraphics = false
            isAutomaticLinkDetectionEnabled = false
            font = RichAttributedStyle.standard.font
            textContainerInset = NSSize(width: 4, height: 6)
            minSize = NSSize(width: 0, height: 0)
            maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: .greatestFiniteMagnitude
            )
            isVerticallyResizable = true
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            textContainer?.widthTracksTextView = true
            setAccessibilityIdentifier(editor.placeholder)
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// The container of a text view that lays out with TextKit 2, as a plain text view does:
        /// the view made without one has no text at all.
        private static func makeTextContainer() -> NSTextContainer {
            let content = NSTextContentStorage()
            let layout = NSTextLayoutManager()
            content.addTextLayoutManager(layout)
            let container = NSTextContainer(
                size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
            )
            layout.textContainer = container
            return container
        }

        // MARK: Content

        private var style: RichAttributedStyle { .standard }

        /// Where undo steps go when the view is not in a window, which has its own manager.
        private lazy var fallbackUndoManager = UndoManager()

        override var undoManager: UndoManager? {
            super.undoManager ?? fallbackUndoManager
        }

        /// The kind of the last block while it is empty and not a paragraph — an empty quote or
        /// code at the end. No character carries the kind of such a block, so the view keeps it
        /// here until the text changes.
        private var emptyTailKind: RichText.Kind?

        private static func tailKind(of text: RichText) -> RichText.Kind? {
            guard let last = text.blocks.last, last.characterCount == 0, last.kind != .paragraph
            else { return nil }

            return last.kind
        }

        /// What the view holds, as a value.
        var model: RichText {
            var value = RichAttributed.richText(
                from: textStorage ?? NSAttributedString(),
                style: style
            )
            if let kind = emptyTailKind, value.blocks.last == .paragraph([]) {
                value.setKind(kind, for: RichRange(at: value.end))
            }
            return value
        }

        private var length: Int { textStorage?.length ?? 0 }

        /// Shows `text`, set by code: what the view could undo was about other text.
        func show(_ text: RichText) {
            let caret = selectedRange()
            emptyTailKind = Self.tailKind(of: text)
            textStorage?.setAttributedString(RichAttributed.attributedString(text, style: style))
            setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
            // Only the steps of this view: the window's manager holds those of other views too.
            undoManager?.removeAllActions(withTarget: self)
            refreshTypingAttributes()
            onContentChange?()
        }

        /// Puts `content` in place of the whole text with the selection at `selection`, the way
        /// the rules of the model change the text; the change can be undone, and undoing it can
        /// be undone. `tail` is the kind of an empty last block, which the content cannot show.
        private func replaceContent(
            _ content: NSAttributedString,
            selection: NSRange,
            tail: RichText.Kind?,
            actionName: String? = nil
        ) {
            let previous = (
                NSAttributedString(attributedString: textStorage ?? NSAttributedString()),
                selectedRange(), emptyTailKind
            )
            // The memory comes first: the typing style of an empty line depends on it.
            emptyTailKind = tail
            textStorage?.setAttributedString(content)
            setSelectedRange(selection)
            refreshTypingAttributes()
            undoManager?.registerUndo(withTarget: self) { view in
                view.replaceContent(
                    previous.0,
                    selection: previous.1,
                    tail: previous.2,
                    actionName: actionName
                )
                view.contentChanged()
            }
            if let actionName { undoManager?.setActionName(actionName) }
        }

        /// The style of what is typed on an empty line. There is no character on it to take the
        /// style from, and the view would take it from the line above — a quote's, say — so the
        /// line's own kind is set.
        func refreshTypingAttributes() {
            guard !hasMarkedText(), selectedRange().length == 0, let storage = textStorage
            else { return }

            let string = storage.string as NSString
            let location = selectedRange().location
            guard location <= string.length else { return }

            let startsBlock = location == 0 || string.character(at: location - 1) == 0x0A
            let endsBlock = location == string.length || string.character(at: location) == 0x0A
            guard startsBlock, endsBlock else { return }

            var kind = emptyTailKind ?? .paragraph
            if location < string.length,
                let tag = storage.attribute(
                    RichAttributed.blockKey,
                    at: location,
                    effectiveRange: nil
                ) as? String
            {
                kind = RichAttributed.kind(ofTag: tag) ?? .paragraph
            }
            typingAttributes = RichAttributed.attributes(
                kind: kind,
                style: style,
                isFirst: location == 0
            )
        }

        /// Reads the view back into the node, unless a word is being composed: its letters are
        /// not the text yet.
        func contentChanged() {
            onContentChange?()
            guard !hasMarkedText(), let editor else { return }

            editor.userChanged(model)
            editor.setNeedsLayout()
        }

        private func apply(_ text: RichText, selection: NSRange, actionName: String? = nil) {
            replaceContent(
                RichAttributed.attributedString(text, style: style),
                selection: selection,
                tail: Self.tailKind(of: text),
                actionName: actionName
            )
            contentChanged()
        }

        private func apply(_ text: RichText, caret: RichPosition) {
            apply(text, selection: NSRange(location: text.utf16Offset(of: caret), length: 0))
        }

        // MARK: Rules of the model

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn range: NSRange,
            replacementString text: String?
        ) -> Bool {
            guard text == "\n", !hasMarkedText() else { return true }

            var value = model
            let selection = value.range(utf16Location: range.location, length: range.length)
            guard value.blocks[selection.start.block].kind != .paragraph else { return true }

            let caret = selection.isEmpty ? selection.start : value.delete(selection)
            let after = value.splitBlock(at: caret)
            apply(value, caret: after)
            return false
        }

        override func deleteBackward(_ sender: Any?) {
            if !hasMarkedText(), selectedRange().length == 0 {
                var value = model
                let caret = value.position(utf16Offset: selectedRange().location, rounding: .down)
                if caret.offset == 0, value.blocks[caret.block].kind != .paragraph {
                    value.setKind(.paragraph, for: RichRange(at: caret))
                    apply(value, caret: caret)
                    return
                }
            }
            super.deleteBackward(sender)
        }

        override func didChangeText() {
            // Deleting all the text of a quote or code at the end leaves it an empty block of
            // the same kind, as it does in the middle of the text; typing anywhere else, or
            // deleting more, ends the memory of an empty last block.
            let before = editor?.richText
            emptyTailKind = nil
            if let before, let last = before.blocks.last, last.kind != .paragraph {
                let read = model
                if read.blocks.count == before.blocks.count, read.blocks.last == .paragraph([]) {
                    emptyTailKind = last.kind
                }
            }
            super.didChangeText()
            contentChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            refreshTypingAttributes()
        }

        // MARK: Keyboard focus

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { editor?.editingChanged(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { editor?.editingChanged(false) }
            return resigned
        }

        // MARK: Formats

        /// Whether `format` can be applied to the selection now: not while a word is being
        /// composed, and not where the text cannot carry it — code has no marks, and a link
        /// needs a selection.
        func isAvailable(_ format: RichFormat) -> Bool {
            guard !hasMarkedText() else { return false }

            let value = model
            let selection = selectedRange()
            return value.isAvailable(
                format,
                in: value.range(utf16Location: selection.location, length: selection.length)
            )
        }

        /// Whether `format` is in effect at the selection, for a checkmark: for a caret, a mark
        /// is what the next typed text gets.
        func isOn(_ format: RichFormat) -> Bool {
            let selection = selectedRange()
            if let mark = format.mark, selection.length == 0 {
                return RichAttributed.marks(of: typingAttributes, style: style).contains(mark)
                    && isAvailable(format)
            }
            let value = model
            let range = value.range(utf16Location: selection.location, length: selection.length)
            return value.state(ofFormat: format, in: range) == .all
        }

        /// Applies `format` to the selection. Marks, kinds and links go through the rules of the
        /// model and replace the content, which can be undone as one step named for the format;
        /// a mark at a caret changes the style of the next typed text instead. A link asks for
        /// its address first.
        func perform(_ format: RichFormat) {
            guard isAvailable(format) else { return }

            if format == .link {
                requestLink()
                return
            }
            let selection = selectedRange()
            if let mark = format.mark, selection.length == 0 {
                toggleTypingMark(mark)
                return
            }
            var value = model
            let range = value.range(utf16Location: selection.location, length: selection.length)
            let before = value
            value.apply(format, in: range)
            guard value != before else { return }

            apply(value, selection: selection, actionName: format.command.title)
        }

        private func toggleTypingMark(_ mark: Marks) {
            let value = model
            let caret = value.position(utf16Offset: selectedRange().location, rounding: .down)
            var marks = RichAttributed.marks(of: typingAttributes, style: style)
            if marks.contains(mark) { marks.remove(mark) } else { marks.insert(mark) }
            typingAttributes = RichAttributed.attributes(
                kind: value.blocks[caret.block].kind,
                style: style,
                isFirst: caret.block == 0,
                marks: marks,
                link: typingAttributes[.link] as? URL
            )
        }

        // MARK: Links

        /// Asks for the address of the link the selection becomes — or, when the whole
        /// selection is a link already, its address to change or take away — and then applies
        /// it. Replaced in tests: the default is a sheet over the window.
        var askForLink: ((_ current: URL?, _ apply: @escaping (URL?) -> Void) -> Void)?

        private func requestLink() {
            let value = model
            let selection = selectedRange()
            let range = value.range(utf16Location: selection.location, length: selection.length)
            let ask =
                askForLink ?? { [weak self] current, apply in
                    self?.presentLinkSheet(current: current, apply: apply)
                }
            ask(value.link(in: range)) { [weak self] url in
                self?.setLink(url, in: selection)
            }
        }

        /// Makes the text at `selection` a link to `url`, or takes links off it when `url` is
        /// `nil`; the view takes the keyboard back, as the prompt for the address had it.
        func setLink(_ url: URL?, in selection: NSRange) {
            var value = model
            let before = value
            value.apply(
                .link,
                in: value.range(utf16Location: selection.location, length: selection.length),
                link: url
            )
            if value != before {
                apply(value, selection: selection, actionName: RichFormat.link.command.title)
            }
            window?.makeFirstResponder(self)
            setSelectedRange(selection)
        }

        private func presentLinkSheet(current: URL?, apply: @escaping (URL?) -> Void) {
            guard let window else { return }

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "https://"
            field.stringValue = current?.absoluteString ?? ""
            field.setAccessibilityIdentifier("richText.linkAddress")
            let alert = NSAlert()
            alert.messageText = "Link"
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            if current != nil { alert.addButton(withTitle: "Remove Link") }
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    let typed = field.stringValue
                    if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        apply(nil)
                    } else if let url = RichFormat.linkURL(from: typed) {
                        apply(url)
                    } else {
                        window.makeFirstResponder(self)
                    }
                case .alertThirdButtonReturn:
                    apply(nil)
                default:
                    window.makeFirstResponder(self)
                }
            }
        }

        // MARK: Shortcuts and menus

        /// The shortcuts of the formats work while the view has the keyboard, whether or not
        /// the app's menu has items for them; a format that is not available leaves the keys
        /// to the system.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, let shortcut = Shortcut(event),
                let format = RichFormat.allCases.first(where: { $0.command.shortcut == shortcut }),
                isAvailable(format)
            {
                perform(format)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        /// A format's menu item (`NSMenu.richTextFormat`) was chosen.
        @objc func performFormat(_ sender: Any?) {
            guard let format = RichEditorTextView.format(of: sender) else { return }

            perform(format)
        }

        static func format(of sender: Any?) -> RichFormat? {
            (sender as? NSMenuItem).flatMap { $0.representedObject as? String }
                .flatMap(RichFormat.init(commandID:))
        }

        /// A format's menu item is enabled where the format applies, and shows a checkmark
        /// while it is in effect.
        override func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard item.action == #selector(performFormat(_:)) else {
                return super.validateMenuItem(item)
            }
            guard let format = RichEditorTextView.format(of: item) else { return false }

            item.state = isOn(format) ? .on : .off
            return isAvailable(format)
        }
    }

    extension NSMenu {
        /// A menu of the rich text editor's formats for the app's menu bar:
        ///
        ///     let item = NSMenuItem(title: "Text Format", action: nil, keyEquivalent: "")
        ///     item.submenu = .richTextFormat
        ///     NSApplication.shared.mainMenu?.insertItem(item, at: 3)
        ///
        /// Its items go to the first responder: they are enabled while a rich text editor has
        /// the keyboard and can apply the format to its selection, and show a checkmark while
        /// the format is in effect there.
        public static var richTextFormat: NSMenu {
            let menu = NSMenu(title: "Text Format")
            func add(_ formats: [RichFormat]) {
                for format in formats {
                    let command = format.command
                    let item = NSMenuItem(
                        title: command.title,
                        action: #selector(RichEditorTextView.performFormat(_:)),
                        keyEquivalent: command.shortcut?.keyEquivalent ?? ""
                    )
                    item.keyEquivalentModifierMask =
                        command.shortcut.map { NSEvent.ModifierFlags($0.modifiers) } ?? []
                    item.representedObject = command.id
                    menu.addItem(item)
                }
            }
            add([.bold, .italic, .underline, .strikethrough, .monospace])
            menu.addItem(.separator())
            add([.link])
            menu.addItem(.separator())
            add([.quote, .code])
            return menu
        }
    }
#endif
