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
    /// through the model's rules, and what they change can be undone.
    final class RichEditorView: UITextView, UITextViewDelegate {
        weak var editor: RichTextEditor?
        /// What to do when the editor takes the keyboard: the keyboard bar's turn.
        var onBeginEditing: (@MainActor () -> Void)?
        let placeholderLabel = UILabel()

        init(_ editor: RichTextEditor) {
            self.editor = editor
            super.init(frame: .zero, textContainer: nil)
            delegate = self
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
        }

        required init?(coder: NSCoder) {
            nil
        }

        // MARK: Content

        private var style: RichAttributedStyle {
            var style = RichAttributedStyle.standard
            style.font = .preferredFont(forTextStyle: .body)
            return style
        }

        /// What the view holds, as a value.
        var model: RichText {
            RichAttributed.richText(from: attributedText, style: style)
        }

        /// Shows `text`, set by code: what the view could undo was about other text.
        func show(_ text: RichText) {
            let caret = selectedRange
            attributedText = RichAttributed.attributedString(text, style: style)
            selectedRange = NSRange(location: min(caret.location, textStorage.length), length: 0)
            undoManager?.removeAllActions()
            updatePlaceholder()
        }

        /// Puts `content` in place of the whole text with the caret at `selection`, the way the
        /// rules of the model change the text; the change can be undone, and undoing it can be
        /// undone.
        private func replaceContent(_ content: NSAttributedString, selection: NSRange) {
            let previous = (attributedText ?? NSAttributedString(), selectedRange)
            attributedText = content
            selectedRange = selection
            undoManager?.registerUndo(withTarget: self) { view in
                view.replaceContent(previous.0, selection: previous.1)
                view.contentChanged()
            }
        }

        /// Reads the view back into the node, unless a word is being composed: its letters are
        /// not the text yet.
        func contentChanged() {
            updatePlaceholder()
            guard markedTextRange == nil, let editor else { return }

            editor.userChanged(model)
            editor.setNeedsLayout()
        }

        private func apply(_ text: RichText, caret: RichPosition) {
            let location = text.utf16Offset(of: caret)
            replaceContent(
                RichAttributed.attributedString(text, style: style),
                selection: NSRange(location: location, length: 0)
            )
            contentChanged()
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
            contentChanged()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onBeginEditing?()
            editor?.editingChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            editor?.editingChanged(false)
        }
    }
#endif
