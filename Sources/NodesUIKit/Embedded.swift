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
            for item in host.embeddedItems() {
                let id = ObjectIdentifier(item.node)
                guard let holder = embedded[id] ?? makeHolder(for: item.node) else { continue }

                if holder.clip.superview !== self {
                    addSubview(holder.clip)
                }
                // Over the scrolls' physics, which are views too, so that touches reach it.
                bringSubviewToFront(holder.clip)
                holder.place(frame: zoomed(item.frame), shown: item.shownFrame.map(zoomed))
                kept[id] = holder
            }
            for (id, holder) in embedded where kept[id] == nil {
                holder.remove()
            }
            embedded = kept
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
            guard let field = node as? TextField else { return nil }

            let view = FieldView(field)
            let holder = EmbeddedHolder(node: field, view: view)
            holder.watch { [weak view, weak field] in
                guard let view, let field else { return }

                let text = field.text
                if view.text != text { view.text = text }
                view.placeholder = field.placeholder
                view.returnKeyType = UIReturnKeyType(field.returnKey)
            }
            field.onEditingRequest = { [weak view] editing in
                guard let view else { return }

                if editing {
                    view.becomeFirstResponder()
                } else {
                    view.resignFirstResponder()
                }
            }
            let height = Double(view.intrinsicContentSize.height)
            field.preferredSize = LayoutSize(width: field.preferredSize.width, height: height)
            return holder
        }
    }

    /// A text field showing a `TextField` node: what the user types goes to the node.
    final class FieldView: UITextField, UITextFieldDelegate {
        weak var field: TextField?

        init(_ field: TextField) {
            self.field = field
            super.init(frame: .zero)
            delegate = self
            borderStyle = .roundedRect
            font = .preferredFont(forTextStyle: .body)
            adjustsFontForContentSizeCategory = true
            accessibilityIdentifier = field.placeholder
            switch field.content {
            case .text:
                break
            case .name:
                textContentType = .name
                autocapitalizationType = .words
            case .email:
                textContentType = .emailAddress
                keyboardType = .emailAddress
                autocapitalizationType = .none
                autocorrectionType = .no
                spellCheckingType = .no
            }
            addTarget(self, action: #selector(changed), for: .editingChanged)
        }

        required init?(coder: NSCoder) {
            nil
        }

        @objc private func changed() {
            field?.userChanged(text ?? "")
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
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
            if duration > 0 {
                withAnimation(.easeInOut(duration: duration)) {
                    host.keyboardInset = inset
                }
            } else {
                host.keyboardInset = inset
            }
        }
    }
#endif
