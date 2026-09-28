// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutAppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import ThemeCore
    import os

    /// Where the adapter writes layout reports.
    private let layoutLog = Logger(subsystem: "Nodes", category: "layout")

    /// A view that shows a tree of nodes: it lays the tree out in its bounds and draws it into
    /// a layer it hosts. Outside, it is an ordinary view — frames, Auto Layout (through
    /// `intrinsicContentSize`), or a place in another view's `layoutSpec()`.
    ///
    /// The view hosts its own layer, so AppKit leaves that layer's geometry alone; it is
    /// flipped to put the origin at the top left, where layout frames start.
    ///
    /// Ownership: the view owns the host and, through it, the tree. Isolation: MainActor.
    /// Errors: none. Cancellation: `host.detach()` ends the tree's updates.
    @MainActor
    public final class NodeNSView: NSView {
        /// Ownership: owned by the view. Isolation: MainActor. Errors: none. Cancellation:
        /// `detach()`.
        public let host: NodeHost

        private let renderer = LayerRenderer()
        private let hostedLayer = CALayer()
        /// Holds the tree's layers, scaled by `zoom` from its top left corner.
        private let contentLayer = CALayer()
        private var isLayingOut = false
        /// The accessibility element of each node, kept while the node is one: VoiceOver
        /// keeps its place by the element's identity, and a scroll redraws many times a
        /// second.
        private var accessibilityByNode: [NodeID: NodeAccessibilityElement] = [:]
        /// The element of each lazy list, kept while the list shows, for the same reason.
        private var accessibilityLists: [NodeID: ListAccessibilityElement] = [:]
        /// The elements of the items laid out in each list, by item.
        private var accessibilityListItems: [NodeID: [Int: [NodeAccessibilityElement]]] = [:]
        /// The elements in reading order; `nil` after a drawing, until asked for.
        private var accessibilityOrder: [NSAccessibilityElement]?
        private let focusRing = FocusRing()
        /// Return or Space went down on a focused node and has not come up yet.
        private var isSelecting = false
        /// The display's frames, while a scroll moves frame by frame.
        private var frameLink: CADisplayLink?

        /// A view showing `root`.
        ///
        /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(root: Node) {
            host = NodeHost(root: root, size: LayoutSize(width: 0, height: 0))
            super.init(frame: .zero)
            hostedLayer.isGeometryFlipped = true
            contentLayer.anchorPoint = .zero
            hostedLayer.addSublayer(contentLayer)
            layer = hostedLayer
            wantsLayer = true
            host.focusLook = .ring
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(systemSettingsChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil
            )
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
            host.onNeedsLayout = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.invalidateIntrinsicContentSize()
                self.needsLayout = true
            }
            host.onNeedsRender = { [weak self] in
                guard let self, !self.isLayingOut else { return }

                self.needsLayout = true
            }
            host.onFocusRequest = { [weak self] node in
                guard let self else { return }

                // The keyboard comes here first, so the focused node gets the keys.
                if self.window?.firstResponder !== self {
                    self.window?.makeFirstResponder(self)
                }
                self.host.focus(node)
            }
            host.onNeedsFrames = { [weak self] in
                self?.startFrames()
            }
        }

        private func startFrames() {
            guard frameLink == nil else { return }

            let link = displayLink(
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
        /// stays sharp; clicks and accessibility frames follow. `nil`, the default, is 1.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var zoom: Double? {
            didSet {
                guard zoom != oldValue else { return }

                invalidateIntrinsicContentSize()
                needsLayout = true
            }
        }

        /// `zoom`, kept positive.
        var factor: Double {
            let zoom = zoom ?? 1
            return zoom > 0 ? zoom : 1
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var isFlipped: Bool { true }

        /// A new size needs a new layout; AppKit asks for one by itself only for views laid
        /// out by constraints.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }

        /// Lays the tree out in the bounds and draws it.
        ///
        /// Ownership: updates the tree and the layers. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func layout() {
            super.layout()
            isLayingOut = true
            defer { isLayingOut = false }

            updateConditions()
            let content = LayoutSize(
                width: Double(bounds.width) / factor,
                height: Double(bounds.height) / factor
            )
            let widthChanged = host.size.width != content.width
            host.size = content
            // Frames snap to, and text is drawn for, the pixels of the zoomed size.
            host.scale = Double(window?.backingScaleFactor ?? 1) * factor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.bounds = CGRect(x: 0, y: 0, width: content.width, height: content.height)
            contentLayer.position = .zero
            contentLayer.transform = CATransform3DMakeScale(CGFloat(factor), CGFloat(factor), 1)
            CATransaction.commit()
            host.direction =
                userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            host.layoutIfNeeded()
            if host.needsRender {
                renderer.render(
                    host.root,
                    in: contentLayer,
                    scale: host.scale,
                    animation: host.renderAnimation
                )
                host.didRender()
                updateAfterMove()
                NSAccessibility.post(element: self, notification: .layoutChanged)
            } else if !host.scrolledSinceRender.isEmpty {
                // Only scrolls moved: their content moves, and the ring and accessibility
                // frames follow.
                renderer.renderScrolls(host.scrolledSinceRender)
                host.didRender()
                updateAfterMove()
            }
            if widthChanged {
                // The height the tree wants depends on the width it has.
                invalidateIntrinsicContentSize()
            }
        }

        /// Brings what depends on where the nodes show in line after a drawing.
        private func updateAfterMove() {
            accessibilityOrder = nil
            if NSWorkspace.shared.isVoiceOverEnabled {
                // VoiceOver reads the frame of the element it is on without asking the view
                // again: bring it up to date now.
                _ = updateAccessibilityElements()
            }
            focusRing.show(
                around: host.focusedItem,
                color: NSColor.keyboardFocusIndicatorColor.cgColor,
                in: contentLayer
            )
        }

        /// The view is a container: its elements are the tree's.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func isAccessibilityElement() -> Bool {
            false
        }

        /// The tree's accessibility elements (`NodeHost.accessibilityEntries()`), brought up to
        /// date after every drawing; a node keeps its element. A lazy list is one element, a
        /// list with a row for each of its items, whether laid out or not.
        ///
        /// Ownership: the view keeps the elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func accessibilityChildren() -> [Any]? {
            accessibilityOrder ?? updateAccessibilityElements()
        }

        @discardableResult
        private func updateAccessibilityElements() -> [NSAccessibilityElement] {
            var kept: [NodeID: NodeAccessibilityElement] = [:]
            var keptLists: [NodeID: ListAccessibilityElement] = [:]
            var listItems: [NodeID: [Int: [NodeAccessibilityElement]]] = [:]
            /// The element of `item` in `parent`, which takes `container` in the view.
            func element(
                _ item: AccessibilityItem,
                in parent: Any,
                container: CGRect
            ) -> NodeAccessibilityElement {
                let element =
                    accessibilityByNode[item.node]
                    ?? NodeAccessibilityElement(parent: self, node: item.node)
                element.setAccessibilityParent(parent)
                element.update(item, frame: parentSpace(zoomed(item.frame), in: container))
                kept[item.node] = element
                return element
            }
            var order: [NSAccessibilityElement] = []
            for entry in host.accessibilityEntries() {
                switch entry {
                case .element(let item):
                    order.append(element(item, in: self, container: bounds))
                case .list(let list, let items):
                    let group =
                        accessibilityLists[list.node]
                        ?? ListAccessibilityElement(view: self, list: list.node)
                    let frame = zoomed(list.frame)
                    var byItem: [Int: [NodeAccessibilityElement]] = [:]
                    for item in items {
                        guard let index = item.listItem?.index else { continue }

                        let row = group.row(index)
                        let container = accessibilityFrame(ofItem: index, in: list.node) ?? frame
                        byItem[index, default: []].append(
                            element(item, in: row, container: container)
                        )
                    }
                    group.update(list, frame: parentSpace(frame, in: bounds), elements: byItem)
                    listItems[list.node] = byItem
                    keptLists[list.node] = group
                    order.append(group)
                }
            }
            accessibilityByNode = kept
            accessibilityLists = keptLists
            accessibilityListItems = listItems
            accessibilityOrder = order
            return order
        }

        /// `rect`, in the tree's points, in the view's points.
        private func zoomed(_ rect: LayoutRect) -> CGRect {
            CGRect(
                x: rect.origin.x * factor,
                y: rect.origin.y * factor,
                width: rect.size.width * factor,
                height: rect.size.height * factor
            )
        }

        /// `rect`, in the view's points from its top left, as a frame in the space of a
        /// parent that takes `container` in the view. AppKit measures a frame in its parent's
        /// space from the parent's bottom left even when the parent is a flipped view.
        fileprivate func parentSpace(_ rect: CGRect, in container: CGRect) -> CGRect {
            CGRect(
                x: rect.minX - container.minX,
                y: container.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }

        /// Where the item at `index` of `list` is, or is expected, in the view's points.
        fileprivate func accessibilityFrame(ofItem index: Int, in list: NodeID) -> CGRect? {
            host.accessibilityFrame(ofItem: index, in: list).map(zoomed)
        }

        /// VoiceOver moved to an item of `list`: the list scrolls to it and lays it out, and
        /// VoiceOver is told of the item's elements.
        fileprivate func accessibilityReveal(item index: Int, in list: NodeID) -> Bool {
            guard host.revealItem(index, in: list) else { return false }

            layoutSubtreeIfNeeded()
            updateAccessibilityElements()
            let elements = accessibilityListItems[list]?[index] ?? []
            NSAccessibility.post(
                element: accessibilityLists[list] ?? self,
                notification: .layoutChanged,
                userInfo: [.uiElements: elements]
            )
            return true
        }

        /// VoiceOver moved to the element of `node`: the scrolls around it show it.
        fileprivate func accessibilityReveal(_ node: NodeID) -> Bool {
            host.reveal(node)
            layoutSubtreeIfNeeded()
            return true
        }

        /// No width of its own — the surroundings give it one (constraints, SwiftUI, a
        /// frame), as for a paragraph of text — and the height the tree takes at the current
        /// width. A tree's widest content is a poor width to ask for: one long line of text
        /// can make it wider than the window.
        public override var intrinsicContentSize: CGSize {
            let width =
                bounds.width > 0
                ? AvailableSpace.definite(Double(bounds.width) / factor) : .maxContent
            return CGSize(
                width: NSView.noIntrinsicMetric,
                height: host.fittingSize(width: width).height * factor
            )
        }

        /// Follows the window's appearance, light or dark.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateConditions()
        }

        /// Takes the system's settings into the host's conditions: light or dark, Increase
        /// Contrast, Reduce Motion. They apply at once, without an animation of the tree's
        /// own.
        private func updateConditions() {
            let conditions = DisplayConditions(effectiveAppearance)
            guard conditions != host.conditions else { return }

            withAnimation(nil) {
                host.conditions = conditions
            }
        }

        @objc private func systemSettingsChanged() {
            updateConditions()
        }

        /// Presses on nodes with `onTap`; other clicks go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseDown(with event: NSEvent) {
            if !mouseDown(at: point(of: event), time: event.timestamp) {
                super.mouseDown(with: event)
            }
        }

        /// Drags the node under the click along the way the mouse first goes, if it is
        /// dragged that way.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseDragged(with event: NSEvent) {
            if !mouseDragged(to: point(of: event), time: event.timestamp) {
                super.mouseDragged(with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseUp(with event: NSEvent) {
            mouseUp(at: point(of: event))
            super.mouseUp(with: event)
        }

        /// A press of the mouse under way: where it began, and — once it moved far enough to
        /// be a drag of a node — how fast it moves.
        private struct MousePress {
            let start: LayoutPoint
            var isDrag = false
            var last: (point: LayoutPoint, time: Double)
            var speed = LayoutPoint.zero
        }

        private var mousePress: MousePress?

        /// Points the mouse moves before a press is a drag.
        private static let dragDistance = 4.0

        /// The mouse went down at `point`; returns whether a node takes the press.
        @discardableResult
        func mouseDown(at point: LayoutPoint, time: Double) -> Bool {
            mousePress = MousePress(start: point, last: (point, time))
            return host.pointerDown(at: point)
        }

        /// The mouse moved to `point` while down; returns whether a node's drag took it.
        @discardableResult
        func mouseDragged(to point: LayoutPoint, time: Double) -> Bool {
            guard var press = mousePress else { return false }

            let moved = LayoutPoint(x: point.x - press.start.x, y: point.y - press.start.y)
            if !press.isDrag {
                guard hypot(moved.x, moved.y) >= NodeNSView.dragDistance else { return false }

                let axis: ScrollAxis = abs(moved.x) > abs(moved.y) ? .horizontal : .vertical
                guard host.dragBegan(at: press.start, along: axis) else {
                    mousePress = nil
                    return false
                }

                press.isDrag = true
            }
            if time > press.last.time {
                let elapsed = time - press.last.time
                press.speed = LayoutPoint(
                    x: (point.x - press.last.point.x) / elapsed,
                    y: (point.y - press.last.point.y) / elapsed
                )
            }
            press.last = (point, time)
            mousePress = press
            host.dragMoved(by: moved)
            return true
        }

        /// The mouse went up at `point`: ends the drag of a node, or the press.
        func mouseUp(at point: LayoutPoint) {
            let press = mousePress
            mousePress = nil
            guard let press, press.isDrag else {
                host.pointerUp(at: point)
                return
            }

            host.dragEnded(
                by: LayoutPoint(x: point.x - press.start.x, y: point.y - press.start.y),
                velocity: press.speed
            )
        }

        /// A click on an inactive window also reaches the nodes.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        // MARK: - Keyboard focus

        /// The view takes the keyboard when the tree has nodes to focus, or nodes carrying out
        /// commands — menus and shortcuts reach them through it. Tab reaches it when the
        /// system's keyboard navigation is on, as for any control, and a click makes it the
        /// first responder.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var acceptsFirstResponder: Bool {
            !host.focusItems().isEmpty || host.handlesCommands
        }

        /// Reached by Tab or Shift-Tab, focuses the first or the last node. A click takes the
        /// keyboard without showing a focus, as on any Mac control.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }

            if window?.currentEvent?.type == .keyDown {
                let backward = window?.keyViewSelectionDirection == .selectingPrevious
                host.moveFocus(backward ? .previous : .next)
            }
            return true
        }

        /// Leaving the keyboard, the tree loses the focus.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }

            if isSelecting {
                isSelecting = false
                host.pointerCancelled()
            }
            host.focus(nil)
            return true
        }

        /// A command's shortcut (`Node.handle`) comes first, and then: Tab and Shift-Tab go
        /// through the nodes and then on to the window's other views; an arrow goes to the
        /// focused node (`onMoveCommand`), else to the nearest node that way; Return and Space
        /// press the focused node. Other keys go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func keyDown(with event: NSEvent) {
            if let shortcut = Shortcut(event), host.perform(shortcut) { return }

            let backward = event.modifierFlags.contains(.shift)
            switch event.specialKey {
            case .tab? where !backward:
                if !host.moveFocus(.next) {
                    window?.selectNextKeyView(self)
                }
            case .tab?, .backTab?:
                if !host.moveFocus(.previous) {
                    window?.selectPreviousKeyView(self)
                }
            case .upArrow?:
                arrow(.up)
            case .downArrow?:
                arrow(.down)
            case .leftArrow?:
                arrow(.left)
            case .rightArrow?:
                arrow(.right)
            default:
                if NodeNSView.selects(event) {
                    if !event.isARepeat, host.selectBegan() {
                        isSelecting = true
                    }
                } else {
                    super.keyDown(with: event)
                }
            }
        }

        /// An arrow goes to the focused node first; the focus moves when the node does not
        /// take it.
        private func arrow(_ move: FocusMove) {
            if !host.moveCommand(move) {
                host.moveFocus(move)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func keyUp(with event: NSEvent) {
            if isSelecting, NodeNSView.selects(event) {
                isSelecting = false
                host.selectEnded()
            } else {
                super.keyUp(with: event)
            }
        }

        /// Return, Enter or Space.
        private static func selects(_ event: NSEvent) -> Bool {
            event.specialKey == .carriageReturn || event.specialKey == .enter
                || event.charactersIgnoringModifiers == " "
        }

        // MARK: - Scrolling

        /// The scroll wheel and the trackpad move the tree's scrolls: the innermost one under
        /// the pointer that can still go that way, then the ones around it. A trackpad
        /// gesture, with its glide, stays with the scrolls it started in, as in any Mac scroll
        /// view, and pulls the content past its end with growing resistance; let go, it
        /// springs back. What no scroll takes goes on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func scrollWheel(with event: NSEvent) {
            let phase: WheelPhase
            if event.phase == [] && event.momentumPhase == [] {
                phase = .wheel
            } else if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                phase = .glideEnded
            } else if event.momentumPhase != [] {
                phase = .gliding
            } else if event.phase == .ended || event.phase == .cancelled {
                phase = .released
            } else {
                phase = event.phase == .began ? .began : .touching
            }
            var delta = LayoutPoint(
                x: -Double(event.scrollingDeltaX),
                y: -Double(event.scrollingDeltaY)
            )
            if !event.hasPreciseScrollingDeltas {
                // A mouse wheel counts lines.
                delta = LayoutPoint(x: delta.x * NodeNSView.line, y: delta.y * NodeNSView.line)
            }
            if !scroll(by: delta, at: point(of: event), phase: phase, time: event.timestamp) {
                super.scrollWheel(with: event)
            }
        }

        /// Where a scroll event is in its gesture.
        enum WheelPhase {
            /// A mouse wheel: no gesture, no pulling past the ends.
            case wheel
            /// Fingers down on the trackpad.
            case began
            case touching
            /// Fingers up.
            case released
            /// The glide after the fingers.
            case gliding
            case glideEnded
        }

        /// Points one line of a mouse wheel scrolls.
        private static let line = 10.0

        /// The scrolls the current trackpad gesture moves.
        private var latched: [Scroll]?
        /// The scroll pulled past its end, and how far the gesture pulled it — more than it
        /// shows, which the resistance makes less.
        private var pulled: (scroll: Scroll, by: Double)?
        /// The glide reached an end and bounced: the rest of it is spent.
        private var glideIsSpent = false
        /// Where the paging scrolls of the gesture were when it began.
        private var pageStarts: [(scroll: Scroll, offset: LayoutPoint)] = []
        /// How fast the fingers moved the content, in points a second, and when last.
        private var fingerSpeed = LayoutPoint.zero
        private var lastTouch: Double?
        /// When a mouse wheel last turned a page: the wheel keeps turning for a while, and
        /// one turn is one page.
        private var lastWheelPage: Double?
        /// Where the gesture began, until its first move tells whether it drags a node.
        private var dragAt: LayoutPoint?
        /// How far the fingers moved a node's drag under way.
        private var dragTranslation: LayoutPoint?

        /// Moves the scrolls under `point` by `delta`, in the view's points, and returns
        /// whether it took the event.
        @discardableResult
        func scroll(
            by delta: LayoutPoint,
            at point: LayoutPoint,
            phase: WheelPhase = .wheel,
            time: Double = 0
        ) -> Bool {
            switch phase {
            case .wheel, .began:
                latched = nil
                glideIsSpent = false
                springBack()
            case .released:
                if let moved = dragTranslation {
                    // The fingers move the other way from the content.
                    host.dragEnded(
                        by: moved,
                        velocity: LayoutPoint(x: -fingerSpeed.x, y: -fingerSpeed.y)
                    )
                    dragTranslation = nil
                    glideIsSpent = true
                    pageStarts = []
                    return true
                }
                if let pull = pulled, pull.scroll.platformDidRelease() {
                    // Pulled far enough to refresh: it opens the room rather than springing
                    // back.
                    pulled = nil
                }
                springBack()
                turnPages()
                return latched.map { !$0.isEmpty } ?? false
            case .glideEnded:
                springBack()
                return latched.map { !$0.isEmpty } ?? false
            case .gliding where glideIsSpent:
                return true
            case .touching, .gliding:
                break
            }
            let scrolls = latched ?? host.scrolls(at: point)
            latched = scrolls
            var left = LayoutPoint(x: delta.x / factor, y: delta.y / factor)
            if phase == .began {
                dragAt = point
                dragTranslation = nil
                pageStarts = scrolls.filter(\.isPaging).map { ($0, $0.contentOffset) }
                fingerSpeed = .zero
                lastTouch = time
            } else if phase == .touching, let last = lastTouch, time > last {
                // The speed of the last moves, the older ones counting less.
                let speed = LayoutPoint(x: left.x / (time - last), y: left.y / (time - last))
                fingerSpeed = LayoutPoint(
                    x: fingerSpeed.x * 0.4 + speed.x * 0.6,
                    y: fingerSpeed.y * 0.4 + speed.y * 0.6
                )
                lastTouch = time
            }
            if phase == .touching, let at = dragAt, left != .zero {
                // The first move tells the way: a node dragged along it takes the gesture.
                dragAt = nil
                let axis: ScrollAxis = abs(left.x) > abs(left.y) ? .horizontal : .vertical
                if host.dragBegan(at: at, along: axis) {
                    dragTranslation = .zero
                }
            }
            if phase == .touching, let moved = dragTranslation {
                let now = LayoutPoint(x: moved.x - left.x, y: moved.y - left.y)
                dragTranslation = now
                host.dragMoved(by: now)
                return true
            }
            if phase == .wheel,
                let pager = scrolls.first(where: { $0.isPaging && along($0.axis, left) != 0 })
            {
                // A mouse wheel turns a pager a page at a time.
                if lastWheelPage.map({ time - $0 > NodeNSView.wheelPageInterval }) ?? true {
                    lastWheelPage = time
                    withAnimation(NodeNSView.pageTurn) {
                        pager.scroll(toPage: pager.page + (along(pager.axis, left) > 0 ? 1 : -1))
                    }
                }
                return true
            }
            var moved = false
            // Moving back, a scroll pulled past its end first takes the pull back.
            if let pull = pulled {
                let back = along(pull.scroll.axis, left)
                if back * pull.by < 0 {
                    let now = abs(back) >= abs(pull.by) ? 0 : pull.by + back
                    left = setting(pull.scroll.axis, of: left, to: back + (pull.by - now))
                    stretch(pull.scroll, to: now)
                    moved = true
                }
            }
            for scroll in scrolls where moves(scroll, left) {
                if phase == .gliding && scroll.isPaging {
                    // The pager came to rest on its page when the fingers left: it takes the
                    // glide along its axis without moving.
                    left = setting(scroll.axis, of: left, to: 0)
                    continue
                }
                let before = scroll.contentOffset
                var offset = before
                if scroll.isZoomable {
                    // Zoomable content moves both ways.
                    offset.x += left.x
                    offset.y += left.y
                } else {
                    switch scroll.axis {
                    case .vertical: offset.y += left.y
                    case .horizontal: offset.x += left.x
                    }
                }
                scroll.contentOffset = offset
                let now = scroll.contentOffset
                left.x -= now.x - before.x
                left.y -= now.y - before.y
                moved = moved || now != before
            }
            // What no scroll took pulls the innermost one of its axis past its end.
            if phase != .wheel,
                let scroll = scrolls.first(where: { along($0.axis, left) != 0 })
            {
                let already = pulled?.scroll === scroll ? pulled!.by : 0
                stretch(scroll, to: already + along(scroll.axis, left))
                moved = true
                if phase == .gliding {
                    // A glide that hits the end bounces off it at once.
                    glideIsSpent = true
                    springBack()
                }
            }
            return moved
        }

        /// Whether `delta` goes the way `scroll` moves.
        private func moves(_ scroll: Scroll, _ delta: LayoutPoint) -> Bool {
            scroll.isZoomable ? delta != .zero : along(scroll.axis, delta) != 0
        }

        /// A trackpad pinch zooms the innermost zoomable scroll under the pointer, about the
        /// pointer.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func magnify(with event: NSEvent) {
            if !pinch(by: Double(event.magnification), at: point(of: event)) {
                super.magnify(with: event)
            }
        }

        /// A double tap with two fingers zooms the scroll under the pointer in to twice its
        /// smallest size, or back out to it.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func smartMagnify(with event: NSEvent) {
            if !smartZoom(at: point(of: event)) {
                super.smartMagnify(with: event)
            }
        }

        /// Zooms the scroll under `point` by `magnification` — 0.1 a tenth bigger — about the
        /// point; returns whether there was one.
        @discardableResult
        func pinch(by magnification: Double, at point: LayoutPoint) -> Bool {
            guard let (scroll, at) = zoomableScroll(at: point) else { return false }

            scroll.zoom(to: scroll.zoomScale * (1 + magnification), around: at)
            return true
        }

        /// Zooms the scroll under `point` in or back out, as a double tap does; returns
        /// whether there was one.
        @discardableResult
        func smartZoom(at point: LayoutPoint) -> Bool {
            guard let (scroll, at) = zoomableScroll(at: point) else { return false }

            let smallest = scroll.zoomRange.lowerBound
            withAnimation(NodeNSView.pageTurn) {
                scroll.zoom(to: scroll.zoomScale > smallest ? smallest : smallest * 2, around: at)
            }
            return true
        }

        /// The innermost scroll under `point` that zooms, and the point in its box.
        func zoomableScroll(at point: LayoutPoint) -> (Scroll, LayoutPoint)? {
            host.scrollItems().last { item in
                let frame = item.frame
                return item.scroll.isZoomable && point.x >= frame.origin.x
                    && point.y >= frame.origin.y
                    && point.x < frame.origin.x + frame.size.width
                    && point.y < frame.origin.y + frame.size.height
            }
            .map { item in
                (
                    item.scroll,
                    LayoutPoint(x: point.x - item.frame.origin.x, y: point.y - item.frame.origin.y)
                )
            }
        }

        /// How long a mouse wheel's turn goes on turning one page, in seconds.
        private static let wheelPageInterval = 0.35
        /// How a pager comes to rest on its page.
        private static let pageTurn = Animation.spring(response: 0.35, dampingRatio: 1)

        /// Fingers left a gesture that moved pagers: each comes to rest on the page the
        /// gesture's end picks.
        private func turnPages() {
            let starts = pageStarts
            pageStarts = []
            lastTouch = nil
            for (scroll, start) in starts {
                let target = scroll.pagingTarget(
                    from: start,
                    at: scroll.contentOffset,
                    velocity: fingerSpeed
                )
                withAnimation(NodeNSView.pageTurn) {
                    scroll.contentOffset = target
                }
            }
        }

        /// Shows `scroll` pulled `amount` points past its end, with resistance: the further
        /// the pull, the less it gives, never beyond its window's length.
        private func stretch(_ scroll: Scroll, to amount: Double) {
            let window =
                scroll.axis == .vertical ? scroll.frame.size.height : scroll.frame.size.width
            let length = max(window, 1)
            let shown = (1 - 1 / (abs(amount) * 0.55 / length + 1)) * length
            let past = amount < 0 ? -shown : shown
            pulled = amount == 0 ? nil : (scroll, amount)
            let offset = scroll.contentOffset
            scroll.platformDidScroll(
                to: scroll.axis == .vertical
                    ? LayoutPoint(x: offset.x, y: offset.y + past)
                    : LayoutPoint(x: offset.x + past, y: offset.y)
            )
        }

        /// Lets a pulled scroll spring back to its end.
        private func springBack() {
            guard let pull = pulled else { return }

            pulled = nil
            withAnimation(.spring(response: 0.3, dampingRatio: 1)) {
                pull.scroll.platformDidScroll(to: pull.scroll.contentOffset)
            }
        }

        private func along(_ axis: ScrollAxis, _ point: LayoutPoint) -> Double {
            axis == .vertical ? point.y : point.x
        }

        private func setting(_ axis: ScrollAxis, of point: LayoutPoint, to value: Double)
            -> LayoutPoint
        {
            axis == .vertical
                ? LayoutPoint(x: point.x, y: value) : LayoutPoint(x: value, y: point.y)
        }

        private func point(of event: NSEvent) -> LayoutPoint {
            // The view is flipped, so the point is measured from the top left.
            let location = convert(event.locationInWindow, from: nil)
            return LayoutPoint(x: Double(location.x) / factor, y: Double(location.y) / factor)
        }

        /// The layer drawing `node`, for tests and debugging.
        ///
        /// Ownership: returns a layer the view's renderer owns. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public func renderedLayer(for node: Node) -> CALayer? {
            renderer.layer(for: node)
        }
    }

    extension NSView {
        /// Shows `node` in a new `NodeNSView` added as a subview, and returns it for sizing
        /// and positioning.
        ///
        /// Ownership: the view keeps the new subview, which keeps the node. Isolation:
        /// MainActor. Errors: none. Cancellation: remove the subview and call
        /// `host.detach()`.
        @discardableResult
        public func addSubnode(_ node: Node) -> NodeNSView {
            let view = NodeNSView(root: node)
            addSubview(view)
            return view
        }
    }

    /// Takes the display's frames for a node view without keeping it: a display link keeps
    /// its target until it is invalidated.
    @MainActor
    private final class FrameTarget: NSObject {
        private weak var view: NodeNSView?

        init(_ view: NodeNSView) {
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

    /// The action VoiceOver sends an element it moves to, so that it shows. AppKit names it
    /// `NSAccessibilityScrollToVisibleAction` from macOS 26; the name is older.
    private let scrollToVisible = NSAccessibility.Action(rawValue: "AXScrollToVisible")

    /// An accessibility element that VoiceOver can ask to show: moving to an element, it sends
    /// the element the scroll-to-visible action, and the element's scrolls bring it into view.
    ///
    /// AppKit has no method of the NSAccessibility protocol for that action, as it has
    /// `accessibilityPerformPress` for a press: the element takes it through the action
    /// methods AppKit marks deprecated, the only ones it still calls with it.
    class ShowableAccessibilityElement: NSAccessibilityElement {
        /// Shows the element; `Sendable`, so the action method can run it on the main actor.
        private let show: @MainActor @Sendable () -> Bool
        /// Whether the element takes a press as well.
        private let pressable: Bool

        init(pressable: Bool, show: @escaping @MainActor @Sendable () -> Bool) {
            self.pressable = pressable
            self.show = show
            super.init()
        }

        override func accessibilityActionNames() -> [NSAccessibility.Action] {
            pressable ? [.press, scrollToVisible] : [scrollToVisible]
        }

        // AppKit declares the action methods without actor isolation but calls them on the
        // main thread; `assumeIsolated` checks that at run time.
        override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
            if action == scrollToVisible {
                let show = show
                MainActor.assumeIsolated { _ = show() }
            } else if action == .press, pressable {
                _ = accessibilityPerformPress()
            }
        }
    }

    /// One accessibility element of a node tree. It keeps the node's identity and asks the
    /// host to act on it; it never holds the node itself.
    @MainActor
    final class NodeAccessibilityElement: ShowableAccessibilityElement {
        /// Presses the node: it holds the node's identity and the host weakly. A `Sendable`
        /// constant, so the nonisolated press can read it without touching `self`'s state.
        private let press: @MainActor @Sendable () -> Bool

        private weak var host: NodeHost?

        init(parent: NodeNSView, node: NodeID) {
            host = parent.host
            press = { [weak host = parent.host] in
                host?.activate(node) ?? false
            }
            super.init(pressable: true) { [weak parent] in
                parent?.accessibilityReveal(node) ?? false
            }
            setAccessibilityParent(parent)
        }

        /// The names of the actions shown, so that they are made again only when they change.
        private var actionNames: [String] = []

        /// Shows what `item` says, at `frame` in its parent's space.
        func update(_ item: AccessibilityItem, frame: CGRect) {
            if item.actions != actionNames {
                actionNames = item.actions
                let id = item.node
                let host = host
                setAccessibilityCustomActions(
                    item.actions.enumerated().map { index, name in
                        NSAccessibilityCustomAction(name: name) { [weak host] in
                            // AppKit calls it on the main thread; `assumeIsolated` checks.
                            MainActor.assumeIsolated {
                                host?.performAccessibilityAction(index, of: id) ?? false
                            }
                        }
                    }
                )
            }
            setAccessibilityLabel(item.label)
            setAccessibilityValue(item.value)
            setAccessibilityHelp(item.hint)
            setAccessibilityRole(NodeAccessibilityElement.role(item.traits))
            setAccessibilitySelected(item.traits.contains(.selected))
            setAccessibilityEnabled(!item.traits.contains(.notEnabled))
            setAccessibilityFrameInParentSpace(frame)
        }

        // AppKit declares this without actor isolation but calls it on the main thread;
        // `assumeIsolated` checks that at run time.
        override nonisolated func accessibilityPerformPress() -> Bool {
            let press = press
            return MainActor.assumeIsolated { press() }
        }

        private static func role(_ traits: AccessibilityTraits) -> NSAccessibility.Role {
            if traits.contains(.button) { return .button }
            if traits.contains(.image) { return .image }
            if traits.contains(.staticText) || traits.contains(.header) { return .staticText }
            return .group
        }
    }

    /// A lazy list as VoiceOver goes through it: a row for each of all its items. The rows of
    /// items laid out hold their elements; the others are empty, at the frame the item is
    /// expected to take, and VoiceOver moving to one lays the item out. Rows are made as
    /// they are asked for: a list may have far more items than anyone reads.
    ///
    /// Not bound to the main actor, as AppKit asks for rows from outside any: the view hands
    /// it what it needs, and it goes to the view on the main actor only for values.
    final class ListAccessibilityElement: NSAccessibilityElement {
        let list: NodeID
        private weak var view: NodeNSView?
        private var count = 0
        private var laidOut: Range<Int> = 0..<0
        private var rows: [Int: ListRowAccessibilityElement] = [:]

        init(view: NodeNSView, list: NodeID) {
            self.view = view
            self.list = list
            super.init()
            setAccessibilityParent(view)
            setAccessibilityRole(.list)
        }

        /// Takes what `list` says, `frame` in the view's space, and the elements of the items
        /// laid out, by item.
        func update(
            _ list: AccessibilityList,
            frame: CGRect,
            elements: [Int: [NodeAccessibilityElement]]
        ) {
            for index in laidOut where elements[index] == nil {
                rows[index]?.elements = []
            }
            count = list.count
            laidOut = list.laidOut
            rows = rows.filter { $0.key < count }
            for (index, elements) in elements {
                row(index).elements = elements
            }
            setAccessibilityFrameInParentSpace(frame)
        }

        /// The row of the item at `index`.
        func row(_ index: Int) -> ListRowAccessibilityElement {
            if let row = rows[index] { return row }

            let row = ListRowAccessibilityElement(list: self, item: index, view: view)
            rows[index] = row
            return row
        }

        /// The rows of the items in `range`, clamped to the items there are.
        private func rows(_ range: Range<Int>) -> [ListRowAccessibilityElement] {
            range.clamped(to: 0..<count).map { row($0) }
        }

        override func accessibilityRows() -> [Any]? {
            rows(0..<count)
        }

        override func accessibilityChildren() -> [Any]? {
            rows(0..<count)
        }

        override func accessibilityVisibleRows() -> [Any]? {
            rows(laidOut)
        }

        override func accessibilityRowCount() -> Int {
            count
        }

        // Clients that read a few rows at a time ask for them by index; answering without
        // the whole array makes a row only for each of those.
        override func accessibilityArrayAttributeCount(
            _ attribute: NSAccessibility.Attribute
        ) -> Int {
            guard attribute == .children || attribute == .rows else {
                return super.accessibilityArrayAttributeCount(attribute)
            }

            return count
        }

        override func accessibilityArrayAttributeValues(
            _ attribute: NSAccessibility.Attribute,
            index: Int,
            maxCount: Int
        ) -> [Any] {
            guard attribute == .children || attribute == .rows else {
                return super.accessibilityArrayAttributeValues(
                    attribute,
                    index: index,
                    maxCount: maxCount
                )
            }

            let start = max(0, index)
            return rows(start..<start + max(0, maxCount))
        }

        override func accessibilityIndex(ofChild child: Any) -> Int {
            guard let row = child as? ListRowAccessibilityElement else {
                return super.accessibilityIndex(ofChild: child)
            }

            return row.list === self && row.item < count ? row.item : NSNotFound
        }

        /// The frame of the item at `index` in this element's space.
        fileprivate func frame(ofItem index: Int) -> CGRect {
            let shown = accessibilityFrameInParentSpace()
            let view = view
            let list = list
            // AppKit asks on the main thread; `assumeIsolated` checks that at run time.
            return MainActor.assumeIsolated {
                guard let view, let item = view.accessibilityFrame(ofItem: index, in: list)
                else { return .zero }

                // The list's frame back in the view's points from the top left.
                let container = CGRect(
                    x: shown.minX,
                    y: view.bounds.height - shown.maxY,
                    width: shown.width,
                    height: shown.height
                )
                return view.parentSpace(item, in: container)
            }
        }
    }

    /// The row of one item of a lazy list: where the item is, or is expected to be, and its
    /// elements when it is laid out. It asks the list for its frame each time: the list
    /// scrolls, and a row may be one of thousands never read. VoiceOver moving to it lays the
    /// item out.
    final class ListRowAccessibilityElement: ShowableAccessibilityElement {
        fileprivate unowned let list: ListAccessibilityElement
        let item: Int
        /// The elements of the item, while it is laid out.
        fileprivate(set) var elements: [NodeAccessibilityElement] = []

        init(list: ListAccessibilityElement, item: Int, view: NodeNSView?) {
            self.list = list
            self.item = item
            let id = list.list
            super.init(pressable: false) { [weak view] in
                view?.accessibilityReveal(item: item, in: id) ?? false
            }
            setAccessibilityParent(list)
            setAccessibilityRole(.row)
        }

        override func accessibilityIndex() -> Int {
            item
        }

        override func accessibilityFrameInParentSpace() -> NSRect {
            list.frame(ofItem: item)
        }

        override func accessibilityChildren() -> [Any]? {
            elements
        }
    }
#endif
