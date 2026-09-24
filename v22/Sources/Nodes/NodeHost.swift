import Foundation
import LayoutCore
import StateCore

/// Lays out a tree of nodes in a given size. A platform adapter owns one per root: it sets
/// `size`, `scale` and `direction`, is told through `onNeedsLayout` when the tree must be laid
/// out again, and calls `layoutIfNeeded()` before it draws.
///
/// A layout pass first runs pending state updates (`update()` of nodes whose state changed),
/// then lays out the whole tree in one engine pass — nested nodes' layouts are part of it —
/// and finally mounts the nodes the layouts mention and unmounts those they no longer do.
///
/// Ownership: the host keeps the root, which keeps its mounted subnodes. Isolation:
/// MainActor; the pass runs synchronously. Errors: none. Cancellation: `detach()`.
@MainActor
public final class NodeHost {
    /// Ownership: owned by the host. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let root: Node

    /// The size the root is laid out in.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var size: LayoutSize {
        didSet { if size != oldValue { setNeedsLayout() } }
    }

    /// Pixels per point, for snapping frames to the pixel grid.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var scale: Double = 1 {
        didSet { if scale != oldValue { setNeedsLayout() } }
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var direction: LayoutDirection = .leftToRight {
        didSet { if direction != oldValue { setNeedsLayout() } }
    }

    /// The points of spacing steps (`.s1` … `.s9`) in the tree's layouts.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var spacing: SpacingScale = .standard {
        didSet { setNeedsLayout() }
    }

    /// Called once when the tree goes from laid out to needing a layout — the adapter
    /// schedules `layoutIfNeeded()` from it (`setNeedsLayout` of its view).
    ///
    /// Ownership: the host keeps the closure; it must not keep the host. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onNeedsLayout: (@MainActor () -> Void)?

    /// Called once when something visible changed without needing a layout (an
    /// `appearance`) — the adapter redraws from it.
    ///
    /// Ownership: the host keeps the closure; it must not keep the host. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onNeedsRender: (@MainActor () -> Void)?

    /// Whether the tree changed since the adapter last drew it: set by every layout and by
    /// `setNeedsRender()`, cleared by `didRender()`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var needsRender = true

    /// The animation the next drawing moves with: set when a layout or a redraw is asked for
    /// inside `withAnimation`, and by the layout pass that asking led to; cleared by
    /// `didRender()`. `nil` draws the changes at once.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var renderAnimation: Animation?

    /// Whether the next `layoutIfNeeded()` lays the tree out.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var needsLayout = true

    /// Solve layouts after the first one on a background thread. The main thread still asks
    /// the nodes for their layouts and content (`layoutSpec()`, `update()`), and applies the
    /// frames; only the engine's work moves. The tree keeps its old frames until the new ones
    /// arrive, and a solve that a newer layout overtakes is cancelled and its result dropped.
    /// A layout whose content only measures on the main thread (views inside it) is solved
    /// there anyway.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var solvesInBackground = false

    /// The focused node, or `nil`. The platform's focus system decides where focus goes; the
    /// adapter reports it with `focus(_:)`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var focusedNode: NodeID?

    /// The animation of the nodes' `focusChanged`. `nil` shows focus at once.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var focusAnimation: Animation? = .easeOut(duration: 0.15)

    /// How focused nodes show the focus; the adapter sets it for its platform. A change
    /// reaches nodes at their next `focusChanged`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var focusLook: FocusLook = .lift

    /// Layout passes run so far — for tests and diagnostics.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var passes = 0

    private var mounted: [NodeID: Node] = [:]
    private var pressed: Node?
    private var generation: UInt64 = 0
    private var solving: Task<Void, Never>?
    private var solverThread: Thread?
    /// The animation of the layout asked for, until a pass takes it.
    private var pendingAnimation: Animation?
    /// The animation of the pass being solved in the background.
    private var solvingAnimation: Animation?

    /// Stack of the background solver's thread. The engine recurses once per nesting level;
    /// the 512 KiB of a task's thread holds a few hundred levels in an optimized build and a
    /// few dozen in an unoptimized one. A task cannot ask for a stack size, a thread can.
    nonisolated static let solverStackSize = 8 << 20

    /// Grows with every layout pass and measurement of any host: `NodeCache` tells passes
    /// apart by it.
    static var passGeneration: UInt64 = 0

    /// A host for `root`, which must not be mounted anywhere else.
    ///
    /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation:
    /// `detach()`.
    public init(root: Node, size: LayoutSize) {
        self.root = root
        self.size = size
        root.hostOfRoot = self
    }

    /// Marks the tree as needing a layout.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func setNeedsLayout() {
        if let animation = Animation.current {
            pendingAnimation = animation
        }
        guard !needsLayout else { return }

        needsLayout = true
        onNeedsLayout?()
    }

    /// Marks the tree as needing to be drawn again.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func setNeedsRender() {
        if let animation = Animation.current {
            renderAnimation = animation
        }
        guard !needsRender else { return }

        needsRender = true
        onNeedsRender?()
    }

    /// Tells the host the adapter has drawn the tree as it is now.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func didRender() {
        needsRender = false
        renderAnimation = nil
    }

    /// The size the tree takes under the given space — for `sizeThatFits` and
    /// `intrinsicContentSize`.
    ///
    /// Ownership: returns a value. Isolation: MainActor; synchronous. Errors: none.
    /// Cancellation: not applicable.
    public func fittingSize(
        width: AvailableSpace,
        height: AvailableSpace = .maxContent
    ) -> LayoutSize {
        StateUpdates.flush()
        NodeHost.passGeneration &+= 1
        return root.asLayoutSpec.measure(
            width: width,
            height: height,
            direction: direction,
            spacing: spacing
        )
    }

    /// Runs pending state updates, then lays the tree out if anything asked for it.
    ///
    /// Ownership: sets frames and subnodes of the tree. Isolation: MainActor; synchronous.
    /// Errors: none. Cancellation: not applicable.
    public func layoutIfNeeded() {
        StateUpdates.flush()
        guard needsLayout else { return }

        needsLayout = false
        generation &+= 1
        NodeHost.passGeneration &+= 1
        // A pass that overtakes an animated one still in flight carries its animation on.
        let animation = pendingAnimation ?? solvingAnimation
        pendingAnimation = nil
        cancelSolving()
        let prepared = root.asLayoutSpec.prepare(direction: direction, spacing: spacing)
        let rect = LayoutRect(origin: .zero, size: size)
        guard solvesInBackground, passes > 0, !prepared.requiresMainThread else {
            if let result = try? FlexboxEngine.layout(prepared.input, size: rect.size) {
                finish(prepared, result, in: rect, animation: animation)
            }
            return
        }

        solvingAnimation = animation
        solveInBackground(prepared, in: rect)
    }

    /// Waits for a background solve in flight, if any, and its frames to be applied.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: returns early if
    /// the solve is cancelled.
    public func layoutFinished() async {
        await solving?.value
    }

    private func finish(
        _ prepared: PreparedLayout,
        _ result: LayoutResult,
        in rect: LayoutRect,
        animation: Animation?
    ) {
        passes += 1
        needsRender = true
        if let animation {
            renderAnimation = animation
        }
        mount(prepared.apply(result, in: rect, scale: scale))
    }

    private func solveInBackground(_ prepared: PreparedLayout, in rect: LayoutRect) {
        let input = prepared.input
        let pass = generation
        solving = Task { [weak self] in
            let result = await NodeHost.solve(input, size: rect.size) { thread in
                self?.adopt(thread, pass: pass)
            }
            guard let self, pass == self.generation, let result else { return }

            let animation = self.solvingAnimation
            self.solving = nil
            self.solverThread = nil
            self.solvingAnimation = nil
            self.finish(prepared, result, in: rect, animation: animation)
            self.onNeedsRender?()
        }
    }

    /// Solves `input` on a thread of its own. The thread is handed to `started` from inside
    /// its body, once it certainly runs: a thread cancelled before its body starts never
    /// runs it, and the wait would never end. `nil` when cancelled.
    private nonisolated static func solve(
        _ input: LayoutNode,
        size: LayoutSize,
        started: @escaping @MainActor @Sendable (Thread) -> Void
    ) async -> LayoutResult? {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let running = Thread.current
                Task { @MainActor in started(running) }
                let context = LayoutContext(isCancelled: { Thread.current.isCancelled })
                continuation.resume(
                    returning: try? FlexboxEngine.layout(input, size: size, context: context)
                )
            }
            thread.stackSize = solverStackSize
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Keeps the running solver's thread so a newer layout can cancel it; a thread whose pass
    /// was already overtaken is cancelled at once.
    private func adopt(_ thread: Thread, pass: UInt64) {
        if pass == generation, solving != nil {
            solverThread = thread
        } else {
            thread.cancel()
        }
    }

    private func cancelSolving() {
        solving?.cancel()
        solving = nil
        solverThread?.cancel()
        solverThread = nil
        solvingAnimation = nil
    }

    // MARK: - Pointer

    /// A finger or the mouse went down at `point`, in the root's coordinates. Returns whether
    /// a node with `onTap` is under it — the node then shows itself pressed. When it returns
    /// `false`, the adapter passes the event on.
    ///
    /// Ownership: remembers the pressed node until the pointer goes up. Isolation:
    /// MainActor. Errors: none. Cancellation: `pointerCancelled()`.
    @discardableResult
    public func pointerDown(at point: LayoutPoint) -> Bool {
        pointerCancelled()
        var node = root.hitTest(point)
        while let current = node, current.onTap == nil {
            node = current.supernode
        }
        guard let target = node else { return false }

        pressed = target
        target.pressChanged(true)
        return true
    }

    /// The pointer went up at `point`: the pressed node is tapped if the pointer is still
    /// over it (or over a node inside it).
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func pointerUp(at point: LayoutPoint) {
        guard let target = pressed else { return }

        pressed = nil
        target.pressChanged(false)
        if let hit = root.hitTest(point), hit.isDescendant(of: target) {
            target.onTap?()
        }
    }

    /// The system took the pointer away (a scroll began, the window lost it): nothing is
    /// tapped.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func pointerCancelled() {
        guard let target = pressed else { return }

        pressed = nil
        target.pressChanged(false)
    }

    // MARK: - Focus

    /// The focused node's item, or `nil` — where the adapter draws a focus ring.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var focusedItem: FocusItem? {
        guard let focusedNode else { return nil }

        return focusItems().first { $0.node == focusedNode }
    }

    /// The nodes that can take focus, visible, in reading order, framed in the root's
    /// coordinates.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func focusItems() -> [FocusItem] {
        var items: [FocusItem] = []
        collectFocus(root, origin: .zero, into: &items)
        return items
    }

    /// The visible focus sections with focusable nodes inside, outer ones first.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func focusSections() -> [FocusSection] {
        var sections: [FocusSection] = []
        collectSections(root, origin: .zero, into: &sections)
        return sections
    }

    /// Moves the focus to `node` — the adapter calls it when the platform moved it — or
    /// clears it with `nil`. A node that is not mounted or cannot be focused clears it too.
    /// The nodes that lose and get the focus are told inside `focusAnimation`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func focus(_ node: NodeID?) {
        let target = node.flatMap { mounted[$0] }.flatMap { $0.canBecomeFocused ? $0 : nil }
        guard target?.id != focusedNode else { return }

        let previous = focusedNode.flatMap { mounted[$0] }
        focusedNode = target?.id
        // The adapter draws a focus ring, if any, at its next drawing.
        setNeedsRender()
        withAnimation(focusAnimation) {
            previous?.setFocused(false)
            target?.setFocused(true)
        }
    }

    /// Moves the focus by the keyboard, where the adapter decides it (AppKit has no focus
    /// system for parts of a view). With nothing focused, `.previous` focuses the last node
    /// and any other move the first. Returns `false`, leaving the focus as it is, when there
    /// is nowhere to go — Tab past the last node then goes on to the next view.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func moveFocus(_ move: FocusMove) -> Bool {
        let items = focusItems()
        guard !items.isEmpty else { return false }

        guard let current = items.firstIndex(where: { $0.node == focusedNode }) else {
            focus(move == .previous ? items[items.count - 1].node : items[0].node)
            return true
        }

        let target: FocusItem?
        switch move {
        case .next: target = current + 1 < items.count ? items[current + 1] : nil
        case .previous: target = current > 0 ? items[current - 1] : nil
        default: target = NodeHost.nearest(to: items[current], toward: move, among: items)
        }
        guard let target else { return false }

        focus(target.node)
        return true
    }

    /// The item nearest to `origin` that lies wholly toward `move`, preferring ones straight
    /// ahead: the distance ahead counts once, the distance aside twice. Ties go to reading
    /// order.
    private static func nearest(
        to origin: FocusItem,
        toward move: FocusMove,
        among items: [FocusItem]
    ) -> FocusItem? {
        let from = origin.frame
        var best: (item: FocusItem, score: Double)?
        for item in items where item.node != origin.node {
            let to = item.frame
            let ahead: Double
            let aside: Double
            switch move {
            case .up:
                ahead = from.origin.y - (to.origin.y + to.size.height)
                aside = gap(from.origin.x, from.size.width, to.origin.x, to.size.width)
            case .down:
                ahead = to.origin.y - (from.origin.y + from.size.height)
                aside = gap(from.origin.x, from.size.width, to.origin.x, to.size.width)
            case .left:
                ahead = from.origin.x - (to.origin.x + to.size.width)
                aside = gap(from.origin.y, from.size.height, to.origin.y, to.size.height)
            case .right:
                ahead = to.origin.x - (from.origin.x + from.size.width)
                aside = gap(from.origin.y, from.size.height, to.origin.y, to.size.height)
            case .next, .previous:
                return nil
            }
            guard ahead >= 0 else { continue }

            let score = ahead + 2 * aside
            if best == nil || score < best!.score {
                best = (item, score)
            }
        }
        return best?.item
    }

    /// How far apart two spans are along one axis; 0 when they overlap.
    private static func gap(_ a: Double, _ aLength: Double, _ b: Double, _ bLength: Double)
        -> Double
    {
        max(0, max(b - (a + aLength), a - (b + bLength)))
    }

    /// The remote's select button went down: the focused node shows itself pressed. Returns
    /// whether a focused node has `onTap`; when not, the adapter passes the press on.
    ///
    /// Ownership: remembers the pressed node until the button goes up. Isolation: MainActor.
    /// Errors: none. Cancellation: `pointerCancelled()`.
    @discardableResult
    public func selectBegan() -> Bool {
        pointerCancelled()
        guard let target = focusedNode.flatMap({ mounted[$0] }), target.onTap != nil else {
            return false
        }

        pressed = target
        target.pressChanged(true)
        return true
    }

    /// The select button went up: the pressed node is tapped.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func selectEnded() {
        guard let target = pressed else { return }

        pressed = nil
        target.pressChanged(false)
        target.onTap?()
    }

    private func collectFocus(_ node: Node, origin: LayoutPoint, into items: inout [FocusItem]) {
        guard !node.isHidden, node.appearance.opacity > 0 else { return }

        let frame = LayoutRect(
            x: origin.x + node.frame.origin.x,
            y: origin.y + node.frame.origin.y,
            width: node.frame.size.width,
            height: node.frame.size.height
        )
        if node.canBecomeFocused {
            items.append(
                FocusItem(node: node.id, frame: frame, cornerRadius: node.appearance.cornerRadius)
            )
            return
        }

        for subnode in node.subnodes {
            collectFocus(subnode, origin: frame.origin, into: &items)
        }
    }

    private func collectSections(
        _ node: Node,
        origin: LayoutPoint,
        into sections: inout [FocusSection]
    ) {
        guard !node.isHidden, node.appearance.opacity > 0 else { return }

        let frame = LayoutRect(
            x: origin.x + node.frame.origin.x,
            y: origin.y + node.frame.origin.y,
            width: node.frame.size.width,
            height: node.frame.size.height
        )
        if node.isFocusSection {
            var items: [FocusItem] = []
            collectFocus(node, origin: origin, into: &items)
            if !items.isEmpty {
                sections.append(FocusSection(node: node.id, frame: frame, items: items.map(\.node)))
            }
        }

        for subnode in node.subnodes {
            collectSections(subnode, origin: frame.origin, into: &sections)
        }
    }

    // MARK: - Accessibility

    /// The accessibility elements of the tree at its last layout, in reading order.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func accessibilityItems() -> [AccessibilityItem] {
        var items: [AccessibilityItem] = []
        collect(root, origin: .zero, into: &items)
        return items
    }

    /// Performs the default action of the element for `node` — its tap. Returns whether it
    /// had one.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func activate(_ node: NodeID) -> Bool {
        guard let action = mounted[node]?.onTap else { return false }

        action()
        return true
    }

    private func collect(_ node: Node, origin: LayoutPoint, into items: inout [AccessibilityItem]) {
        guard !node.isHidden, node.appearance.opacity > 0 else { return }

        let frame = LayoutRect(
            x: origin.x + node.frame.origin.x,
            y: origin.y + node.frame.origin.y,
            width: node.frame.size.width,
            height: node.frame.size.height
        )
        let settings = node.accessibility
        let ownLabel = settings.label ?? node.accessibilityContentLabel
        let isElement =
            settings.isElement ?? (node.onTap != nil || (ownLabel.map { !$0.isEmpty } ?? false))
        guard isElement else {
            for subnode in node.subnodes {
                collect(subnode, origin: frame.origin, into: &items)
            }
            return
        }

        var traits = node.accessibilityContentTraits.union(settings.traits)
        if node.onTap != nil {
            traits.insert(.button)
            traits.remove(.staticText)
        }
        items.append(
            AccessibilityItem(
                node: node.id,
                frame: frame,
                label: ownLabel ?? spokenText(inside: node),
                value: settings.value,
                hint: settings.hint,
                traits: traits
            )
        )
    }

    /// The labels of the visible nodes inside `node`, in order — the name of an element made
    /// of several nodes.
    private func spokenText(inside node: Node) -> String {
        var parts: [String] = []
        func visit(_ node: Node) {
            guard !node.isHidden, node.appearance.opacity > 0,
                node.accessibility.isElement != false
            else { return }

            if let label = node.accessibility.label ?? node.accessibilityContentLabel,
                !label.isEmpty
            {
                parts.append(label)
                return
            }

            node.subnodes.forEach(visit)
        }
        node.subnodes.forEach(visit)
        return parts.joined(separator: ", ")
    }

    /// Unmounts the whole tree and lets go of the root's host role. The host does nothing
    /// afterwards.
    ///
    /// Ownership: releases the tree's subscriptions. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation.
    public func detach() {
        pointerCancelled()
        focus(nil)
        generation &+= 1
        cancelSolving()
        for node in mounted.values {
            node.unmount()
        }
        mounted = [:]
        root.unmount()
        root.hostOfRoot = nil
        onNeedsLayout = nil
        onNeedsRender = nil
    }

    /// Makes the tree match the placements: each node's subnodes are the nodes placed by its
    /// layout, in order. A node placed twice (both sides of a `Breakpoint`) belongs where it
    /// was laid out.
    private func mount(_ placements: [LayoutPlacement]) {
        var present: [NodeID: Node] = [root.id: root]
        var parent: [NodeID: Node] = [:]
        for placement in placements {
            guard let node = placement.element as? Node, node !== root else { continue }

            present[node.id] = node
            if let container = placement.container as? Node,
                placement.frame != nil || parent[node.id] == nil
            {
                parent[node.id] = container
            }
        }

        var children: [NodeID: [Node]] = [:]
        var listed: Set<NodeID> = []
        for placement in placements {
            guard let node = placement.element as? Node, let container = parent[node.id],
                placement.container === container, !listed.contains(node.id)
            else { continue }

            listed.insert(node.id)
            children[container.id, default: []].append(node)
        }

        if let focusedNode, present[focusedNode] == nil {
            focus(nil)
        }
        for (id, node) in mounted where present[id] == nil {
            node.unmount()
        }
        for (id, node) in present {
            node.mount(in: parent[id], subnodes: children[id] ?? [])
        }
        mounted = present
    }
}
