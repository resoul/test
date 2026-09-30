#if canImport(UIKit)
    import Foundation
    import LayoutCore
    import Nodes
    import NodesRender
    import RichTextCore
    import UIKit

    extension RichTextEditor: UIKitEmbedded {
        func makeHolder() -> EmbeddedHolder {
            let view = RichEditorView(self)
            if let bar = makeKeyboardBar(for: self) {
                view.inputAccessoryView = bar.view
                view.onBeginEditing = bar.refresh
            }
            let holder = EmbeddedHolder(node: self, view: view)
            holder.watch { [weak view, weak self] in
                guard let view, let self else { return }

                let text = richText
                // What the user typed comes back here as the node's own value: the view already
                // shows it, and putting it in again would disturb the caret and the input method.
                if view.model != text {
                    view.show(text)
                    setNeedsLayout()
                }
                view.placeholderLabel.text = placeholder
                view.updatePlaceholder()
            }
            onEditingRequest = { [weak view] editing in
                guard let view else { return }

                if editing {
                    view.becomeFirstResponder()
                } else {
                    view.resignFirstResponder()
                }
            }
            holder.fit = { [weak view, weak self] width in
                guard let view, let self else { return false }

                let content = Double(
                    view.sizeThatFits(
                        CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                    ).height
                )
                let metrics = view.lineMetrics(width: width)
                let fitted = height(
                    forContent: content,
                    lineHeight: metrics.lineHeight,
                    insets: metrics.insets
                )
                view.isScrollEnabled = fitted.scrolls
                guard abs(preferredSize.height - fitted.height) > 0.5 else { return false }

                preferredSize = LayoutSize(width: preferredSize.width, height: fitted.height)
                return true
            }
            return holder
        }
    }

    /// A text view showing a `RichTextEditor` node. The view's attributed text is the truth
    /// while the user edits: what it holds is read back into a `RichText` after each change,
    /// except while a word is being composed. Return and Backspace in a quote or in code go
    /// through the model's rules, and so do the formats (`RichFormat`) from the menu and the
    /// shortcuts; what they change can be undone.
    final class RichEditorView: UITextView, UITextViewDelegate {
        weak var editor: RichTextEditor?
        /// What to do when the editor takes the keyboard: the keyboard bar's turn.
        var onBeginEditing: (@MainActor () -> Void)?
        let placeholderLabel = UILabel()
        /// Makes the layout fragments that draw the bars and plates; the layout manager holds its
        /// delegate weakly.
        private let fragments = RichBlockFragments()

        init(_ editor: RichTextEditor) {
            self.editor = editor
            super.init(frame: .zero, textContainer: nil)
            delegate = self
            textLayoutManager?.delegate = fragments
            font = .preferredFont(forTextStyle: .body)
            adjustsFontForContentSizeCategory = true
            textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
            layer.borderColor = UIColor.separator.cgColor
            layer.borderWidth = 1
            layer.cornerRadius = 8
            isScrollEnabled = false
            accessibilityIdentifier = editor.placeholder
            placeholderLabel.font = font
            placeholderLabel.textColor = .placeholderText
            placeholderLabel.numberOfLines = 0
            placeholderLabel.isUserInteractionEnabled = false
            placeholderLabel.isAccessibilityElement = false
            addSubview(placeholderLabel)
            updatePlaceholder()
            if #available(iOS 17, tvOS 17, *) {
                registerForTraitChanges(
                    [UITraitPreferredContentSizeCategory.self],
                    action: #selector(textSizeChanged)
                )
            }
        }

        /// The reader changed the text size. The base font follows it by itself, but the bold,
        /// italic and monospaced faces derived from it were sized when the text was built, so
        /// the text is built again from what the view holds. The node's value does not change,
        /// and neither does the selection or what can be undone.
        @objc func textSizeChanged() {
            guard markedTextRange == nil else { return }

            let value = model
            let selection = selectedRange
            font = .preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
            placeholderLabel.font = font
            attributedText = RichAttributed.attributedString(value, style: style)
            selectedRange = selection
            refreshTypingAttributes()
            editor?.setNeedsLayout()
        }

        required init?(coder: NSCoder) {
            nil
        }

        // MARK: Content

        private var style: RichAttributedStyle {
            var style = RichAttributedStyle.standard
            style.font = .preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
            return style
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
            var value = RichAttributed.richText(from: attributedText, style: style)
            if let kind = emptyTailKind, value.blocks.last == .paragraph([]) {
                value.setKind(kind, for: RichRange(at: value.end))
            }
            return value
        }

        /// Shows `text`, set by code: what the view could undo was about other text.
        func show(_ text: RichText) {
            let caret = selectedRange
            emptyTailKind = Self.tailKind(of: text)
            attributedText = RichAttributed.attributedString(text, style: style)
            selectedRange = NSRange(location: min(caret.location, textStorage.length), length: 0)
            undoManager?.removeAllActions()
            updatePlaceholder()
            refreshTypingAttributes()
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
            let previous = (attributedText ?? NSAttributedString(), selectedRange, emptyTailKind)
            // The memory comes first: assigning the content moves the selection, and the
            // typing style of an empty line depends on it.
            emptyTailKind = tail
            attributedText = content
            selectedRange = selection
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
            guard markedTextRange == nil, selectedRange.length == 0 else { return }

            let string = textStorage.string as NSString
            let location = selectedRange.location
            let startsBlock = location == 0 || string.character(at: location - 1) == 0x0A
            let endsBlock = location == string.length || string.character(at: location) == 0x0A
            guard startsBlock, endsBlock else { return }

            var kind = emptyTailKind ?? .paragraph
            if location < string.length,
                let tag = textStorage.attribute(
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
            updatePlaceholder()
            guard markedTextRange == nil, let editor else { return }

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
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n", markedTextRange == nil else { return true }

            var value = model
            let selection = value.range(utf16Location: range.location, length: range.length)
            guard value.blocks[selection.start.block].kind != .paragraph else { return true }

            let caret = selection.isEmpty ? selection.start : value.delete(selection)
            let after = value.splitBlock(at: caret)
            apply(value, caret: after)
            return false
        }

        override func deleteBackward() {
            if markedTextRange == nil, selectedRange.length == 0 {
                var value = model
                let caret = value.position(utf16Offset: selectedRange.location, rounding: .down)
                if caret.offset == 0, value.blocks[caret.block].kind != .paragraph {
                    value.setKind(.paragraph, for: RichRange(at: caret))
                    apply(value, caret: caret)
                    return
                }
            }
            super.deleteBackward()
        }

        // MARK: Formats

        /// Whether `format` can be applied to the selection now: not while a word is being
        /// composed, and not where the text cannot carry it — code has no marks, and a link
        /// needs a selection.
        func isAvailable(_ format: RichFormat) -> Bool {
            guard markedTextRange == nil else { return false }

            let value = model
            return value.isAvailable(
                format,
                in: value.range(utf16Location: selectedRange.location, length: selectedRange.length)
            )
        }

        /// Whether `format` is in effect at the selection, for a checkmark: for a caret, a mark
        /// is what the next typed text gets.
        func isOn(_ format: RichFormat) -> Bool {
            if let mark = format.mark, selectedRange.length == 0 {
                return RichAttributed.marks(of: typingAttributes, style: style).contains(mark)
                    && isAvailable(format)
            }
            let value = model
            let range = value.range(
                utf16Location: selectedRange.location,
                length: selectedRange.length
            )
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
            if let mark = format.mark, selectedRange.length == 0 {
                toggleTypingMark(mark)
                return
            }
            var value = model
            let range = value.range(
                utf16Location: selectedRange.location,
                length: selectedRange.length
            )
            let before = value
            value.apply(format, in: range)
            guard value != before else { return }

            apply(value, selection: selectedRange, actionName: format.command.title)
        }

        private func toggleTypingMark(_ mark: Marks) {
            let value = model
            let caret = value.position(utf16Offset: selectedRange.location, rounding: .down)
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
        /// it. Replaced in tests: the default is an alert over the view.
        var askForLink: ((_ current: URL?, _ apply: @escaping (URL?) -> Void) -> Void)?

        private func requestLink() {
            let value = model
            let selection = selectedRange
            let range = value.range(utf16Location: selection.location, length: selection.length)
            let ask =
                askForLink ?? { [weak self] current, apply in
                    self?.presentLinkAlert(current: current, apply: apply)
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
            becomeFirstResponder()
            selectedRange = selection
        }

        private func presentLinkAlert(current: URL?, apply: @escaping (URL?) -> Void) {
            guard var presenter = window?.rootViewController else { return }

            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            let alert = UIAlertController(title: "Link", message: nil, preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = "https://"
                field.text = current?.absoluteString
                field.keyboardType = .URL
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.clearButtonMode = .whileEditing
                field.accessibilityIdentifier = "richText.linkAddress"
            }
            alert.addAction(
                UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.becomeFirstResponder()
                }
            )
            if current != nil {
                alert.addAction(
                    UIAlertAction(title: "Remove Link", style: .destructive) { _ in apply(nil) }
                )
            }
            alert.addAction(
                UIAlertAction(title: "OK", style: .default) { [weak alert, weak self] _ in
                    let typed = alert?.textFields?.first?.text ?? ""
                    if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        apply(nil)
                    } else if let url = RichFormat.linkURL(from: typed) {
                        apply(url)
                    } else {
                        self?.becomeFirstResponder()
                    }
                }
            )
            presenter.present(alert, animated: true)
        }

        // MARK: Shortcuts and menus

        /// The shortcuts of the formats: the keyboard's list on iPad shows them, and they work
        /// while the view has the keyboard.
        override var keyCommands: [UIKeyCommand]? {
            let own = RichFormat.allCases.compactMap { format -> UIKeyCommand? in
                guard let shortcut = format.command.shortcut else { return nil }

                let key = UIKeyCommand(
                    input: shortcut.input,
                    modifierFlags: UIKeyModifierFlags(shortcut.modifiers),
                    action: #selector(performFormat(_:))
                )
                key.title = format.command.title
                key.discoverabilityTitle = format.command.title
                key.wantsPriorityOverSystemBehavior = true
                return key
            }
            return (super.keyCommands ?? []) + own
        }

        /// A format's shortcut or menu item (`UIMenu.richTextFormat`) reached the view.
        @objc func performFormat(_ sender: Any?) {
            guard let format = RichEditorView.format(of: sender) else { return }

            perform(format)
        }

        static func format(of sender: Any?) -> RichFormat? {
            if let key = sender as? UIKeyCommand, let shortcut = Shortcut(key) {
                return RichFormat.allCases.first { $0.command.shortcut == shortcut }
            }
            if let command = sender as? UICommand, let id = command.propertyList as? String {
                return RichFormat(commandID: id)
            }
            return nil
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            guard action == #selector(performFormat(_:)) else {
                return super.canPerformAction(action, withSender: sender)
            }

            return RichEditorView.format(of: sender).map(isAvailable) ?? false
        }

        @available(tvOS, unavailable)
        override func validate(_ command: UICommand) {
            super.validate(command)
            guard command.action == #selector(performFormat(_:)),
                let format = RichEditorView.format(of: command)
            else { return }

            command.state = isOn(format) ? .on : .off
        }

        /// The formats as a submenu of the edit menu that comes up over a selection or a caret.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            func group(_ formats: [RichFormat]) -> UIMenu {
                UIMenu(
                    options: .displayInline,
                    children: formats.map { format in
                        UIAction(
                            title: format.command.title,
                            attributes: isAvailable(format) ? [] : .disabled,
                            state: isOn(format) ? .on : .off
                        ) { [weak self] _ in
                            self?.perform(format)
                        }
                    }
                )
            }
            let format = UIMenu(
                title: "Format",
                children: [
                    group([.bold, .italic, .underline, .strikethrough, .monospace]),
                    group([.link]),
                    group([.quote, .code]),
                ]
            )
            return UIMenu(children: suggestedActions + [format])
        }

        // MARK: Placeholder and height

        func updatePlaceholder() {
            placeholderLabel.isHidden = !text.isEmpty
            setNeedsLayout()
        }

        /// A view of the same kind to measure with, which never shows.
        private lazy var scratch = UITextView(frame: .zero, textContainer: nil)

        /// How much a line of text adds to the height at `width`, and what the height is
        /// besides the lines — worked out by measuring one line and two, as the text view
        /// spaces its lines by more than its font's line height.
        func lineMetrics(width: Double) -> (lineHeight: Double, insets: Double) {
            scratch.font = font
            scratch.textContainerInset = textContainerInset
            scratch.textContainer.lineFragmentPadding = textContainer.lineFragmentPadding
            let proposal = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            scratch.text = "A"
            let one = Double(scratch.sizeThatFits(proposal).height)
            scratch.text = "A\nA"
            let two = Double(scratch.sizeThatFits(proposal).height)
            return (two - one, one - (two - one))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let left = textContainerInset.left + textContainer.lineFragmentPadding
            let width = max(bounds.width - left - textContainerInset.right - 6, 0)
            let size = placeholderLabel.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            placeholderLabel.frame = CGRect(
                x: left,
                y: textContainerInset.top,
                width: width,
                height: size.height
            )
        }

        // MARK: Delegate

        func textViewDidChange(_ textView: UITextView) {
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
            contentChanged()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshTypingAttributes()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onBeginEditing?()
            editor?.editingChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            editor?.editingChanged(false)
        }
    }

    extension UIMenu {
        /// A menu of the rich text editor's formats for the menu bar on iPad and Mac Catalyst,
        /// added in the app delegate's `buildMenu(with:)`:
        ///
        ///     builder.insertSibling(UIMenu.richTextFormat, afterMenu: .format)
        ///
        /// Its items go to the first responder: they are enabled while a rich text editor has
        /// the keyboard and can apply the format to its selection, and show a checkmark while
        /// the format is in effect there.
        @available(tvOS, unavailable)
        public static var richTextFormat: UIMenu {
            func item(_ format: RichFormat) -> UIMenuElement {
                let command = format.command
                guard let shortcut = command.shortcut else {
                    return UICommand(
                        title: command.title,
                        action: #selector(RichEditorView.performFormat(_:)),
                        propertyList: command.id
                    )
                }

                let key = UIKeyCommand(
                    title: command.title,
                    action: #selector(RichEditorView.performFormat(_:)),
                    input: shortcut.input,
                    modifierFlags: UIKeyModifierFlags(shortcut.modifiers),
                    propertyList: command.id
                )
                key.wantsPriorityOverSystemBehavior = true
                return key
            }
            func group(_ formats: [RichFormat]) -> UIMenu {
                UIMenu(title: "", options: .displayInline, children: formats.map(item))
            }
            return UIMenu(
                title: "Text Format",
                identifier: UIMenu.Identifier("nodes.menu.richTextFormat"),
                children: [
                    group([.bold, .italic, .underline, .strikethrough, .monospace]),
                    group([.link]),
                    group([.quote, .code]),
                ]
            )
        }
    }
#endif
