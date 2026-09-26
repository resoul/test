// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
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
        /// The elements in reading order; `nil` after a drawing, until asked for.
        private var accessibilityOrder: [NodeAccessibilityElement]?
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

        /// The tree's accessibility elements (`NodeHost.accessibilityItems()`), brought up to
        /// date after every drawing; a node keeps its element.
        ///
        /// Ownership: the view keeps the elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public override func accessibilityChildren() -> [Any]? {
            accessibilityOrder ?? updateAccessibilityElements()
        }

        private func updateAccessibilityElements() -> [NodeAccessibilityElement] {
            var kept: [NodeID: NodeAccessibilityElement] = [:]
            let order = host.accessibilityItems().map { item in
                let element =
                    accessibilityByNode[item.node]
                    ?? NodeAccessibilityElement(parent: self, node: item.node)
                element.update(item, zoom: factor)
                kept[item.node] = element
                return element
            }
            accessibilityByNode = kept
            accessibilityOrder = order
            return order
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

        /// Presses on nodes with `onTap`; other clicks go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseDown(with event: NSEvent) {
            if !host.pointerDown(at: point(of: event)) {
                super.mouseDown(with: event)
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mouseUp(with event: NSEvent) {
            host.pointerUp(at: point(of: event))
            super.mouseUp(with: event)
        }

        /// A click on an inactive window also reaches the nodes.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        // MARK: - Keyboard focus

        /// The view takes the keyboard when the tree has nodes to focus. Tab reaches it when
        /// the system's keyboard navigation is on, as for any control.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var acceptsFirstResponder: Bool {
            !host.focusItems().isEmpty
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

        /// Tab and Shift-Tab go through the nodes and then on to the window's other views;
        /// the arrows go to the nearest node that way; Return and Space press the focused
        /// node. Other keys go on up the responder chain.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func keyDown(with event: NSEvent) {
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
                host.moveFocus(.up)
            case .downArrow?:
                host.moveFocus(.down)
            case .leftArrow?:
                host.moveFocus(.left)
            case .rightArrow?:
                host.moveFocus(.right)
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
            if !scroll(by: delta, at: point(of: event), phase: phase) {
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

        /// Moves the scrolls under `point` by `delta`, in the view's points, and returns
        /// whether it took the event.
        @discardableResult
        func scroll(by delta: LayoutPoint, at point: LayoutPoint, phase: WheelPhase = .wheel)
            -> Bool
        {
            switch phase {
            case .wheel, .began:
                latched = nil
                glideIsSpent = false
                springBack()
            case .released, .glideEnded:
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
            for scroll in scrolls where along(scroll.axis, left) != 0 {
                let before = scroll.contentOffset
                var offset = before
                switch scroll.axis {
                case .vertical: offset.y += left.y
                case .horizontal: offset.x += left.x
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

    /// One accessibility element of a node tree. It keeps the node's identity and asks the
    /// host to act on it; it never holds the node itself.
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

    @MainActor
    final class NodeAccessibilityElement: NSAccessibilityElement {
        /// Presses the node: it holds the node's identity and the host weakly. A `Sendable`
        /// constant, so the nonisolated press can read it without touching `self`'s state.
        private let press: @MainActor @Sendable () -> Bool

        init(parent: NodeNSView, node: NodeID) {
            press = { [weak host = parent.host] in
                host?.activate(node) ?? false
            }
            super.init()
            setAccessibilityParent(parent)
        }

        /// Shows what `item` says, at its frame zoomed by `zoom`.
        func update(_ item: AccessibilityItem, zoom: Double) {
            setAccessibilityLabel(item.label)
            setAccessibilityValue(item.value)
            setAccessibilityHelp(item.hint)
            setAccessibilityRole(NodeAccessibilityElement.role(item.traits))
            setAccessibilitySelected(item.traits.contains(.selected))
            setAccessibilityEnabled(!item.traits.contains(.notEnabled))
            setAccessibilityFrameInParentSpace(
                NSRect(
                    x: item.frame.origin.x * zoom,
                    y: item.frame.origin.y * zoom,
                    width: item.frame.size.width * zoom,
                    height: item.frame.size.height * zoom
                )
            )
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
#endif
