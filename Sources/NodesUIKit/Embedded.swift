#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import UIKit

    /// The view of an embedded node, in a view that cuts it to what the nodes around it show.
    @MainActor
    final class EmbeddedHolder: NSObject {
        weak var node: EmbeddedNode?
        /// Cuts the view to the part of the node's frame that shows.
        let clip = UIView()
        let view: UIView
        private var watch: Observer?
        /// Set by a view whose height follows its text: given the width the node has, it sets
        /// the node's size, and says whether it changed.
        var fit: (@MainActor (Double) -> Bool)?

        init(node: EmbeddedNode, view: UIView) {
            self.node = node
            self.view = view
            super.init()
            clip.clipsToBounds = true
            clip.addSubview(view)
        }

        /// Puts the view at `frame`, cut to `shown`, both in the node view's points. Where
        /// none of it shows — scrolled away — it is cut to nothing rather than hidden: a
        /// hidden view leaves accessibility, and VoiceOver and the UI tests could not reach
        /// the field to scroll it back.
        func place(frame: CGRect, shown: CGRect?) {
            let cut = shown ?? CGRect(origin: frame.origin, size: .zero)
            clip.frame = cut
            view.frame = frame.offsetBy(dx: -cut.minX, dy: -cut.minY)
        }

        func remove() {
            watch?.cancel()
            if view.isFirstResponder {
                view.resignFirstResponder()
            }
            clip.removeFromSuperview()
        }

        /// Keeps the view showing what the node says, as it changes.
        func watch(_ update: @escaping @MainActor () -> Void) {
            let watch = Observer { [weak self] in self?.watch(update) }
            self.watch = watch
            watch.track(update)
        }
    }

    extension NodeView {
        /// Puts the views of the tree's embedded nodes over the drawing, where the nodes show;
        /// makes the views of new ones and lets go of those gone.
        func placeEmbeddedViews() {
            var kept: [ObjectIdentifier: EmbeddedHolder] = [:]
            var madeViews = false
            for item in host.embeddedItems() {
                let id = ObjectIdentifier(item.node)
                if embedded[id] == nil { madeViews = true }
                guard let holder = embedded[id] ?? makeHolder(for: item.node) else { continue }

                if holder.clip.superview !== self {
                    addSubview(holder.clip)
                }
                // Over the scrolls' physics, which are views too, so that touches reach it.
                bringSubviewToFront(holder.clip)
                holder.place(frame: zoomed(item.frame), shown: item.shownFrame.map(zoomed))
                if holder.fit?(item.frame.size.width) == true {
                    madeViews = true
                    // An editor being edited grew or shrank: once the next pass has laid it out
                    // so, it is kept above the keyboard, where its new last line would be under
                    // it.
                    if holder.view.isFirstResponder
                        || holder.view.subviews.contains(where: \.isFirstResponder)
                    {
                        revealAfterPass = host.passes
                    }
                }
                kept[id] = holder
            }
            for (id, holder) in embedded where kept[id] == nil {
                holder.remove()
            }
            embedded = kept
            if madeViews {
                // A view tells its node its size — when it is made, when its text grows —
                // which the pass in progress has already gone by, and the host does not ask a
                // view to lay out again from inside a pass: ask for the next one.
                setNeedsLayout()
            }
        }

        /// After the keyboard moved and the tree was laid out for it: the field being edited
        /// scrolls into what shows above the keyboard.
        func revealEditingField() {
            // A layout solved in the background lands in a later pass than the one the
            // keyboard moved in: the frames are the keyboard's once a pass is applied.
            guard let pass = revealAfterPass, host.passes > pass else { return }

            revealAfterPass = nil
            if let node = embedded.values.first(where: { $0.view.isFirstResponder })?.node {
                host.reveal(node)
            }
        }

        /// The view of the embedded node `id`.
        func embeddedView(of id: NodeID) -> UIView? {
            embedded.values.first { $0.node?.id == id }?.view
        }

        private func makeHolder(for node: EmbeddedNode) -> EmbeddedHolder? {
            (node as? any UIKitEmbedded)?.makeHolder()
        }
    }

    /// An embedded node the UIKit adapter can show: it makes the holder of its view and keeps
    /// the view in step with the node.
    @MainActor
    protocol UIKitEmbedded: EmbeddedNode {
        func makeHolder() -> EmbeddedHolder
    }

    extension TextField: UIKitEmbedded {
        func makeHolder() -> EmbeddedHolder {
            let view = FieldView(self)
            if let bar = makeKeyboardBar(for: self) {
                view.inputAccessoryView = bar.view
                view.onBeginEditing = bar.refresh
            }
            let holder = EmbeddedHolder(node: self, view: view)
            holder.watch { [weak view, weak self] in
                guard let view, let self else { return }

                let text = text
                if view.text != text { view.text = text }
                view.placeholder = placeholder
                view.returnKeyType = UIReturnKeyType(returnKey)
                view.show(validation)
            }
            onEditingRequest = { [weak view] editing in
                guard let view else { return }

                if editing {
                    view.becomeFirstResponder()
                } else {
                    view.resignFirstResponder()
                }
            }
            preferredSize = LayoutSize(
                width: preferredSize.width,
                height: Double(view.intrinsicContentSize.height)
            )
            return holder
        }
    }

    /// A view of UIKit in the tree: the node lays out at the view's own size (or one given),
    /// the view sits over the drawing at the node's frame, moves with the scrolls around it,
    /// is cut to what the nodes around it show, goes when the node is hidden, and stands
    /// where the node does in the order the tree is read in. The view takes its own touches
    /// and keys.
    ///
    ///     let slider = HostedView(make: { UISlider() }) { $0.value = Float(model.level) }
    ///
    /// `update` runs when the view is made and again whenever a `State` it read changes, to
    /// show the model in the view; what the user does in the view goes back to the model
    /// through the view's own targets and delegates, made in `make`.
    ///
    /// Ownership: the tree keeps the node; the adapter keeps the view while the node is in
    /// the tree, and lets it go after. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class HostedView<View: UIView>: EmbeddedNode, UIKitEmbedded {
        /// How big the node lays out, unless its layout says otherwise.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public enum Sizing: Sendable {
            /// The view's own size (`intrinsicContentSize`, else what its layout needs at the
            /// least), measured when the view is made and by `invalidateSize()`.
            case intrinsic
            /// This size, before the view exists too.
            case fixed(LayoutSize)
        }

        /// The view, while the node is in a tree.
        ///
        /// Ownership: the adapter keeps the view. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public private(set) weak var view: View?

        private let sizing: Sizing
        private let make: @MainActor () -> View
        private let update: (@MainActor (View) -> Void)?

        /// Ownership: keeps the closures; they must not keep the node. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public init(
            sizing: Sizing = .intrinsic,
            make: @escaping @MainActor () -> View,
            update: (@MainActor (View) -> Void)? = nil
        ) {
            self.sizing = sizing
            self.make = make
            self.update = update
            super.init()
            if case .fixed(let size) = sizing {
                preferredSize = size
            }
        }

        /// Measures the view again, for an `.intrinsic` node: call it after the view's content
        /// changed size. Nothing happens while the node is not in a tree.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func invalidateSize() {
            guard case .intrinsic = sizing, let view else { return }

            preferredSize = HostedView.measure(view)
        }

        /// Gives the view the keyboard, where it takes it.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: `unfocus()`.
        public func focus() {
            view?.becomeFirstResponder()
        }

        /// Takes the keyboard from the view.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func unfocus() {
            view?.resignFirstResponder()
        }

        /// Whether the view has the keyboard now. Not observable: ask when it matters.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var hasKeyboard: Bool { view?.isFirstResponder ?? false }

        func makeHolder() -> EmbeddedHolder {
            let view = make()
            self.view = view
            let holder = EmbeddedHolder(node: self, view: view)
            if let update {
                holder.watch { [weak view] in
                    guard let view else { return }

                    update(view)
                }
            }
            invalidateSize()
            return holder
        }

        private static func measure(_ view: UIView) -> LayoutSize {
            var size = view.intrinsicContentSize
            if size.width < 0 || size.height < 0 {
                size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            }
            return LayoutSize(
                width: Double(max(size.width, 0)),
                height: Double(max(size.height, 0))
            )
        }
    }

    /// A text field showing a `TextField` node: what the user types goes to the node.
    final class FieldView: UITextField, UITextFieldDelegate {
        weak var field: TextField?
        /// What to do when the field takes the keyboard: the keyboard bar's turn.
        var onBeginEditing: (@MainActor () -> Void)?

        init(_ field: TextField) {
            self.field = field
            super.init(frame: .zero)
            delegate = self
            borderStyle = .roundedRect
            font = .preferredFont(forTextStyle: .body)
            adjustsFontForContentSizeCategory = true
            accessibilityIdentifier = field.placeholder
            isSecureTextEntry = field.isSecure
            clearButtonMode = UITextField.ViewMode(field.clearButton)
            switch field.content {
            case .text:
                break
            case .name:
                textContentType = .name
                autocapitalizationType = .words
            case .email:
                textContentType = .emailAddress
                keyboardType = .emailAddress
                typedByHand()
            case .password:
                textContentType = .password
                typedByHand()
            case .newPassword:
                textContentType = .newPassword
                typedByHand()
            case .phone:
                textContentType = .telephoneNumber
                keyboardType = .phonePad
            case .oneTimeCode:
                textContentType = .oneTimeCode
                keyboardType = .numberPad
            case .url:
                textContentType = .URL
                keyboardType = .URL
                typedByHand()
            }
            addTarget(self, action: #selector(changed), for: .editingChanged)
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// A red edge and the message read after the field's label, while the text is not
        /// right.
        func show(_ validation: FieldValidation) {
            if case .invalid(let message) = validation {
                layer.borderColor = UIColor.systemRed.cgColor
                layer.borderWidth = 1
                layer.cornerRadius = 6
                accessibilityHint = message
            } else {
                layer.borderWidth = 0
                accessibilityHint = nil
            }
        }

        /// Text that is not words: no capitals, no autocorrection, no spell checking.
        private func typedByHand() {
            autocapitalizationType = .none
            autocorrectionType = .no
            spellCheckingType = .no
        }

        @objc func changed() {
            guard let field else { return }

            field.userChanged(text ?? "")
            // The node may have cut what was typed to its limit.
            if text != field.text { text = field.text }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            onBeginEditing?()
            field?.editingChanged(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            field?.editingChanged(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            field?.userSubmitted()
            return false
        }
    }

    /// The bar above the keyboard a text input shows (`KeyboardBar`), as a view of the
    /// keyboard's kind holding a tree of nodes, and what to do when the input takes the
    /// keyboard: the bar's buttons are made right for where the input is. `nil` for none.
    @MainActor
    func makeKeyboardBar(for input: any TextInputNode) -> (
        view: UIView, refresh: @MainActor () -> Void
    )? {
        let root: Node
        var refresh: @MainActor () -> Void = {}
        switch input.effectiveKeyboardBar {
        case .none:
            return nil
        case .navigation:
            let bar = KeyboardNavigationBar(input: input)
            refresh = { bar.refresh() }
            root = bar
        case .custom(let make):
            root = make()
        }

        let content = NodeView(root: root)
        content.zoom = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 0, height: 44),
            inputViewStyle: .keyboard
        )
        container.allowsSelfSizing = true
        container.addSubview(content)
        // As high as its tree, at the width of the screen: the system gives the width.
        let width = UIScreen.main.bounds.width
        let height = max(content.sizeThatFits(CGSize(width: width, height: 10_000)).height, 44)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: height),
        ])
        return (container, refresh)
    }

    extension UITextField.ViewMode {
        init(_ button: ClearButton) {
            switch button {
            case .never: self = .never
            case .whileEditing: self = .whileEditing
            case .always: self = .always
            }
        }
    }

    extension TextEditor: UIKitEmbedded {
        func makeHolder() -> EmbeddedHolder {
            let view = EditorView(self)
            if let bar = makeKeyboardBar(for: self) {
                view.inputAccessoryView = bar.view
                view.onBeginEditing = bar.refresh
            }
            let holder = EmbeddedHolder(node: self, view: view)
            holder.watch { [weak view, weak self] in
                guard let view, let self else { return }

                let text = text
                if view.text != text {
                    view.text = text
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

    /// A text view showing a `TextEditor` node: what the user types goes to the node. A text
    /// view has no placeholder, so a label stands where the first line goes while it is empty.
    final class EditorView: UITextView, UITextViewDelegate {
        weak var editor: TextEditor?
        /// What to do when the editor takes the keyboard: the keyboard bar's turn.
        var onBeginEditing: (@MainActor () -> Void)?
        let placeholderLabel = UILabel()

        init(_ editor: TextEditor) {
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

        func textViewDidChange(_ textView: UITextView) {
            guard let editor else { return }

            editor.userChanged(text)
            // The node may have cut what was typed to its limit.
            if text != editor.text { text = editor.text }
            updatePlaceholder()
            // Its height follows its text: lay out again.
            editor.setNeedsLayout()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onBeginEditing?()
            editor?.editingChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            editor?.editingChanged(false)
        }
    }

    extension UIReturnKeyType {
        init(_ key: ReturnKey) {
            switch key {
            case .default: self = .default
            case .next: self = .next
            case .done: self = .done
            case .send: self = .send
            case .search: self = .search
            }
        }
    }

    // MARK: - The keyboard

    /// Follows the keyboard for the tree. A TV has no keyboard over the screen, and the
    /// guide it would follow is unavailable there. The conformance is unavailable too, yet a
    /// cast still finds it at run time: the view checks the device itself.
    @MainActor
    protocol KeyboardFollowing {
        /// Starts following the keyboard: its guide lays the view out as the keyboard moves.
        func followKeyboard()
        /// Tells the host how far the keyboard comes up over the view now.
        func readKeyboard()
    }

    @available(tvOS, unavailable)
    extension NodeView: KeyboardFollowing {
        func followKeyboard() {
            guard UIDevice.current.userInterfaceIdiom != .tv else { return }

            if #available(iOS 17, *) {
                keyboardLayoutGuide.usesBottomSafeArea = false
                // A floating keyboard on iPad does not push the page: the guide follows the
                // docked keyboard only, as the system's own apps do, and the user moves a
                // floating one. The overlap is worked out in this view's coordinates, so a
                // window smaller than the screen gets the part of the keyboard over it.
                keyboardLayoutGuide.followsUndockedKeyboard = false
            }
            // A view tied to the guide: the node view lays out again whenever the guide moves
            // — with the keyboard's animation, and at every frame of a drag down.
            let probe = UIView()
            probe.isHidden = true
            probe.isUserInteractionEnabled = false
            probe.translatesAutoresizingMaskIntoConstraints = false
            addSubview(probe)
            keyboardProbe = probe
            NSLayoutConstraint.activate([
                probe.leadingAnchor.constraint(equalTo: leadingAnchor),
                probe.widthAnchor.constraint(equalToConstant: 1),
                probe.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                probe.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
            ])
        }

        func readKeyboard() {
            guard keyboardProbe != nil else { return }

            let overlap = bounds.maxY - keyboardLayoutGuide.layoutFrame.minY
            let inset = max(Double(overlap), 0) / factor
            guard inset != host.keyboardInset else { return }

            revealAfterPass = host.passes
            let duration = UIView.inheritedAnimationDuration
            if let animation = keyboardAnimation(duration: duration) {
                withAnimation(animation) {
                    host.keyboardInset = inset
                }
            } else {
                host.keyboardInset = inset
            }
        }

        /// The animation the system moves the keyboard with, as the tree moves with it: the
        /// view tied to the keyboard's guide is animated by the same block, and the animation
        /// it was given is the system's own — a spring on current systems, with its
        /// physical numbers. Where it is not a spring, the block's duration with an ease is
        /// the nearest there is; `nil` outside any animation.
        func keyboardAnimation(duration: Double) -> Animation? {
            if let layer = keyboardProbe?.layer {
                for key in layer.animationKeys() ?? [] {
                    if let spring = layer.animation(forKey: key) as? CASpringAnimation {
                        return .spring(
                            mass: Double(spring.mass),
                            stiffness: Double(spring.stiffness),
                            damping: Double(spring.damping),
                            duration: spring.settlingDuration
                        )
                    }
                }
            }
            return duration > 0 ? .easeInOut(duration: duration) : nil
        }
    }
#endif
