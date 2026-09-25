#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import UIKit
    import os

    /// Where the adapter writes layout reports.
    private let layoutLog = Logger(subsystem: "Nodes", category: "layout")

    /// A view that shows a tree of nodes: it lays the tree out in its bounds and draws it into
    /// its layer. Outside, it is an ordinary view — frames, Auto Layout (through
    /// `intrinsicContentSize`), or a place in another view's `layoutSpec()`.
    ///
    /// Ownership: the view owns the host and, through it, the tree. Isolation: MainActor.
    /// Errors: none. Cancellation: `host.detach()` ends the tree's updates.
    @MainActor
    public final class NodeView: UIView {
        /// Ownership: owned by the view. Isolation: MainActor. Errors: none. Cancellation:
        /// `detach()`.
        public let host: NodeHost

        fileprivate let renderer = LayerRenderer()
        /// Holds the tree's layers, scaled by `zoom` from its top left corner.
        private let contentLayer = CALayer()
        private var isLayingOut = false
        private var accessibilityCache: [UIAccessibilityElement]?
        /// The focus items of the tree, one per focusable node, kept while the node is: the
        /// focus system recognizes the focused item by identity.
        private var focusItemsByNode: [NodeID: NodeFocusItem] = [:]
        private var focusOrder: [NodeFocusItem] = []
        /// A focus container for each scroll, kept while the scroll is: the focus system
        /// searches its whole content and scrolls it to what it focuses.
        private var scrollContainers: [NodeID: ScrollFocusContainer] = [:]
        /// The items and scroll containers right under the view, not inside a scroll.
        private var topFocusItems: [any UIFocusItem] = []
        /// A select press that began on a focused node and has not ended yet.
        private var isSelecting = false
        /// A focus guide over each focus section, kept while the section is.
        private var sectionGuides: [NodeID: SectionGuide] = [:]
        /// The keyboard focus ring, off a TV.
        private let focusRing = FocusRing()
        /// A node the app asked to focus (`NodeHost.requestFocus`), until the focus system
        /// moves the focus.
        private var requestedFocus: NodeID?
        /// The platform's scrolling of each scroll of the tree, off a TV.
        private var scrollDrivers: [NodeID: ScrollDriver] = [:]

        /// A view showing `root`.
        ///
        /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(root: Node) {
            host = NodeHost(root: root, size: LayoutSize(width: 0, height: 0))
            super.init(frame: .zero)
            contentLayer.anchorPoint = .zero
            layer.addSublayer(contentLayer)
            isAccessibilityElement = false
            host.onNeedsLayout = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.invalidateIntrinsicContentSize()
                self.setNeedsLayout()
            }
            host.onNeedsRender = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.setNeedsLayout()
            }
            host.onFocusRequest = { [weak self] node in
                self?.requestFocus(on: node)
            }
            #if DEBUG
                // Problems in the layouts, and a trace the app asked for, go to the unified log
                // while debugging; a pass without either stays quiet.
                host.onLayoutReport = { report in
                    guard report.hasProblems || !report.trace.isEmpty else { return }

                    for line in report.lines {
                        layoutLog.log("\(line, privacy: .public)")
                    }
                }
            #endif
        }

        /// Not supported: a node tree is built in code.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: always fails. Cancellation: not
        /// applicable.
        public required init?(coder: NSCoder) {
            nil
        }

        /// Ownership: returns the root the host keeps. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var root: Node { host.root }

        /// How many times bigger than its points the tree is shown: at 2, it is laid out in
        /// half the view's size and drawn twice as big. Text is drawn for the final size and
        /// stays sharp; taps, focus and accessibility frames follow. `nil`, the default, is 2
        /// on a TV — seen from across a room, sizes made for a phone read about right there —
        /// and 1 elsewhere.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var zoom: Double? {
            didSet {
                guard zoom != oldValue else { return }

                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        /// `zoom`, or the device's, kept positive.
        private var factor: Double {
            let zoom = zoom ?? (traitCollection.userInterfaceIdiom == .tv ? 2 : 1)
            return zoom > 0 ? zoom : 1
        }

        /// Lays the tree out in the bounds and draws it.
        ///
        /// Ownership: updates the tree and the layers. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func layoutSubviews() {
            super.layoutSubviews()
            isLayingOut = true
            defer { isLayingOut = false }

            let content = LayoutSize(
                width: Double(bounds.width) / factor,
                height: Double(bounds.height) / factor
            )
            let widthChanged = host.size.width != content.width
            host.size = content
            // Frames snap to, and text is drawn for, the pixels of the zoomed size.
            host.scale =
                Double(traitCollection.displayScale > 0 ? traitCollection.displayScale : 1) * factor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.bounds = CGRect(x: 0, y: 0, width: content.width, height: content.height)
            contentLayer.position = .zero
            contentLayer.transform = CATransform3DMakeScale(CGFloat(factor), CGFloat(factor), 1)
            CATransaction.commit()
            host.direction =
                effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.focusLook = isTV ? .lift : .ring
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(
                    host.root,
                    in: contentLayer,
                    scale: host.scale,
                    animation: host.renderAnimation
                )
                host.didRender()
                updateScrollDrivers()
                updateAfterMove()
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .layoutChanged, argument: nil)
                }
            } else if !host.scrolledSinceRender.isEmpty {
                // Only scrolls moved: their content moves, and what depends on where nodes
                // show — the ring, focus and accessibility frames — follows.
                let scrolled = host.scrolledSinceRender
                renderer.renderScrolls(scrolled)
                host.didRender()
                for scroll in scrolled {
                    scrollDrivers[scroll.id]?.follow(factor: factor)
                }
                updateAfterMove()
            }
            if widthChanged {
                // The height the tree wants depends on the width it has.
                invalidateIntrinsicContentSize()
            }
        }

        /// Brings what depends on where the nodes show in line after a drawing.
        private func updateAfterMove() {
            accessibilityCache = nil
            updateFocusItems()
            if usesFocus, !isTV {
                focusRing.show(
                    around: host.focusedItem,
                    color: tintColor.cgColor,
                    in: contentLayer
                )
            }
        }

        // MARK: - Scrolling

        /// Brings the scroll drivers in line with the tree's scrolls after a drawing: one per
        /// visible scroll, over its frame. On a TV the focus scrolls, not the touch surface.
        private func updateScrollDrivers() {
            var kept: [NodeID: ScrollDriver] = [:]
            if !isTV {
                for item in host.scrollItems() {
                    let driver =
                        scrollDrivers[item.scroll.id] ?? ScrollDriver(in: self, scroll: item.scroll)
                    driver.place(zoomed(item.frame), factor: factor)
                    kept[item.scroll.id] = driver
                }
            }
            for (id, driver) in scrollDrivers where kept[id] == nil {
                driver.remove()
            }
            scrollDrivers = kept
        }

        /// Touches over the scrolls' physics come to this view, like any other: the scroll
        /// views only lend their pans, which are on this view.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            if let hit, scrollDrivers.values.contains(where: { $0.owns(hit) }) {
                return self
            }
            return hit
        }

        /// A drag starts a scroll's pan only where that scroll is the innermost one under the
        /// finger able to move along its axis, so a row of cards scrolls sideways inside a
        /// list that scrolls up and down.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard
                let driver = scrollDrivers.values.first(where: {
                    $0.pan === gestureRecognizer
                })
            else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }

            let location = gestureRecognizer.location(in: self)
            let point = LayoutPoint(x: Double(location.x) / factor, y: Double(location.y) / factor)
            return host.scrolls(at: point).first { $0.axis == driver.scroll?.axis }
                === driver.scroll
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func sizeThatFits(_ size: CGSize) -> CGSize {
            let limited = size.width > 0 && size.width < CGFloat.greatestFiniteMagnitude
            let fitting = host.fittingSize(
                width: limited ? .definite(Double(size.width) / factor) : .maxContent
            )
            return CGSize(width: fitting.width * factor, height: fitting.height * factor)
        }

        /// Presses on nodes with `onTap`; other touches go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // A touch on content still gliding stops it, and does nothing else — as in any
            // scroll view.
            let gliding = scrollDrivers.values.filter(\.isGliding)
            guard gliding.isEmpty else {
                for driver in gliding {
                    driver.stop()
                }
                return
            }
            guard let touch = touches.first, host.pointerDown(at: point(of: touch)) else {
                super.touchesBegan(touches, with: event)
                return
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first {
                host.pointerUp(at: point(of: touch))
            }
            super.touchesEnded(touches, with: event)
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            host.pointerCancelled()
            super.touchesCancelled(touches, with: event)
        }

        private func point(of touch: UITouch) -> LayoutPoint {
            let location = touch.location(in: self)
            return LayoutPoint(x: Double(location.x) / factor, y: Double(location.y) / factor)
        }

        // MARK: - Focus

        /// Whether the platform's focus system moves between the tree's nodes: on a TV, and on
        /// iPad with a keyboard (the system turns it on only then).
        private var usesFocus: Bool {
            isTV || traitCollection.userInterfaceIdiom == .pad
        }

        private var isTV: Bool {
            traitCollection.userInterfaceIdiom == .tv
        }

        /// The tree's focusable nodes as focus items, added to UIKit's own (subviews).
        ///
        /// Ownership: the view keeps the items. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func focusItems(in rect: CGRect) -> [any UIFocusItem] {
            // The scroll views giving the scrolls' physics are subviews, but hold nothing to
            // focus: the scrolls' own focus containers stand for them.
            let own = super.focusItems(in: rect).filter { item in
                !scrollDrivers.values.contains { driver in
                    (item as? UIView).map(driver.owns) ?? false
                }
            }
            return own + topFocusItems.filter { $0.frame.intersects(rect) }
        }

        /// The focused node's item, so a focus update keeps the focus where it is.
        ///
        /// Ownership: returns an item the view keeps. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            if let requested = requestedFocus, let item = focusItemsByNode[requested] {
                return [item]
            }
            if let focused = host.focusedNode, let item = focusItemsByNode[focused] {
                return [item]
            }
            return super.preferredFocusEnvironments
        }

        /// Tells the host where the platform moved the focus: to one of the tree's nodes, or
        /// away from them.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            super.didUpdateFocus(in: context, with: coordinator)
            requestedFocus = nil
            if let next = context.nextFocusedItem as? NodeFocusItem, next.view === self {
                host.focus(next.node)
                // Return and Space come to the first responder, as the remote's buttons do.
                if !isFirstResponder {
                    becomeFirstResponder()
                }
            } else if host.focusedNode != nil {
                host.focus(nil)
            }
            updateSectionGuides()
        }

        /// Remote and keyboard presses come to the first responder, and a focus item that is
        /// not a view is not one: the view takes the role where the tree takes focus — on a TV
        /// at once, on iPad when one of its nodes gets the focus.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var canBecomeFirstResponder: Bool { usesFocus }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, isTV {
                becomeFirstResponder()
            }
        }

        /// The remote's select button presses the focused node; other presses go on up the
        /// responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.contains(where: NodeView.selects), host.selectBegan() {
                isSelecting = true
            } else {
                super.pressesBegan(presses, with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if isSelecting, presses.contains(where: NodeView.selects) {
                isSelecting = false
                host.selectEnded()
            } else {
                super.pressesEnded(presses, with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            if isSelecting {
                isSelecting = false
                host.pointerCancelled()
            } else {
                super.pressesCancelled(presses, with: event)
            }
        }

        /// Asks the focus system to focus the node's item; a node without one yet gets it
        /// after the next drawing. Without a focus system (iPhone) the host just notes it.
        private func requestFocus(on node: NodeID) {
            guard usesFocus else {
                host.focus(node)
                return
            }

            requestedFocus = node
            applyFocusRequest()
        }

        private func applyFocusRequest() {
            guard let requestedFocus, let item = focusItemsByNode[requestedFocus] else { return }

            item.setNeedsFocusUpdate()
            item.updateFocusIfNeeded()
        }

        /// The remote's select button, or Return or Space on a keyboard.
        private static func selects(_ press: UIPress) -> Bool {
            press.type == .select || press.key?.keyCode == .keyboardReturnOrEnter
                || press.key?.keyCode == .keyboardSpacebar
        }

        /// Brings the focus items in line with the tree after a drawing. Asks the focus system
        /// to look again when the focused node is gone, and when the first items appear — it
        /// may have looked for them before the tree was laid out.
        private func updateFocusItems() {
            guard usesFocus else { return }

            let hadItems = !focusOrder.isEmpty
            let containers = updateScrollContainers()
            var kept: [NodeID: NodeFocusItem] = [:]
            focusOrder = host.focusItems().map { item in
                let focusItem =
                    focusItemsByNode[item.node] ?? NodeFocusItem(view: self, node: item.node)
                focusItem.frame = zoomed(item.frame)
                focusItem.parent = self
                if let node = host.node(item.node), let scroll = node.enclosingScroll,
                    let container = containers[scroll.id], let frame = scroll.frame(of: node)
                {
                    // Inside a scroll the item is the scroll's, framed in its content.
                    focusItem.frame = zoomed(frame)
                    focusItem.parent = container
                }
                kept[item.node] = focusItem
                return focusItem
            }
            let lostFocus = focusItemsByNode.values.contains {
                $0.isFocused && kept[$0.node] == nil
            }
            focusItemsByNode = kept
            for container in containers.values {
                container.items =
                    focusOrder.filter { $0.parent === container }
                    + containers.values.filter { $0.parent === container }
            }
            topFocusItems =
                focusOrder.filter { $0.parent === self }
                + containers.values.filter { $0.parent === self }
            updateSections()
            if lostFocus || (!hadItems && !focusOrder.isEmpty) {
                setNeedsFocusUpdate()
            }
            applyFocusRequest()
        }

        /// Brings the scrolls' focus containers in line with the tree's scrolls: each framed in
        /// the content of the scroll around it, or in the view.
        private func updateScrollContainers() -> [NodeID: ScrollFocusContainer] {
            var kept: [NodeID: ScrollFocusContainer] = [:]
            for item in host.scrollItems() {
                kept[item.scroll.id] =
                    scrollContainers[item.scroll.id]
                    ?? ScrollFocusContainer(view: self, scroll: item.scroll)
            }
            for (id, container) in kept {
                guard let scroll = container.scroll else { continue }

                container.factor = factor
                container.frame = zoomed(item(frameOf: scroll))
                container.parent = self
                if let outer = scroll.enclosingScroll, let outerContainer = kept[outer.id],
                    let frame = outer.frame(of: scroll)
                {
                    container.frame = zoomed(frame)
                    container.parent = outerContainer
                }
            }
            scrollContainers = kept
            return kept
        }

        /// The frame of `scroll` in the root's coordinates, where it shows.
        private func item(frameOf scroll: Scroll) -> LayoutRect {
            host.scrollItems().first { $0.scroll === scroll }?.frame ?? scroll.frame
        }

        /// Brings the section guides in line with the tree's focus sections.
        private func updateSections() {
            var kept: [NodeID: SectionGuide] = [:]
            for section in host.focusSections() {
                let guide = sectionGuides[section.node] ?? SectionGuide(in: self)
                guide.place(zoomed(section.frame))
                guide.items = section.items
                kept[section.node] = guide
            }
            for (id, guide) in sectionGuides where kept[id] == nil {
                guide.remove()
            }
            sectionGuides = kept
            updateSectionGuides()
        }

        /// Points each guide at the node to focus in its section, and turns off the guide of
        /// the section that has the focus: moves inside it go by the nodes themselves.
        private func updateSectionGuides() {
            let focused = host.focusedNode
            for guide in sectionGuides.values {
                if let focused, guide.items.contains(focused) {
                    guide.lastFocused = focused
                    guide.guide.isEnabled = false
                } else {
                    guide.guide.isEnabled = true
                }
                let target =
                    guide.lastFocused.flatMap { guide.items.contains($0) ? $0 : nil }
                    ?? guide.items.first
                guide.guide.preferredFocusEnvironments =
                    target.flatMap { focusItemsByNode[$0] }.map { [$0] } ?? []
            }
        }

        /// The tree's accessibility elements (`NodeHost.accessibilityItems()`), rebuilt after
        /// every drawing.
        ///
        /// Ownership: the view keeps the elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override var accessibilityElements: [Any]? {
            get {
                if let accessibilityCache { return accessibilityCache }

                let elements = host.accessibilityItems().map {
                    NodeAccessibilityElement(container: self, item: $0)
                }
                accessibilityCache = elements
                return elements
            }
            set {}
        }

        /// No width of its own — the surroundings give it one (constraints, SwiftUI, a
        /// frame), as for a paragraph of text — and the height the tree takes at the current
        /// width. A tree's widest content is a poor width to ask for: one long line of text
        /// can make it wider than the screen.
        public override var intrinsicContentSize: CGSize {
            let width =
                bounds.width > 0
                ? AvailableSpace.definite(Double(bounds.width) / factor) : .maxContent
            return CGSize(
                width: UIView.noIntrinsicMetric,
                height: host.fittingSize(width: width).height * factor
            )
        }

        /// A frame in the tree's points, in the view's.
        fileprivate func zoomed(_ frame: LayoutRect) -> CGRect {
            CGRect(
                x: frame.origin.x * factor,
                y: frame.origin.y * factor,
                width: frame.size.width * factor,
                height: frame.size.height * factor
            )
        }
    }

    extension NodeView {
        /// The layer drawing `node`, for tests and debugging.
        ///
        /// Ownership: returns a layer the view's renderer owns. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public func renderedLayer(for node: Node) -> CALayer? {
            renderer.layer(for: node)
        }
    }

    extension UIView {
        /// Shows `node` in a new `NodeView` added as a subview, and returns it for sizing
        /// and positioning.
        ///
        /// Ownership: the view keeps the new subview, which keeps the node. Isolation:
        /// MainActor. Errors: none. Cancellation: remove the subview and call
        /// `host.detach()`.
        @discardableResult
        public func addSubnode(_ node: Node) -> NodeView {
            let view = NodeView(root: node)
            addSubview(view)
            return view
        }
    }

    /// The platform's scrolling for one scroll of the tree. An empty `UIScrollView` over the
    /// scroll's frame gives the physics — the drag, the glide, the bounce at the ends — and
    /// its offset moves the scroll; the tree's layers do all the drawing. Its pan is added to
    /// the node view, which takes the touches over it (`hitTest`) so taps still reach the
    /// nodes. The scroll view stays shown and interactive: hidden, or with interaction off,
    /// its pan never begins.
    @MainActor
    final class ScrollDriver: NSObject, UIScrollViewDelegate {
        private(set) weak var scroll: Scroll?
        private let physics = UIScrollView()
        /// Set while the driver moves the scroll view itself, so it does not hear itself.
        private var isFollowing = false
        private var factor = 1.0

        var pan: UIPanGestureRecognizer { physics.panGestureRecognizer }

        /// Moving with the finger, or on its own after it: a touch then stops it.
        var isGliding: Bool { physics.isDecelerating && !isPastTheEnds }

        init(in view: UIView, scroll: Scroll) {
            self.scroll = scroll
            super.init()
            physics.delegate = self
            physics.backgroundColor = nil
            physics.contentInsetAdjustmentBehavior = .never
            physics.showsVerticalScrollIndicator = false
            physics.showsHorizontalScrollIndicator = false
            physics.alwaysBounceVertical = scroll.axis == .vertical
            physics.alwaysBounceHorizontal = scroll.axis == .horizontal
            view.addSubview(physics)
            view.addGestureRecognizer(physics.panGestureRecognizer)
        }

        /// Puts the scroll view over the scroll's frame, `frame` in the node view's points,
        /// with the content's extent, and at the scroll's offset unless a finger moves it.
        func place(_ frame: CGRect, factor: Double) {
            guard let scroll else { return }

            isFollowing = true
            defer { isFollowing = false }

            self.factor = factor
            physics.frame = frame
            let content = scroll.contentBounds
            // The content may start before the scroll's origin (a row laid out from the
            // right); the insets let the offset go there.
            physics.contentInset = UIEdgeInsets(
                top: CGFloat(-content.origin.y * factor),
                left: CGFloat(-content.origin.x * factor),
                bottom: 0,
                right: 0
            )
            physics.contentSize = CGSize(
                width: (content.origin.x + content.size.width) * factor,
                height: (content.origin.y + content.size.height) * factor
            )
            follow(factor: factor)
        }

        /// Moves the scroll view to the scroll's offset, when code moved the scroll rather
        /// than a finger.
        func follow(factor: Double) {
            guard let scroll, !physics.isTracking, !physics.isDecelerating else { return }

            isFollowing = true
            defer { isFollowing = false }

            let offset = scroll.shownOffset
            physics.contentOffset = CGPoint(x: offset.x * factor, y: offset.y * factor)
        }

        func owns(_ view: UIView) -> Bool {
            view === physics
        }

        func stop() {
            physics.setContentOffset(physics.contentOffset, animated: false)
        }

        func remove() {
            physics.panGestureRecognizer.view?.removeGestureRecognizer(physics.panGestureRecognizer)
            physics.removeFromSuperview()
        }

        private var isPastTheEnds: Bool {
            scroll.map { $0.overscroll != .zero } ?? false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isFollowing else { return }

            let offset = scrollView.contentOffset
            scroll?.platformDidScroll(
                to: LayoutPoint(x: Double(offset.x) / factor, y: Double(offset.y) / factor)
            )
        }
    }

    /// The focus guide over one focus section, framed by constraints to the view's edges.
    @MainActor
    private final class SectionGuide {
        let guide = UIFocusGuide()
        var items: [NodeID] = []
        var lastFocused: NodeID?
        private let left: NSLayoutConstraint
        private let top: NSLayoutConstraint
        private let width: NSLayoutConstraint
        private let height: NSLayoutConstraint

        init(in view: UIView) {
            view.addLayoutGuide(guide)
            left = guide.leftAnchor.constraint(equalTo: view.leftAnchor)
            top = guide.topAnchor.constraint(equalTo: view.topAnchor)
            width = guide.widthAnchor.constraint(equalToConstant: 0)
            height = guide.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([left, top, width, height])
        }

        func place(_ frame: CGRect) {
            left.constant = frame.minX
            top.constant = frame.minY
            width.constant = frame.width
            height.constant = frame.height
        }

        func remove() {
            guide.owningView?.removeLayoutGuide(guide)
        }
    }

    /// A scroll of a tree for the platform's focus system: an item that does not take focus
    /// itself but holds the focusable nodes inside the scroll, framed in its content. The
    /// focus system then looks for the next node in the whole content, not only in what
    /// shows, and moves `contentOffset` to show it — as it does for a `UIScrollView`. Its
    /// coordinates are the content's, shifted by the offset, as a scroll view's bounds are.
    @MainActor
    final class ScrollFocusContainer: NSObject, UIFocusItem, UIFocusItemScrollableContainer,
        UICoordinateSpace
    {
        private(set) weak var view: NodeView?
        private(set) weak var scroll: Scroll?
        /// The view, or the container of the scroll around this one.
        weak var parent: (any UIFocusEnvironment & UICoordinateSpace)?
        /// In the parent's coordinates.
        var frame: CGRect = .zero
        var factor = 1.0
        /// The focusable nodes and the scrolls right inside.
        var items: [any UIFocusItem] = []

        init(view: NodeView, scroll: Scroll) {
            self.view = view
            self.scroll = scroll
        }

        // The item: never focused itself.

        var canBecomeFocused: Bool { false }
        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
        var parentFocusEnvironment: (any UIFocusEnvironment)? { parent }
        var focusItemContainer: (any UIFocusItemContainer)? { self }

        func setNeedsFocusUpdate() {
            view?.setNeedsFocusUpdate()
        }

        func updateFocusIfNeeded() {
            view?.updateFocusIfNeeded()
        }

        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }

        func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {}

        // The container.

        var coordinateSpace: any UICoordinateSpace { self }

        func focusItems(in rect: CGRect) -> [any UIFocusItem] {
            items.filter { $0.frame.intersects(rect) }
        }

        var contentOffset: CGPoint {
            get {
                let offset = scroll?.shownOffset ?? .zero
                return CGPoint(x: offset.x * factor, y: offset.y * factor)
            }
            set {
                // The focus system moves it to show the node it focuses; it moves as focus
                // moves, with its animation.
                withAnimation(scroll?.host?.focusAnimation) {
                    scroll?.contentOffset = LayoutPoint(
                        x: Double(newValue.x) / factor,
                        y: Double(newValue.y) / factor
                    )
                }
            }
        }

        var contentSize: CGSize {
            guard let content = scroll?.contentBounds else { return .zero }

            return CGSize(
                width: (content.origin.x + content.size.width) * factor,
                height: (content.origin.y + content.size.height) * factor
            )
        }

        var visibleSize: CGSize { bounds.size }

        // The coordinate space: the content, starting at the offset.

        var bounds: CGRect {
            CGRect(origin: contentOffset, size: frame.size)
        }

        func convert(_ point: CGPoint, to coordinateSpace: any UICoordinateSpace) -> CGPoint {
            let inParent = CGPoint(
                x: point.x - bounds.minX + frame.minX,
                y: point.y - bounds.minY + frame.minY
            )
            return parent?.convert(inParent, to: coordinateSpace) ?? inParent
        }

        func convert(_ point: CGPoint, from coordinateSpace: any UICoordinateSpace) -> CGPoint {
            let inParent = parent?.convert(point, from: coordinateSpace) ?? point
            return CGPoint(
                x: inParent.x - frame.minX + bounds.minX,
                y: inParent.y - frame.minY + bounds.minY
            )
        }

        func convert(_ rect: CGRect, to coordinateSpace: any UICoordinateSpace) -> CGRect {
            CGRect(origin: convert(rect.origin, to: coordinateSpace), size: rect.size)
        }

        func convert(_ rect: CGRect, from coordinateSpace: any UICoordinateSpace) -> CGRect {
            CGRect(origin: convert(rect.origin, from: coordinateSpace), size: rect.size)
        }
    }

    /// One focusable node of a tree for the platform's focus system. It keeps the node's
    /// identity and its frame from the last drawing; it never holds the node itself.
    @MainActor
    final class NodeFocusItem: NSObject, UIFocusItem {
        let node: NodeID
        private(set) weak var view: NodeView?
        /// The view, or the focus container of the scroll the node is in.
        weak var parent: (any UIFocusEnvironment)?
        /// In the parent's coordinates: the view's, or the scroll's content.
        var frame: CGRect = .zero

        init(view: NodeView, node: NodeID) {
            self.view = view
            self.node = node
        }

        var isFocused: Bool {
            UIFocusSystem.focusSystem(for: self)?.focusedItem === self
        }

        var canBecomeFocused: Bool { true }

        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
        var parentFocusEnvironment: (any UIFocusEnvironment)? { parent ?? view }
        /// The container of the item's own children, not of the item: a node is focused as a
        /// whole, so there are none. The view here made the focus engine find the item's
        /// siblings as its children, and the remote could not move the focus.
        var focusItemContainer: (any UIFocusItemContainer)? { nil }

        func setNeedsFocusUpdate() {
            UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self)
        }

        func updateFocusIfNeeded() {
            UIFocusSystem.focusSystem(for: self)?.updateFocusIfNeeded()
        }

        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }

        func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {}
    }

    /// One accessibility element of a node tree. It keeps the node's identity and asks the
    /// host to act on it; it never holds the node itself.
    @MainActor
    final class NodeAccessibilityElement: UIAccessibilityElement {
        private let node: NodeID
        private weak var host: NodeHost?

        init(container: NodeView, item: AccessibilityItem) {
            node = item.node
            host = container.host
            super.init(accessibilityContainer: container)
            accessibilityLabel = item.label
            accessibilityValue = item.value
            accessibilityHint = item.hint
            accessibilityTraits = NodeAccessibilityElement.traits(item.traits)
            accessibilityFrameInContainerSpace = container.zoomed(item.frame)
        }

        override func accessibilityActivate() -> Bool {
            host?.activate(node) ?? false
        }

        private static func traits(_ traits: AccessibilityTraits) -> UIAccessibilityTraits {
            var result: UIAccessibilityTraits = []
            if traits.contains(.button) { result.insert(.button) }
            if traits.contains(.header) { result.insert(.header) }
            if traits.contains(.image) { result.insert(.image) }
            if traits.contains(.staticText) { result.insert(.staticText) }
            if traits.contains(.selected) { result.insert(.selected) }
            if traits.contains(.notEnabled) { result.insert(.notEnabled) }
            return result
        }
    }
#endif
