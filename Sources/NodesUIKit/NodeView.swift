#if canImport(UIKit)
    import LayoutCore
    import LayoutUIKit
    import Nodes
    import NodesRender
    import ThemeCore
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
        /// The accessibility element of each node, kept while the node is one: VoiceOver
        /// keeps its place by the element's identity, and a scroll redraws many times a
        /// second.
        private var accessibilityByNode: [NodeID: NodeAccessibilityElement] = [:]
        /// The elements in reading order; `nil` after a drawing, until asked for.
        private var accessibilityOrder: [Any]?
        /// A container for each list laid out by where it shows, kept while the list is.
        private var accessibilityLists: [NodeID: ListAccessibilityContainer] = [:]
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
        /// The presses the tree took, until they end: the rest of them is the tree's too.
        private var takenPresses: Set<UIPress> = []
        /// The long press select becomes if it is held down, until then.
        private var holding: DispatchWorkItem?
        /// A focus guide over each focus section, kept while the section is.
        private var sectionGuides: [NodeID: SectionGuide] = [:]
        private var sectionEntries: [NodeID: SectionEntry] = [:]
        /// The keyboard focus ring, off a TV.
        private let focusRing = FocusRing()
        /// A node the app asked to focus (`NodeHost.requestFocus`), until the focus system
        /// moves the focus.
        private var requestedFocus: NodeID?
        /// A move of the focus the focus system could not make, which the view makes: the node
        /// it goes to, and until when it tries.
        private var reaching: (node: NodeID, until: Double, asked: Bool)?
        /// The check, after the focus system scrolled a scroll, that the focused node shows.
        private var focusScrollCheck: DispatchWorkItem?
        /// The platform's scrolling of each scroll of the tree, off a TV.
        private var scrollDrivers: [NodeID: ScrollDriver] = [:]
        /// The display's frames, while a scroll moves frame by frame.
        private var frameLink: CADisplayLink?
        /// The views of the tree's embedded nodes.
        var embedded: [ObjectIdentifier: EmbeddedHolder] = [:]
        /// The layout pass in which the keyboard last moved: the first pass after it scrolls
        /// the field being edited into view.
        var revealAfterPass: Int?
        /// A hidden view tied to the keyboard's guide, which lays the view out as the keyboard
        /// moves; `nil` where no keyboard comes over the screen.
        var keyboardProbe: UIView?
        /// Takes the pointer's moves and requests for tips, where there is a pointer.
        var pointer: PointerTracker?

        /// A view showing `root`.
        ///
        /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(root: Node) {
            host = NodeHost(root: root, size: LayoutSize(width: 0, height: 0))
            super.init(frame: .zero)
            // Out of a window, the tree does not show.
            host.isShown = false
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
            host.onNeedsFrames = { [weak self] in
                self?.startFrames()
            }
            // Before any scroll, so that a node's drag works outside scrolls too.
            _ = dragPan
            (self as? any KeyboardFollowing)?.followKeyboard()
            followPointer()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusMovementFailed(_:)),
                name: UIFocusSystem.movementDidFailNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(systemSettingsChanged),
                name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil
            )
            if #available(iOS 17, tvOS 17, *) {
                registerForTraitChanges(
                    [
                        UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                        UITraitPreferredContentSizeCategory.self,
                    ],
                    action: #selector(systemSettingsChanged)
                )
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
        var factor: Double {
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

            updateConditions()
            (self as? any KeyboardFollowing)?.readKeyboard()
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
            revealEditingField()
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
            placeEmbeddedViews()
            accessibilityOrder = nil
            if UIAccessibility.isVoiceOverRunning {
                // VoiceOver reads the frame of the element it is on without asking the view
                // again: bring it up to date now.
                _ = updateAccessibilityElements()
            }
            updateFocusItems()
            if usesFocus, !isTV {
                focusRing.show(
                    around: host.focusedItem,
                    color: tintColor.cgColor,
                    in: contentLayer
                )
            }
            pointerContentMoved()
        }

        // MARK: - Scrolling

        private func startFrames() {
            guard frameLink == nil else { return }

            let link = CADisplayLink(
                target: FrameTarget(self),
                selector: #selector(FrameTarget.tick(_:))
            )
            link.add(to: .main, forMode: .common)
            frameLink = link
        }

        /// A frame of the display is coming: the scrolls moving frame by frame move to where
        /// they are when it shows, and the tree is drawn for it.
        fileprivate func displayFrame(_ link: CADisplayLink) {
            host.advanceFrames(to: link.targetTimestamp)
            guard !host.needsFrames else { return }

            link.invalidate()
            frameLink = nil
        }

        /// The driver of `scroll`, while it shows.
        func scrollDriver(for scroll: Scroll) -> ScrollDriver? {
            scrollDrivers[scroll.id]
        }

        /// Brings the scroll drivers in line with the tree's scrolls after a drawing: one per
        /// visible scroll, over its frame. On a TV the focus scrolls, not the touch surface.
        private func updateScrollDrivers() {
            var kept: [NodeID: ScrollDriver] = [:]
            if !isTV {
                for item in host.scrollItems() {
                    let driver =
                        scrollDrivers[item.scroll.id] ?? newScrollDriver(for: item.scroll)
                    driver.place(zoomed(item.frame), factor: factor)
                    kept[item.scroll.id] = driver
                }
            }
            for (id, driver) in scrollDrivers where kept[id] == nil {
                driver.remove()
            }
            scrollDrivers = kept
        }

        /// A driver for `scroll`, whose pan waits for a node's drag to decline the touch: a row
        /// swiped aside does not scroll the list.
        private func newScrollDriver(for scroll: Scroll) -> ScrollDriver {
            let driver = ScrollDriver(in: self, scroll: scroll)
            driver.pan.require(toFail: dragPan)
            return driver
        }

        /// Drags of nodes (`Node.dragAxis`). Not on a TV: its touch surface moves the focus.
        /// The device tells, not the traits: the view is not in a window yet when it is made.
        private lazy var dragPan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragPanned(_:)))
            if UIDevice.current.userInterfaceIdiom != .tv {
                addGestureRecognizer(pan)
            }
            return pan
        }()

        /// The axis the drag under way goes along, and where it began.
        private var dragStart: (axis: ScrollAxis, point: LayoutPoint)?

        /// Whether a pan at `location`, in the view's points, moving at `velocity`, drags a
        /// node: it goes mostly along an axis some node there is dragged along.
        func dragAxis(at location: CGPoint, velocity: CGPoint) -> ScrollAxis? {
            let axis: ScrollAxis = abs(velocity.x) > abs(velocity.y) ? .horizontal : .vertical
            let point = LayoutPoint(x: Double(location.x) / factor, y: Double(location.y) / factor)
            return host.canDrag(at: point, along: axis) ? axis : nil
        }

        @objc private func dragPanned(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: self)
            let moved = LayoutPoint(
                x: Double(translation.x) / factor,
                y: Double(translation.y) / factor
            )
            switch pan.state {
            case .began:
                let location = pan.location(in: self)
                let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                guard let axis = dragAxis(at: start, velocity: pan.velocity(in: self)) else {
                    return
                }

                let point = LayoutPoint(x: Double(start.x) / factor, y: Double(start.y) / factor)
                dragStart = (axis, point)
                host.dragBegan(at: point, along: axis)
                host.dragMoved(by: moved)
            case .changed:
                host.dragMoved(by: moved)
            case .ended:
                let velocity = pan.velocity(in: self)
                host.dragEnded(
                    by: moved,
                    velocity: LayoutPoint(
                        x: Double(velocity.x) / factor,
                        y: Double(velocity.y) / factor
                    )
                )
                dragStart = nil
            default:
                host.dragCancelled()
                dragStart = nil
            }
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
            if gestureRecognizer === dragPan {
                // Where the finger went down, not where the pan noticed it.
                let location = dragPan.location(in: self)
                let translation = dragPan.translation(in: self)
                let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                return dragAxis(at: start, velocity: dragPan.velocity(in: self)) != nil
            }
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

        /// Presses on nodes with `onTap`; other touches go on up the responder chain. A touch
        /// makes the view the first responder when its nodes carry out commands, as a click
        /// does on a Mac, and commands then go to the node touched and the nodes around it.
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
            if !isFirstResponder, host.handlesCommands {
                becomeFirstResponder()
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
            // focus: the scrolls' own focus containers stand for them. Nor does the view
            // following the keyboard.
            let own = super.focusItems(in: rect).filter { item in
                guard let view = item as? UIView else { return true }

                return view !== keyboardProbe
                    && !scrollDrivers.values.contains { driver in driver.owns(view) }
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
            reaching = nil
            if let entry = context.nextFocusedItem as? SectionEntry, entry.view === self {
                // The focus system has scrolled the section into sight to focus its entry;
                // the node the entry leads to shows now, and the focus goes on to it. The update
                // is asked of this view, which holds the entry that has the focus, and the view
                // prefers the node: asked of the node's own item, which does not hold the
                // focus, the focus system ignores it. The node that had the focus keeps it
                // until then.
                guard let target = entry.target else { return }

                requestedFocus = target
                DispatchQueue.main.async { [weak self] in
                    self?.setNeedsFocusUpdate()
                    self?.updateFocusIfNeeded()
                }
                return
            }
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
        /// at once, on iPad when one of its nodes gets the focus — and where its nodes carry out
        /// commands, whose shortcuts and menu items reach them through it: when it is touched.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var canBecomeFirstResponder: Bool { usesFocus || host.handlesCommands }

        /// In a window, and not hidden, the tree shows (`NodeHost.isShown`): a screen under the
        /// next one in a navigation controller, or in a tab not chosen, is taken out of the
        /// window, and its nodes stop their work for showing until it comes back.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, isTV {
                becomeFirstResponder()
            }
            updateConditions()
            updateShown()
        }

        /// Hidden, the tree does not show. Only the view's own flag counts: UIKit does not tell
        /// a view that one around it was hidden.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var isHidden: Bool {
            didSet { updateShown() }
        }

        private func updateShown() {
            host.isShown = window != nil && !isHidden
        }

        /// Takes the system's settings into the host's conditions: the interface style,
        /// contrast, text size and Reduce Motion. They apply at once — the system animates its
        /// own switch, and the tree does not add one of its own.
        private func updateConditions() {
            let conditions = DisplayConditions(traitCollection)
            guard conditions != host.conditions else { return }

            withAnimation(nil) {
                host.conditions = conditions
            }
        }

        @objc private func systemSettingsChanged() {
            updateConditions()
        }

        /// The remote's select button presses the focused node, and held down carries out
        /// `Command.longPress` instead while a node would (`Node.handle`); the Menu button
        /// carries out `Command.back`, and Play/Pause `Command.playPause`. Presses the tree does
        /// not take go on up the responder chain — Menu, at the top of an app on a TV, leaves
        /// the app.
        ///
        /// Ownership: keeps the presses it takes until they end. Isolation: MainActor. Errors:
        /// none. Cancellation: none.
        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let others = presses.filter { !take($0) }
            if !others.isEmpty {
                super.pressesBegan(others, with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let others = presses.filter { !release($0, ended: true) }
            if !others.isEmpty {
                super.pressesEnded(others, with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            let others = presses.filter { !release($0, ended: false) }
            if !others.isEmpty {
                super.pressesCancelled(others, with: event)
            }
        }

        /// A press went down; returns whether the tree takes it.
        private func take(_ press: UIPress) -> Bool {
            let taken: Bool
            if NodeView.selects(press) {
                isSelecting = host.selectBegan()
                let holds = press.type == .select && host.canPerform(.longPress)
                if holds {
                    startHolding()
                }
                taken = isSelecting || holds
            } else if press.type == .menu {
                taken = host.perform(.back)
            } else if press.type == .playPause {
                taken = host.perform(.playPause)
            } else {
                taken = false
            }
            if taken {
                takenPresses.insert(press)
            }
            return taken
        }

        /// A press came up, or the system took it away; returns whether it was the tree's.
        private func release(_ press: UIPress, ended: Bool) -> Bool {
            guard takenPresses.remove(press) != nil else { return false }

            if NodeView.selects(press) {
                holding?.cancel()
                holding = nil
                if isSelecting {
                    isSelecting = false
                    if ended {
                        host.selectEnded()
                    } else {
                        host.pointerCancelled()
                    }
                }
            }
            return true
        }

        /// Select held long enough is a long press: the focused node is let go without a tap,
        /// and the command is carried out.
        private func startHolding() {
            holding?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }

                holding = nil
                if isSelecting {
                    isSelecting = false
                    host.pointerCancelled()
                }
                host.perform(.longPress)
            }
            holding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NodeView.holdTime, execute: work)
        }

        /// Seconds select is held down before it is a long press.
        static let holdTime = 0.5

        // MARK: - Reach

        /// The focus system found nothing to move the focus to from one of the tree's nodes.
        /// It looks only in a strip in the direction pressed, as wide as the focused node, and
        /// only so far: it widens the strip's length four times, to about five windows. A node
        /// beside the strip, or further along it, under blocks with nothing to focus is out of
        /// its reach. The view then finds the nearest node that way in the whole content of
        /// the node's scroll itself, scrolls it into sight, and moves the focus there.
        @objc private func focusMovementFailed(_ notification: Notification) {
            guard usesFocus, reaching == nil,
                let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext,
                let from = context.previouslyFocusedItem as? NodeFocusItem, from.view === self
            else { return }
            // With nowhere to go that way, the focused node may still take the arrow.
            if let move = FocusMove(context.focusHeading), takesMove(move) { return }
            guard let target = reachTarget(from: from, heading: context.focusHeading) else {
                return
            }

            reaching = (target, CACurrentMediaTime() + NodeView.reachTime, false)
            requestedFocus = target
            withAnimation(host.focusAnimation) {
                host.reveal(target)
            }
            continueReach()
        }

        /// Whether the focused node takes an arrow (`NodeHost.moveCommand`). The focus system
        /// asks several times for one press — once for each place it looks at — and each
        /// answer to the node would do what the arrow does again: the first answer holds until
        /// the main queue turns.
        func takesMove(_ move: FocusMove) -> Bool {
            if let answered = moveAnswered, answered.move == move { return answered.taken }

            let taken = host.moveCommand(move)
            moveAnswered = (move, taken)
            DispatchQueue.main.async { [weak self] in
                self?.moveAnswered = nil
            }
            return taken
        }

        /// The answer to an arrow, for as long as the press asks.
        private var moveAnswered: (move: FocusMove, taken: Bool)?

        /// Seconds a move the view makes has to get there; then it gives up.
        private static let reachTime = 2.0

        /// Where a move from `from` toward `heading` goes: the nearest node that way in the
        /// scroll `from` is in, else in the scroll around it, and so on out — a scroll across
        /// inside a scroll down has nothing above its row. `nil` when no scroll has one.
        func reachTarget(from: NodeFocusItem, heading: UIFocusHeading) -> NodeID? {
            var origin = from.frame
            var current = from.parent as? ScrollFocusContainer
            while let container = current {
                if let target = reachTarget(
                    from: from,
                    at: origin,
                    heading: heading,
                    in: container
                ) {
                    return target
                }
                // Out to the scroll around it: its content starts at its frame there, moved
                // back by its offset.
                let offset = container.contentOffset
                origin = origin.offsetBy(
                    dx: container.frame.minX - offset.x,
                    dy: container.frame.minY - offset.y
                )
                current = container.parent as? ScrollFocusContainer
            }
            return nil
        }

        /// The node nearest to `origin`, where `from` is, that lies wholly toward `heading`
        /// in the whole content of `container`, preferring ones straight ahead: the distance
        /// ahead counts once, the distance aside twice. A section the focus is not in counts as a whole, and leads to
        /// its node focused last, else its first; a scroll inside counts with its nodes.
        /// `nil` when there is none that way.
        func reachTarget(
            from: NodeFocusItem,
            at origin: CGRect,
            heading: UIFocusHeading,
            in container: ScrollFocusContainer
        ) -> NodeID? {
            let sections = container.items.compactMap { $0 as? SectionEntry }
                .filter { $0.canBecomeFocused }
            var best: (node: NodeID, score: CGFloat)?
            func consider(_ node: NodeID, _ frame: CGRect) {
                guard let score = NodeView.score(from: origin, to: frame, heading: heading),
                    score < best?.score ?? .infinity
                else { return }

                best = (node, score)
            }
            // `place` takes a frame in the items' scroll to `container`'s content.
            func look(in items: [any UIFocusItem], place: (CGRect) -> CGRect) {
                for item in items {
                    switch item {
                    case let entry as SectionEntry:
                        if entry.canBecomeFocused, let target = entry.target {
                            consider(target, place(entry.frame))
                        }
                    case let node as NodeFocusItem:
                        // A node in a section the focus is not in is reached by the section.
                        guard node !== from,
                            !sections.contains(where: { $0.items.contains(node.node) })
                        else { continue }

                        consider(node.node, place(node.frame))
                    case let inner as ScrollFocusContainer:
                        // Its content starts at its frame, moved back by its offset.
                        let offset = inner.contentOffset
                        let frame = inner.frame
                        look(in: inner.items) { rect in
                            place(
                                rect.offsetBy(dx: frame.minX - offset.x, dy: frame.minY - offset.y)
                            )
                        }
                    default:
                        continue
                    }
                }
            }
            look(in: container.items) { $0 }
            return best?.node
        }

        /// How far `frame` is from `origin` toward `heading` — ahead once, aside twice — or
        /// `nil` when it is not wholly that way.
        static func score(from origin: CGRect, to frame: CGRect, heading: UIFocusHeading)
            -> CGFloat?
        {
            func gap(_ a: CGFloat, _ aEnd: CGFloat, _ b: CGFloat, _ bEnd: CGFloat) -> CGFloat {
                max(0, max(b - aEnd, a - bEnd))
            }
            let ahead: CGFloat
            let aside: CGFloat
            if heading.contains(.down) {
                ahead = frame.minY - origin.maxY
                aside = gap(origin.minX, origin.maxX, frame.minX, frame.maxX)
            } else if heading.contains(.up) {
                ahead = origin.minY - frame.maxY
                aside = gap(origin.minX, origin.maxX, frame.minX, frame.maxX)
            } else if heading.contains(.right) {
                ahead = frame.minX - origin.maxX
                aside = gap(origin.minY, origin.maxY, frame.minY, frame.maxY)
            } else if heading.contains(.left) {
                ahead = origin.minX - frame.maxX
                aside = gap(origin.minY, origin.maxY, frame.minY, frame.maxY)
            } else {
                return nil
            }
            guard ahead >= 0 else { return nil }

            return ahead + 2 * aside
        }

        /// After a drawing: once the node a move the view makes goes to shows where it is
        /// laid out now, asks for the focus there — of the view, which holds the focus, and
        /// prefers the node (`preferredFocusEnvironments`). Gives up after `reachTime`.
        private func continueReach() {
            guard let reaching else { return }

            guard CACurrentMediaTime() < reaching.until,
                let item = focusItemsByNode[reaching.node]
            else {
                self.reaching = nil
                if requestedFocus == reaching.node {
                    requestedFocus = nil
                }
                return
            }
            guard shows(item), !reaching.asked else { return }

            self.reaching?.asked = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reaching?.node == reaching.node else { return }

                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
                // One try: the focus is there now, or the focus system would not move it.
                if self.reaching?.node == reaching.node {
                    self.reaching = nil
                    self.requestedFocus = nil
                }
            }
        }

        /// Whether `item` shows in the window of its scroll, whole — or, larger than it,
        /// over it.
        private func shows(_ item: NodeFocusItem) -> Bool {
            guard let container = item.parent as? ScrollFocusContainer else { return true }

            let window = container.bounds
            return window.contains(item.frame)
                || (item.frame.height > window.height && item.frame.intersects(window))
        }

        /// The focus system scrolled `container`: once it stops, the focused node shows. On
        /// a far move it stops the scroll short of the node it focused, or past it, and the
        /// node is left out of sight; the scroll then goes on to it.
        func focusScrollMoved(_ container: ScrollFocusContainer) {
            focusScrollCheck?.cancel()
            let check = DispatchWorkItem { [weak self, weak container] in
                guard let self, let container, let focused = self.host.focusedNode,
                    let item = self.focusItemsByNode[focused], item.parent === container,
                    !self.shows(item)
                else { return }

                withAnimation(self.host.focusAnimation) {
                    self.host.reveal(focused)
                }
            }
            focusScrollCheck = check
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NodeView.focusScrollPause,
                execute: check
            )
        }

        /// Seconds without a move of a scroll by the focus system after which it has stopped.
        private static let focusScrollPause = 0.15

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
            if reaching != nil {
                continueReach()
            } else {
                applyFocusRequest()
            }
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

        /// Brings the sections' guides and entries in line with the tree's focus sections: a
        /// guide in the view for a section outside any scroll, an entry in the scroll's focus
        /// container for one inside. A guide lives where the section shows on the screen, and
        /// the focus system does not reach one whose section is scrolled out of sight; an
        /// entry is one of the scroll's items, found in its whole content like the nodes.
        private func updateSections() {
            var guides: [NodeID: SectionGuide] = [:]
            var entries: [NodeID: SectionEntry] = [:]
            for section in host.focusSections() {
                if let node = host.node(section.node), let scroll = node.enclosingScroll,
                    let container = scrollContainers[scroll.id], let frame = scroll.frame(of: node)
                {
                    let entry =
                        sectionEntries[section.node] ?? SectionEntry(view: self, node: section.node)
                    entry.frame = zoomed(frame)
                    entry.parent = container
                    entry.items = section.items
                    container.items.append(entry)
                    entries[section.node] = entry
                    continue
                }

                let guide = sectionGuides[section.node] ?? SectionGuide(in: self)
                guide.place(zoomed(section.frame))
                guide.items = section.items
                guides[section.node] = guide
            }
            for (id, guide) in sectionGuides where guides[id] == nil {
                guide.remove()
            }
            sectionGuides = guides
            sectionEntries = entries
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
            for entry in sectionEntries.values {
                if let focused, entry.items.contains(focused) {
                    entry.lastFocused = focused
                    entry.isEnabled = false
                } else {
                    entry.isEnabled = true
                }
            }
        }

        /// The tree's accessibility elements (`NodeHost.accessibilityItems()`), brought up to
        /// date after every drawing; a node keeps its element.
        ///
        /// Ownership: the view keeps the elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override var accessibilityElements: [Any]? {
            get { accessibilityOrder ?? updateAccessibilityElements() }
            set {}
        }

        /// The element of the node a touch at `point` reaches, or of the nearest node around it
        /// that has one; `nil` when none of them does. Found as touches find their node, so a
        /// node drawn over another — a section's title stuck over the rows — hides the
        /// elements under it: an element is where it can be touched.
        ///
        /// The system asks this from iOS and tvOS 18 on; before, it goes by the elements'
        /// frames.
        ///
        /// Ownership: returns an element the view keeps. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        @available(iOS 18, tvOS 18, *)
        public override func accessibilityHitTest(_ point: CGPoint, event: UIEvent?) -> Any? {
            _ = accessibilityElements
            var node = host.root.hitTest(
                LayoutPoint(x: Double(point.x) / factor, y: Double(point.y) / factor)
            )
            while let current = node {
                if let element = accessibilityByNode[current.id] { return element }
                node = current.supernode
            }
            return nil
        }

        private func updateAccessibilityElements() -> [Any] {
            var kept: [NodeID: NodeAccessibilityElement] = [:]
            var keptLists: [NodeID: ListAccessibilityContainer] = [:]
            func element(
                _ item: AccessibilityItem,
                in container: AnyObject,
                origin: CGPoint = .zero
            ) -> NodeAccessibilityElement {
                let element =
                    accessibilityByNode[item.node] ?? NodeAccessibilityElement(container: self)
                element.accessibilityContainer = container
                let frame = zoomed(item.frame)
                element.update(item, frame: frame.offsetBy(dx: -origin.x, dy: -origin.y))
                kept[item.node] = element
                return element
            }
            var order: [Any] = []
            for entry in host.accessibilityEntries() {
                switch entry {
                case .element(let item):
                    // An embedded node is its platform view, which speaks for itself.
                    if let view = embeddedView(of: item.node) {
                        order.append(view)
                    } else {
                        order.append(element(item, in: self))
                    }
                case .list(let list, let items):
                    let container =
                        accessibilityLists[list.node]
                        ?? ListAccessibilityContainer(view: self, list: list.node)
                    let frame = zoomed(list.frame)
                    container.accessibilityFrameInContainerSpace = frame
                    container.update(
                        list,
                        elements: items.map { item in
                            (
                                item.listItem?.index ?? list.laidOut.lowerBound,
                                element(item, in: container, origin: frame.origin)
                            )
                        }
                    )
                    keptLists[list.node] = container
                    order.append(container)
                }
            }
            accessibilityByNode = kept
            accessibilityLists = keptLists
            accessibilityOrder = order
            return order
        }

        /// Where the item at `index` of `list` is expected, in the view's points.
        fileprivate func accessibilityFrame(ofItem index: Int, in list: NodeID) -> CGRect? {
            host.accessibilityFrame(ofItem: index, in: list).map(zoomed)
        }

        /// VoiceOver moved to an item of `list` not laid out: the list scrolls to it and lays
        /// it out, and VoiceOver moves on to the item's first element.
        fileprivate func accessibilityFocused(item index: Int, in list: NodeID) {
            guard host.revealItem(index, in: list) else { return }

            layoutIfNeeded()
            _ = updateAccessibilityElements()
            let first = host.accessibilityItems().first {
                $0.listItem == AccessibilityListItem(list: list, index: index)
            }
            UIAccessibility.post(
                notification: .layoutChanged,
                argument: first.flatMap { accessibilityByNode[$0.node] }
            )
        }

        /// What VoiceOver says after a three-finger swipe turned a scroll's page. English by
        /// default; an app sets its own words.
        ///
        /// Ownership: the view keeps the closure. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var accessibilityPageStatus: @MainActor (ScrollPage) -> String = { page in
            "Page \(page.number) of \(page.count)"
        }

        /// A three-finger swipe on `node`'s element: turns a page of the scroll around it and
        /// tells VoiceOver where it is.
        fileprivate func accessibilityScroll(
            _ direction: UIAccessibilityScrollDirection,
            from node: NodeID
        ) -> Bool {
            let axis: ScrollAxis?
            let forward: Bool
            switch direction {
            // Three fingers up bring the content up: the next page below.
            case .up: (axis, forward) = (.vertical, true)
            case .down: (axis, forward) = (.vertical, false)
            case .left: (axis, forward) = (.horizontal, true)
            case .right: (axis, forward) = (.horizontal, false)
            case .next: (axis, forward) = (nil, true)
            case .previous: (axis, forward) = (nil, false)
            @unknown default: return false
            }
            guard let page = host.scrollPage(around: node, axis: axis, forward: forward) else {
                return false
            }

            layoutIfNeeded()
            UIAccessibility.post(
                notification: .pageScrolled,
                argument: accessibilityPageStatus(page)
            )
            return true
        }

        /// VoiceOver moved to `node`'s element: the scrolls around it show it.
        fileprivate func accessibilityFocused(_ node: NodeID) {
            host.reveal(node)
            layoutIfNeeded()
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
        func zoomed(_ frame: LayoutRect) -> CGRect {
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

    /// Takes the display's frames for a node view without keeping it: a display link keeps
    /// its target until it is invalidated.
    @MainActor
    private final class FrameTarget: NSObject {
        private weak var view: NodeView?

        init(_ view: NodeView) {
            self.view = view
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }

            view.displayFrame(link)
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
        /// What the scroll view zooms, when the scroll zooms: an empty view the size of the
        /// content as laid out; the tree's layers draw the zoom.
        private let zoomTarget = UIView()
        /// The scroll view's own gestures before it zooms; the ones it adds when it does — its
        /// pinch, where there is one — go to the node view, as the pan does. Told apart by
        /// that rather than by type: a TV has no pinch type at all.
        private var ownGestures: [ObjectIdentifier] = []
        /// The zooming gestures taken to the node view.
        private(set) var zoomGestures: [UIGestureRecognizer] = []
        /// Set while the driver moves the scroll view itself, so it does not hear itself.
        private var isFollowing = false

        /// Runs `body` with the scroll view's callbacks taken as its answer to code. The flag
        /// goes back to what it was, not to off: a call inside another — `follow` inside
        /// `place` — leaves the outer one still covered.
        private func whileFollowing(_ body: () -> Void) {
            let wasFollowing = isFollowing
            isFollowing = true
            defer { isFollowing = wasFollowing }
            body()
        }

        private var factor = 1.0
        /// The scroll's offset when the scroll view and it last agreed.
        private var synced: LayoutPoint?

        var pan: UIPanGestureRecognizer { physics.panGestureRecognizer }

        /// How fast the glide after a finger slows down.
        var decelerationRate: UIScrollView.DecelerationRate { physics.decelerationRate }

        /// How far the physics lets the offset go before the content's origin.
        var contentInset: UIEdgeInsets { physics.contentInset }

        /// Where the physics has the content, and how far it goes.
        var physicsOffset: CGPoint { physics.contentOffset }
        var contentSize: CGSize { physics.contentSize }

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
            zoomTarget.isUserInteractionEnabled = false
            physics.addSubview(zoomTarget)
            ownGestures = (physics.gestureRecognizers ?? []).map(ObjectIdentifier.init)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scroll?.isZoomable == true ? zoomTarget : nil
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isFollowing, let scroll else { return }

            reportZoom(of: scroll)
        }

        /// Tells the scroll where the pinch has the content.
        private func reportZoom(of scroll: Scroll) {
            let offset = physics.contentOffset
            scroll.platformDidZoom(
                to: Double(physics.zoomScale),
                offset: LayoutPoint(x: Double(offset.x) / factor, y: Double(offset.y) / factor)
            )
            synced = scroll.shownOffset
        }

        /// The zoom range and the pinch that goes with it; the scale code set.
        private func applyZoom(of scroll: Scroll, in view: UIView?) {
            let range = scroll.zoomRange
            physics.minimumZoomScale = CGFloat(range.lowerBound)
            physics.maximumZoomScale = CGFloat(range.upperBound)
            if scroll.isZoomable, let view {
                for gesture in physics.gestureRecognizers ?? []
                where !ownGestures.contains(ObjectIdentifier(gesture)) {
                    view.addGestureRecognizer(gesture)
                    zoomGestures.append(gesture)
                }
            }
            if !physics.isZooming, !physics.isZoomBouncing,
                physics.zoomScale != CGFloat(scroll.zoomScale)
            {
                physics.zoomScale = CGFloat(scroll.zoomScale)
            }
        }

        /// Puts the scroll view over the scroll's frame, `frame` in the node view's points,
        /// with the content's extent, and at the scroll's offset unless a finger moves it.
        func place(_ frame: CGRect, factor: Double) {
            guard let scroll else { return }

            let wasFollowing = isFollowing
            isFollowing = true
            defer { isFollowing = wasFollowing }

            self.factor = factor
            physics.frame = frame
            // A pager comes to rest quickly, on the page the drag's end picks.
            physics.decelerationRate = scroll.isPaging ? .fast : .normal
            physics.keyboardDismissMode =
                switch scroll.keyboardDismissal {
                case .none: .none
                case .onDrag: .onDrag
                case .interactive: .interactive
                }
            if scroll.isZoomable {
                // The content as laid out; the scroll view scales it itself.
                // Its transform is the scroll view's: it reads the scale from it.
                let base = scroll.contentBounds
                let zoom = scroll.zoomScale
                let size = CGSize(
                    width: (base.origin.x + base.size.width) / zoom * factor,
                    height: (base.origin.y + base.size.height) / zoom * factor
                )
                if zoomTarget.bounds.size != size, !physics.isZooming {
                    zoomTarget.bounds = CGRect(origin: .zero, size: size)
                    zoomTarget.center = CGPoint(
                        x: size.width * physics.zoomScale / 2,
                        y: size.height * physics.zoomScale / 2
                    )
                }
                applyZoom(of: scroll, in: physics.panGestureRecognizer.view)
            }
            let content = scroll.contentBounds
            // The offset first: a refresh that ends takes its room away, and with the insets
            // gone first the scroll view would put its offset back itself before this moves
            // it by as much again.
            follow(factor: factor)
            applyInsets(of: scroll, factor: factor)
            physics.contentSize = CGSize(
                width: (content.origin.x + content.size.width) * factor,
                height: (content.origin.y + content.size.height) * factor
            )
        }

        /// The content may start before the scroll's origin (a row laid out from the right),
        /// and a refresh opens room over it: the insets let the offset go there.
        private func applyInsets(of scroll: Scroll, factor: Double) {
            let content = scroll.contentBounds
            let lowest = scroll.offsetRange.lowest
            physics.contentInset = UIEdgeInsets(
                top: CGFloat(-min(content.origin.y, lowest.y) * factor),
                left: CGFloat(-min(content.origin.x, lowest.x) * factor),
                bottom: 0,
                right: 0
            )
        }

        /// Moves the scroll view to the scroll's offset, when code moved the scroll rather
        /// than a finger. Under a finger, or gliding after one, the scroll view moves by as
        /// much as code moved the scroll since they last agreed — to keep what shows in place
        /// when content before it changed length — and the pan or the glide goes on from there.
        func follow(factor: Double) {
            guard let scroll else { return }

            let wasFollowing = isFollowing
            isFollowing = true
            defer { isFollowing = wasFollowing }

            let offset = scroll.shownOffset
            if physics.isTracking || physics.isDecelerating {
                catchUp(to: offset, factor: factor)
            } else if offset != synced {
                // Only where code moved the scroll: what the physics moved it to — a pull
                // past the end, a bounce back from it — is its own, and setting its offset
                // would stop the bounce.
                physics.contentOffset = CGPoint(x: offset.x * factor, y: offset.y * factor)
            }
            synced = offset
        }

        private func catchUp(to offset: LayoutPoint, factor: Double) {
            guard let synced, offset != synced else { return }

            physics.contentOffset.x += CGFloat((offset.x - synced.x) * factor)
            physics.contentOffset.y += CGFloat((offset.y - synced.y) * factor)
        }

        func owns(_ view: UIView) -> Bool {
            view === physics
        }

        func stop() {
            physics.setContentOffset(physics.contentOffset, animated: false)
        }

        func remove() {
            physics.panGestureRecognizer.view?.removeGestureRecognizer(physics.panGestureRecognizer)
            for gesture in zoomGestures {
                gesture.view?.removeGestureRecognizer(gesture)
            }
            physics.removeFromSuperview()
        }

        /// How much the scroll view zooms, for tests.
        var physicsZoomScale: CGFloat { physics.zoomScale }
        var physicsZoomRange: ClosedRange<CGFloat> {
            physics.minimumZoomScale...physics.maximumZoomScale
        }

        private var isPastTheEnds: Bool {
            scroll.map { $0.overscroll != .zero } ?? false
        }

        /// Where the drag started, for a pager to go a page on from.
        private var dragStart: LayoutPoint?

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragStart = scroll?.contentOffset
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard let scroll else { return }

            if scroll.platformDidRelease() {
                // Pulled far enough to refresh: the glide comes to rest with the room open.
                whileFollowing { applyInsets(of: scroll, factor: factor) }
                let offset = scroll.contentOffset
                targetContentOffset.pointee = CGPoint(x: offset.x * factor, y: offset.y * factor)
                return
            }
            guard scroll.isPaging else { return }

            // The velocity comes in points a millisecond.
            let target = scroll.pagingTarget(
                from: dragStart ?? scroll.contentOffset,
                at: scroll.shownOffset,
                velocity: LayoutPoint(
                    x: Double(velocity.x) * 1000 / factor,
                    y: Double(velocity.y) * 1000 / factor
                )
            )
            targetContentOffset.pointee = CGPoint(x: target.x * factor, y: target.y * factor)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isFollowing, let scroll else { return }

            // A move code made since the last drawing is not lost to the finger's.
            whileFollowing { catchUp(to: scroll.shownOffset, factor: factor) }
            if scroll.isZoomable, Double(physics.zoomScale) != scroll.zoomScale {
                reportZoom(of: scroll)
                return
            }
            let offset = scrollView.contentOffset
            scroll.platformDidScroll(
                to: LayoutPoint(x: Double(offset.x) / factor, y: Double(offset.y) / factor)
            )
            synced = scroll.shownOffset
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

    /// The way into a focus section inside a scroll, for the platform's focus system: an item
    /// over the whole section, in the scroll's content, that takes the focus when the remote
    /// moves toward any part of the section — its nodes need not lie in the direction pressed.
    /// The view passes the focus on at once to the node focused there last, else the first.
    /// It does not take the focus while the focus is inside the section.
    @MainActor
    final class SectionEntry: NSObject, UIFocusItem {
        let node: NodeID
        private(set) weak var view: NodeView?
        weak var parent: (any UIFocusEnvironment)?
        /// In the scroll's content.
        var frame: CGRect = .zero
        var items: [NodeID] = []
        var lastFocused: NodeID?
        var isEnabled = true

        init(view: NodeView, node: NodeID) {
            self.view = view
            self.node = node
        }

        /// Where the focus goes on to.
        var target: NodeID? {
            lastFocused.flatMap { items.contains($0) ? $0 : nil } ?? items.first
        }

        var canBecomeFocused: Bool { isEnabled && target != nil }
        /// While it does not take the focus it lies over the section's nodes, and it must not
        /// hide them from the focus system.
        var isTransparentFocusItem: Bool { !canBecomeFocused }
        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
        var parentFocusEnvironment: (any UIFocusEnvironment)? { parent ?? view }
        var focusItemContainer: (any UIFocusItemContainer)? { nil }

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
                view?.focusScrollMoved(self)
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

        /// A move of the focus away from the node by an arrow is first offered to the node:
        /// one that takes it keeps the focus.
        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            guard context.previouslyFocusedItem === self,
                let move = FocusMove(context.focusHeading),
                let view
            else { return true }

            return !view.takesMove(move)
        }

        func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {}
    }

    extension FocusMove {
        /// The arrow a focus heading is; `nil` for other headings.
        init?(_ heading: UIFocusHeading) {
            if heading.contains(.up) {
                self = .up
            } else if heading.contains(.down) {
                self = .down
            } else if heading.contains(.left) {
                self = .left
            } else if heading.contains(.right) {
                self = .right
            } else {
                return nil
            }
        }
    }

    /// The elements of a list laid out by where it shows, as VoiceOver goes through a list: one
    /// for each of all its items. The items laid out give their own elements; each of the
    /// others stands in with the frame it is expected to take, and VoiceOver moving to it lays
    /// the item out and moves on to its element — so VoiceOver reads the whole list.
    ///
    /// It is a data table rather than a plain list: that is how UIKit tells VoiceOver where an
    /// element is among all of them — its row and column, and how many there are. A plain
    /// list is one column, a grid has a column for each lane.
    @MainActor
    final class ListAccessibilityContainer: UIAccessibilityElement,
        UIAccessibilityContainerDataTable
    {
        let list: NodeID
        private weak var view: NodeView?
        private var count = 0
        private var laidOut: Range<Int> = 0..<0
        private var table: AccessibilityList?
        /// The elements of the items laid out, in order, with their items' indices.
        private var elements: [(item: Int, element: NodeAccessibilityElement)] = []
        private var standIns: [Int: ListItemStandIn] = [:]

        init(view: NodeView, list: NodeID) {
            self.view = view
            self.list = list
            super.init(accessibilityContainer: view)
            isAccessibilityElement = false
            accessibilityContainerType = .dataTable
        }

        func update(
            _ list: AccessibilityList,
            elements: [(item: Int, element: NodeAccessibilityElement)]
        ) {
            count = list.count
            laidOut = list.laidOut
            table = list
            self.elements = elements
            for (item, element) in elements {
                element.tablePosition = list.position(ofItem: item)
            }
            // Items laid out now have elements of their own.
            standIns = standIns.filter { !laidOut.contains($0.key) && $0.key < count }
            for standIn in standIns.values {
                standIn.accessibilityFrameInContainerSpace = frame(ofItem: standIn.item)
                standIn.tablePosition = list.position(ofItem: standIn.item)
            }
        }

        func accessibilityRowCount() -> Int {
            table?.rowCount ?? 0
        }

        func accessibilityColumnCount() -> Int {
            table?.columnCount ?? 0
        }

        /// The first element of the item at `row` and `column`, or its stand-in.
        func accessibilityDataTableCellElement(
            forRow row: Int,
            column: Int
        ) -> (any UIAccessibilityContainerDataTableCell)? {
            guard let item = table?.item(row: row, column: column) else { return nil }

            if laidOut.contains(item) {
                return elements.first { $0.item == item }?.element
            }
            return standIn(for: item)
        }

        /// Items before the ones laid out, the elements of those, and items after them.
        override func accessibilityElementCount() -> Int {
            laidOut.lowerBound + elements.count + max(0, count - laidOut.upperBound)
        }

        override func accessibilityElement(at index: Int) -> Any? {
            guard index >= 0, index < accessibilityElementCount() else { return nil }

            if index < laidOut.lowerBound {
                return standIn(for: index)
            }
            let inside = index - laidOut.lowerBound
            if inside < elements.count {
                return elements[inside].element
            }
            return standIn(for: laidOut.upperBound + inside - elements.count)
        }

        override func index(ofAccessibilityElement element: Any) -> Int {
            if let standIn = element as? ListItemStandIn, standIn.list === self {
                let item = standIn.item
                if item < laidOut.lowerBound { return item }
                if item >= laidOut.upperBound {
                    return item - laidOut.upperBound + laidOut.lowerBound + elements.count
                }
                return NSNotFound
            }
            guard let position = elements.firstIndex(where: { $0.element === element as AnyObject })
            else { return NSNotFound }

            return laidOut.lowerBound + position
        }

        private func standIn(for item: Int) -> ListItemStandIn {
            if let standIn = standIns[item] { return standIn }

            let standIn = ListItemStandIn(list: self, item: item)
            standIn.accessibilityFrameInContainerSpace = frame(ofItem: item)
            standIn.tablePosition = table?.position(ofItem: item)
            standIns[item] = standIn
            return standIn
        }

        /// The frame the item is expected to take, in the container's coordinates.
        private func frame(ofItem item: Int) -> CGRect {
            guard let frame = view?.accessibilityFrame(ofItem: item, in: list) else { return .zero }

            let origin = accessibilityFrameInContainerSpace.origin
            return frame.offsetBy(dx: -origin.x, dy: -origin.y)
        }

        fileprivate func focused(_ standIn: ListItemStandIn) {
            view?.accessibilityFocused(item: standIn.item, in: list)
        }
    }

    /// An item of a list not laid out, as VoiceOver meets it: VoiceOver moving to it lays the
    /// item out and moves on to its element.
    @MainActor
    final class ListItemStandIn: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
        fileprivate unowned let list: ListAccessibilityContainer
        let item: Int
        fileprivate(set) var tablePosition: (row: Int, column: Int)?

        init(list: ListAccessibilityContainer, item: Int) {
            self.list = list
            self.item = item
            super.init(accessibilityContainer: list)
            isAccessibilityElement = true
        }

        override func accessibilityElementDidBecomeFocused() {
            list.focused(self)
        }

        func accessibilityRowRange() -> NSRange {
            tableRange(tablePosition?.row)
        }

        func accessibilityColumnRange() -> NSRange {
            tableRange(tablePosition?.column)
        }
    }

    /// One accessibility element of a node tree. It keeps the node's identity and asks the
    /// host to act on it; it never holds the node itself.
    @MainActor
    final class NodeAccessibilityElement: UIAccessibilityElement,
        UIAccessibilityContainerDataTableCell
    {
        private var node: NodeID?
        private weak var view: NodeView?
        /// The row and column of the element's item when it belongs to a list's item.
        fileprivate(set) var tablePosition: (row: Int, column: Int)?

        init(container: NodeView) {
            view = container
            super.init(accessibilityContainer: container)
        }

        /// The names of the actions shown, so that they are made again only when they change.
        private var actionNames: [String] = []

        /// Shows what `item` says, at `frame` in the view's coordinates.
        func update(_ item: AccessibilityItem, frame: CGRect) {
            if item.actions != actionNames || item.node != node {
                actionNames = item.actions
                let id = item.node
                accessibilityCustomActions =
                    item.actions.isEmpty
                    ? nil
                    : item.actions.enumerated().map { index, name in
                        UIAccessibilityCustomAction(name: name) { [weak view] _ in
                            view?.host.performAccessibilityAction(index, of: id) ?? false
                        }
                    }
            }
            node = item.node
            accessibilityLabel = item.label
            accessibilityValue = item.value
            accessibilityHint = item.hint
            accessibilityTraits = NodeAccessibilityElement.traits(item.traits)
            accessibilityFrameInContainerSpace = frame
            // The list the element belongs to, if any, sets it again.
            tablePosition = nil
        }

        func accessibilityRowRange() -> NSRange {
            tableRange(tablePosition?.row)
        }

        func accessibilityColumnRange() -> NSRange {
            tableRange(tablePosition?.column)
        }

        override func accessibilityActivate() -> Bool {
            guard let node else { return false }

            return view?.host.activate(node) ?? false
        }

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            guard let node, let view else { return false }

            return view.accessibilityScroll(direction, from: node)
        }

        override func accessibilityElementDidBecomeFocused() {
            guard let node else { return }

            view?.accessibilityFocused(node)
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

    /// A data table cell's row or column as UIKit wants it: one wide, or `NSNotFound` when
    /// the element is not in a table.
    private func tableRange(_ index: Int?) -> NSRange {
        index.map { NSRange(location: $0, length: 1) } ?? NSRange(location: NSNotFound, length: 0)
    }
#endif
