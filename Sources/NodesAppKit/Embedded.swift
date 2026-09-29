#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore

    /// The view of an embedded node, in a view that cuts it to what the nodes around it show.
    @MainActor
    final class EmbeddedHolder: NSObject {
        weak var node: EmbeddedNode?
        /// Cuts the view to the part of the node's frame that shows.
        let clip = FlippedClipView()
        let view: NSView
        private var watch: Observer?

        init(node: EmbeddedNode, view: NSView) {
            self.node = node
            self.view = view
            super.init()
            clip.clipsToBounds = true
            clip.addSubview(view)
        }

        /// Puts the view at `frame`, cut to `shown`, both in the node view's points. Where
        /// none of it shows — scrolled away — it is cut to nothing rather than hidden: a
        /// hidden view leaves accessibility, and the field could not be reached to scroll it
        /// back.
        func place(frame: CGRect, shown: CGRect?) {
            let cut = shown ?? CGRect(origin: frame.origin, size: .zero)
            clip.frame = cut
            view.frame = frame.offsetBy(dx: -cut.minX, dy: -cut.minY)
        }

        func remove() {
            watch?.cancel()
            if let window = view.window,
                window.firstResponder === view
                    || (view as? NSTextField)?.currentEditor() === window.firstResponder
            {
                window.makeFirstResponder(nil)
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

    /// A view with its top left as origin, like the node view it sits in.
    final class FlippedClipView: NSView {
        override var isFlipped: Bool { true }
    }

    extension NodeNSView {
        /// Puts the views of the tree's embedded nodes over the drawing, where the nodes show;
        /// makes the views of new ones and lets go of those gone.
        func placeEmbeddedViews() {
            var kept: [ObjectIdentifier: EmbeddedHolder] = [:]
            var order: [NSView] = []
            for item in host.embeddedItems() {
                let id = ObjectIdentifier(item.node)
                guard let holder = embedded[id] ?? makeHolder(for: item.node) else { continue }

                if holder.clip.superview !== self {
                    addSubview(holder.clip)
                }
                holder.place(
                    frame: embeddedRect(item.frame),
                    shown: item.shownFrame.map(embeddedRect)
                )
                order.append(holder.clip)
                kept[id] = holder
            }
            for (id, holder) in embedded where kept[id] == nil {
                holder.remove()
            }
            embedded = kept
            // In the order of the tree, each above the one before. A view taken out of its
            // superview and added again loses the keyboard, so they are moved only when the
            // order is not right.
            let placed = subviews.filter { view in order.contains { $0 === view } }
            if zip(placed, order).contains(where: { $0 !== $1 }) {
                for clip in order {
                    addSubview(clip)
                }
            }
        }

        /// The view of the embedded node `id`.
        func embeddedView(of id: NodeID) -> NSView? {
            embedded.values.first { $0.node?.id == id }?.view
        }

        private func makeHolder(for node: EmbeddedNode) -> EmbeddedHolder? {
            (node as? any AppKitEmbedded)?.makeHolder()
        }
    }

    /// An embedded node the AppKit adapter can show: it makes the holder of its view and keeps
    /// the view in step with the node.
    @MainActor
    protocol AppKitEmbedded: EmbeddedNode {
        func makeHolder() -> EmbeddedHolder
    }

    extension TextField: AppKitEmbedded {
        func makeHolder() -> EmbeddedHolder {
            let view = FieldView(self)
            let holder = EmbeddedHolder(node: self, view: view)
            holder.watch { [weak view, weak self] in
                guard let view, let self else { return }

                let text = text
                if view.stringValue != text { view.stringValue = text }
                view.placeholderString = placeholder
            }
            onEditingRequest = { [weak view] editing in
                guard let view, let window = view.window else { return }

                if editing {
                    window.makeFirstResponder(view)
                } else if view.currentEditor() != nil {
                    window.makeFirstResponder(nil)
                }
            }
            preferredSize = LayoutSize(
                width: preferredSize.width,
                height: Double(view.intrinsicContentSize.height)
            )
            return holder
        }
    }

    /// A text field showing a `TextField` node: what the user types goes to the node.
    final class FieldView: NSTextField, NSTextFieldDelegate {
        weak var field: TextField?

        init(_ field: TextField) {
            self.field = field
            super.init(frame: .zero)
            delegate = self
            isEditable = true
            isBezeled = true
            bezelStyle = .roundedBezel
            font = .systemFont(ofSize: NSFont.systemFontSize)
            setAccessibilityIdentifier(field.placeholder)
            switch field.content {
            case .text:
                break
            case .name:
                contentType = .name
            case .email:
                contentType = .emailAddress
            }
        }

        required init?(coder: NSCoder) {
            nil
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            field?.editingChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            field?.userChanged(stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            field?.editingChanged(false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }

            field?.userSubmitted()
            return true
        }
    }

    /// A view of AppKit in the tree: the node lays out at the view's own size (or one given),
    /// the view sits over the drawing at the node's frame, moves with the scrolls around it,
    /// is cut to what the nodes around it show, goes when the node is hidden, and stands
    /// where the node does in the order the tree is read in. The view takes its own mouse and
    /// keys.
    ///
    ///     let slider = HostedView(make: { NSSlider() }) { $0.doubleValue = model.level }
    ///
    /// `update` runs when the view is made and again whenever a `State` it read changes, to
    /// show the model in the view; what the user does in the view goes back to the model
    /// through the view's own target and delegate, made in `make`.
    ///
    /// Ownership: the tree keeps the node; the adapter keeps the view while the node is in
    /// the tree, and lets it go after. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class HostedView<View: NSView>: EmbeddedNode, AppKitEmbedded {
        /// How big the node lays out, unless its layout says otherwise.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public enum Sizing: Sendable {
            /// The view's own size (`intrinsicContentSize`, else `fittingSize`), measured
            /// when the view is made and by `invalidateSize()`.
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
            view?.window?.makeFirstResponder(view)
        }

        /// Takes the keyboard from the view.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func unfocus() {
            guard let view, let window = view.window, hasKeyboard else { return }

            window.makeFirstResponder(nil)
        }

        /// Whether the view has the keyboard now. Not observable: ask when it matters.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var hasKeyboard: Bool {
            guard let view, let responder = view.window?.firstResponder else { return false }

            return responder === view || (responder as? NSView)?.isDescendant(of: view) == true
        }

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

        private static func measure(_ view: NSView) -> LayoutSize {
            var size = view.intrinsicContentSize
            if size.width < 0 || size.height < 0 {
                size = view.fittingSize
            }
            return LayoutSize(
                width: Double(max(size.width, 0)),
                height: Double(max(size.height, 0))
            )
        }
    }
#endif
