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

    /// Scrolls whose offset changed since the adapter last drew, when nothing else did and
    /// the change was not animated: the adapter may move just their content and focus ring
    /// instead of drawing the whole tree. Cleared by `didRender()`.
    ///
    /// Ownership: the host keeps the nodes until the next drawing. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public private(set) var scrolledSinceRender: [Scroll] = []

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

    /// Set by the adapter: asks the platform to move the focus to a node (`requestFocus`).
    /// Without one the host focuses the node itself.
    ///
    /// Ownership: the host keeps the closure; it must not keep the host. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onFocusRequest: (@MainActor (NodeID) -> Void)?

    /// How focused nodes show the focus; the adapter sets it for its platform. A change
    /// reaches nodes at their next `focusChanged`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var focusLook: FocusLook = .lift

    /// Layout passes applied so far — for tests and diagnostics. A rejected pass does not
    /// count.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var passes = 0

    /// 1, 2, … in the order hosts are created — the `host=` of their reports.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let number: Int

    /// Called after every layout pass with what it found. The adapter sets one that logs
    /// problems; an app can replace it.
    ///
    /// Ownership: the host keeps the closure; it must not keep the host. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onLayoutReport: (@MainActor (LayoutReport) -> Void)?

    /// What the engine records for the report: nothing when empty.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var traceAreas: Set<LayoutTraceArea> = []

    /// The nodes traced, with the containers of their layouts; `nil` traces every node.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var tracedNodes: Set<NodeID>?

    /// Stack the engine may use when it solves on the main thread — the first layout, and
    /// every layout when not `solvesInBackground` — so that a tree too deep for that stack
    /// does not crash it. Such a tree is solved on the host's own thread instead, whose
    /// stack is far larger, and shows one frame later. A layout with views inside cannot
    /// move, and is rejected. `nil` sets no limit.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var mainThreadStackBudget: Int? = LayoutContext.currentThreadStackBudget

    private var mounted: [NodeID: Node] = [:]
    /// Mounted nodes whose layout depends on where they show, in layout order.
    private var viewportDependents: [any ViewportDependent] = []
    /// Mounted nodes that track whether they are on screen, in layout order.
    private var screenTrackers: [Node] = []
    /// Nodes of the layout being solved in the background that are not mounted yet.
    private var pending: [Node] = []
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

    /// Stack of the solver's thread kept for the frames the engine calls into (measuring
    /// text), beyond its own recursion.
    nonisolated static let solverStackReserve = 256 << 10

    /// Grows with every layout pass and measurement of any host: `NodeCache` tells passes
    /// apart by it.
    static var passGeneration: UInt64 = 0

    private static var created = 0

    /// Passes one `layoutIfNeeded()` may run: after a pass, a node whose layout depends on
    /// where it shows (a lazy stack) may find it needs another one — its first pass had to
    /// guess where it is, and items it laid out may be longer or shorter than it assumed.
    /// Each pass brings it closer; the limit stops a guess that never settles.
    static let settlingPasses = 4

    /// The host whose tree is asked for its layouts now: a node not yet mounted, in its
    /// first layout, learns from it the size of the screen it is going to be on.
    private(set) static var preparing: NodeHost?

    /// A host for `root`, which must not be mounted anywhere else.
    ///
    /// Ownership: keeps `root`. Isolation: MainActor. Errors: none. Cancellation:
    /// `detach()`.
    public init(root: Node, size: LayoutSize) {
        self.root = root
        self.size = size
        NodeHost.created += 1
        number = NodeHost.created
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

    /// Marks `scroll` as scrolled: without an animation the adapter can move just its
    /// content (`scrolledSinceRender`); with one, the whole tree is drawn with it.
    func setNeedsScrollRender(_ scroll: Scroll) {
        guard Animation.current == nil else {
            setNeedsRender()
            return
        }
        guard !scrolledSinceRender.contains(where: { $0 === scroll }) else { return }

        let wasQuiet = !needsRender && scrolledSinceRender.isEmpty
        scrolledSinceRender.append(scroll)
        if wasQuiet {
            onNeedsRender?()
        }
    }

    /// Tells the host the adapter has drawn the tree as it is now.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func didRender() {
        needsRender = false
        renderAnimation = nil
        scrolledSinceRender = []
    }

    /// The size the tree takes under the given space — for `sizeThatFits` and
    /// `intrinsicContentSize`. It is measured on the calling thread; a tree too deep for its
    /// stack measures as zero instead of crashing.
    ///
    /// Ownership: returns a value. Isolation: MainActor; synchronous. Errors: none.
    /// Cancellation: not applicable.
    public func fittingSize(
        width: AvailableSpace,
        height: AvailableSpace = .maxContent
    ) -> LayoutSize {
        StateUpdates.flush()
        NodeHost.passGeneration &+= 1
        let outer = NodeHost.preparing
        NodeHost.preparing = self
        defer { NodeHost.preparing = outer }
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
        for _ in 0..<NodeHost.settlingPasses {
            StateUpdates.flush()
            guard needsLayout, layOut() else { return }
        }
    }

    /// Lays the tree out; returns whether the pass was applied on this thread, rather than
    /// sent to the background or rejected.
    private func layOut() -> Bool {
        needsLayout = false
        generation &+= 1
        NodeHost.passGeneration &+= 1
        // A pass that overtakes an animated one still in flight carries its animation on.
        let animation = pendingAnimation ?? solvingAnimation
        pendingAnimation = nil
        cancelSolving()
        let outer = NodeHost.preparing
        NodeHost.preparing = self
        let prepared = root.asLayoutSpec.prepare(direction: direction, spacing: spacing)
        NodeHost.preparing = outer
        let rect = LayoutRect(origin: .zero, size: size)
        let trace = traceRequest(for: prepared)
        guard solvesInBackground, passes > 0, !prepared.requiresMainThread else {
            let context = LayoutContext(trace: trace, stackBudget: mainThreadStackBudget)
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let result = try FlexboxEngine.layout(
                    prepared.input,
                    size: rect.size,
                    context: context
                )
                return finish(
                    prepared,
                    result,
                    duration: clock.now - start,
                    stack: .enough,
                    in: rect,
                    animation: animation
                )
            } catch is LayoutStackExhausted where !prepared.requiresMainThread {
                solvingAnimation = animation
                solveInBackground(prepared, trace: trace, stack: .moved, in: rect)
            } catch is LayoutStackExhausted {
                reject(prepared, duration: clock.now - start)
            } catch {}
            return false
        }

        solvingAnimation = animation
        solveInBackground(prepared, trace: trace, stack: .enough, in: rect)
        return false
    }

    /// Reports a pass too deep for any thread it could be solved on; the tree keeps the
    /// pass before.
    private func reject(_ prepared: PreparedLayout, duration: Duration) {
        onLayoutReport?(
            LayoutReport(
                host: number,
                generation: generation,
                elements: prepared.elementCount,
                duration: duration,
                duplicates: [],
                isRejected: true,
                stack: .exhausted,
                variantsWithoutWidth: [],
                trace: []
            )
        )
    }

    /// The engine's trace request for `traceAreas` and `tracedNodes`: their ids in
    /// `prepared`, with the containers of their layouts.
    private func traceRequest(for prepared: PreparedLayout) -> LayoutTraceRequest? {
        guard !traceAreas.isEmpty else { return nil }

        guard let tracedNodes else { return LayoutTraceRequest(areas: traceAreas) }

        return LayoutTraceRequest(
            areas: traceAreas,
            ids: prepared.ids { ($0 as? Node).map { tracedNodes.contains($0.id) } ?? false }
        )
    }

    /// Waits for a background solve in flight, if any, and its frames to be applied.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: returns early if
    /// the solve is cancelled.
    public func layoutFinished() async {
        await solving?.value
    }

    /// Applies a solved pass, unless an element got a frame in two places: an element has
    /// one frame, and applying either would hide the mistake. The tree then keeps the pass
    /// before, and the report names the elements. Returns whether the pass was applied.
    @discardableResult
    private func finish(
        _ prepared: PreparedLayout,
        _ result: LayoutResult,
        duration: Duration,
        stack: LayoutReport.Stack,
        in rect: LayoutRect,
        animation: Animation?
    ) -> Bool {
        let duplicates = prepared.elementsPlacedMoreThanOnce(in: result)
        if let onLayoutReport {
            onLayoutReport(
                report(prepared, result, duration: duration, stack: stack, duplicates: duplicates)
            )
        }
        guard duplicates.isEmpty else { return false }

        passes += 1
        needsRender = true
        if let animation {
            renderAnimation = animation
        }
        mount(prepared.apply(result, in: rect, scale: scale))
        for dependent in viewportDependents {
            dependent.layoutApplied()
        }
        updateScreen()
        return true
    }

    /// A scroll moved: nodes whose layout depends on where they show look again, and nodes
    /// that track the screen learn whether they are on it.
    func viewportMoved() {
        for dependent in viewportDependents {
            dependent.viewportMoved()
        }
        updateScreen()
    }

    private func updateScreen() {
        for node in screenTrackers {
            node.updateScreen()
        }
    }

    private func report(
        _ prepared: PreparedLayout,
        _ result: LayoutResult,
        duration: Duration,
        stack: LayoutReport.Stack,
        duplicates: [any LayoutElement]
    ) -> LayoutReport {
        func node(_ id: LayoutID) -> NodeID? { (prepared.element(for: id) as? Node)?.id }
        var widthless: [NodeID] = []
        for id in result.variantsWithoutWidth {
            if let node = node(id), !widthless.contains(node) {
                widthless.append(node)
            }
        }
        return LayoutReport(
            host: number,
            generation: generation,
            elements: prepared.elementCount,
            duration: duration,
            duplicates: duplicates.compactMap { ($0 as? Node)?.id },
            isRejected: !duplicates.isEmpty,
            stack: stack,
            variantsWithoutWidth: widthless.sorted { $0.raw < $1.raw },
            trace: result.trace.map { event in
                LayoutReport.Trace(
                    node: node(event.id),
                    isContainer: !prepared.isElement(event.id),
                    event: event
                )
            }
        )
    }

    private func solveInBackground(
        _ prepared: PreparedLayout,
        trace: LayoutTraceRequest?,
        stack: LayoutReport.Stack,
        in rect: LayoutRect
    ) {
        let input = prepared.input
        let pass = generation
        releasePending()
        for case let node as Node in prepared.mentionedElements where !node.isMounted {
            node.pendingHost = self
            pending.append(node)
        }
        solving = Task { [weak self] in
            let outcome = await NodeHost.solve(input, size: rect.size, trace: trace) { thread in
                self?.adopt(thread, pass: pass)
            }
            guard let self, pass == self.generation else { return }

            let animation = self.solvingAnimation
            switch outcome {
            case .cancelled:
                return
            case let .tooDeep(duration):
                self.releasePending()
                self.solving = nil
                self.solverThread = nil
                self.solvingAnimation = nil
                self.reject(prepared, duration: duration)
            case let .solved(result, duration):
                self.releasePending()
                self.solving = nil
                self.solverThread = nil
                self.solvingAnimation = nil
                self.finish(
                    prepared,
                    result,
                    duration: duration,
                    stack: stack,
                    in: rect,
                    animation: animation
                )
                self.onNeedsRender?()
            }
        }
    }

    /// How a solve on the host's thread ended.
    private enum SolveOutcome: Sendable {
        case solved(LayoutResult, Duration)
        case tooDeep(Duration)
        case cancelled
    }

    /// Solves `input` on a thread of its own. The thread is handed to `started` from inside
    /// its body, once it certainly runs: a thread cancelled before its body starts never
    /// runs it, and the wait would never end.
    private nonisolated static func solve(
        _ input: LayoutNode,
        size: LayoutSize,
        trace: LayoutTraceRequest?,
        started: @escaping @MainActor @Sendable (Thread) -> Void
    ) async -> SolveOutcome {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let running = Thread.current
                Task { @MainActor in started(running) }
                let context = LayoutContext(
                    isCancelled: { Thread.current.isCancelled },
                    trace: trace,
                    stackBudget: solverStackSize - solverStackReserve
                )
                let clock = ContinuousClock()
                let start = clock.now
                let outcome: SolveOutcome
                do {
                    let result = try FlexboxEngine.layout(input, size: size, context: context)
                    outcome = .solved(result, clock.now - start)
                } catch is LayoutStackExhausted {
                    outcome = .tooDeep(clock.now - start)
                } catch {
                    outcome = .cancelled
                }
                continuation.resume(returning: outcome)
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

    private func releasePending() {
        for node in pending where node.pendingHost === self {
            node.pendingHost = nil
        }
        pending = []
    }

    private func cancelSolving() {
        releasePending()
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

    /// The mounted node with `id`, or `nil`.
    ///
    /// Ownership: returns a node of the tree. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func node(_ id: NodeID) -> Node? {
        mounted[id]
    }

    // MARK: - Scrolls

    /// The visible scrolls of the tree, outer ones first, framed in the root's coordinates
    /// — for the adapter to put the platform's scrolling over them.
    ///
    /// Ownership: returns values referring to nodes of the tree. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func scrollItems() -> [ScrollItem] {
        var items: [ScrollItem] = []
        root.walkVisible(from: .zero) { node, origin in
            if let scroll = node as? Scroll {
                items.append(ScrollItem(scroll: scroll, frame: scroll.frame(from: origin)))
            }
            return true
        }
        return items
    }

    /// The scrolls under `point`, in the root's coordinates, that have somewhere to scroll,
    /// the innermost first. A drag moves the first one of its axis; a wheel that has taken
    /// one to its end goes on to the next.
    ///
    /// Ownership: returns nodes of the tree. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func scrolls(at point: LayoutPoint) -> [Scroll] {
        var found: [Scroll] = []
        var node = root.hitTest(point)
        while let current = node {
            if let scroll = current as? Scroll, scroll.canScroll {
                found.append(scroll)
            }
            node = current.supernode
        }
        return found
    }

    /// Scrolls every scroll around `node`, the innermost first, so that it shows — where an
    /// assistive technology moved to a node out of sight. With `withAnimation`, it moves with
    /// it.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func reveal(_ node: NodeID) {
        guard let target = mounted[node] else { return }

        reveal(target)
    }

    /// Scrolls the scroll around `node` by one window, as an assistive technology asks
    /// (three fingers on VoiceOver): along `axis`, or along either for `nil`, `forward`
    /// toward the content's end. Returns the page it shows then, or `nil` when no scroll
    /// around the node could move that way.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func scrollPage(around node: NodeID, axis: ScrollAxis?, forward: Bool) -> ScrollPage? {
        var current = mounted[node]
        while let ancestor = current {
            if let scroll = ancestor as? Scroll, axis == nil || scroll.axis == axis,
                let page = scroll.scrollPage(forward: forward)
            {
                return page
            }
            current = ancestor.supernode
        }
        return nil
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

    /// Asks for the focus to move to `node` — for the app, where it wants the focus (after
    /// opening a screen, after a change). The platform's focus system moves it, and the
    /// node learns of it as of any move; a platform may refuse, when the view is not where
    /// the focus is. A node that is not mounted or cannot be focused is ignored.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func requestFocus(_ node: NodeID) {
        guard let target = mounted[node], target.canBecomeFocused else { return }

        if let onFocusRequest {
            onFocusRequest(node)
        } else {
            focus(node)
        }
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
            if let target {
                reveal(target)
            }
        }
    }

    /// Scrolls every scroll around `node`, the innermost first, so that the node shows.
    private func reveal(_ node: Node) {
        var current = node.supernode
        while let ancestor = current {
            if let scroll = ancestor as? Scroll {
                scroll.scrollToReveal(node)
            }
            current = ancestor.supernode
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
        node.walkVisible(from: origin) { node, origin in
            guard node.canBecomeFocused else { return true }

            items.append(
                FocusItem(
                    node: node.id,
                    frame: node.frame(from: origin),
                    cornerRadius: node.appearance.cornerRadius
                )
            )
            return false
        }
    }

    private func collectSections(
        _ node: Node,
        origin: LayoutPoint,
        into sections: inout [FocusSection]
    ) {
        node.walkVisible(from: origin) { node, origin in
            if node.isFocusSection {
                var items: [FocusItem] = []
                collectFocus(node, origin: origin, into: &items)
                if !items.isEmpty {
                    sections.append(
                        FocusSection(
                            node: node.id,
                            frame: node.frame(from: origin),
                            items: items.map(\.node)
                        )
                    )
                }
            }
            return true
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
        node.walkVisible(from: origin) { node, origin in
            let settings = node.accessibility
            let ownLabel = settings.label ?? node.accessibilityContentLabel
            let isElement =
                settings.isElement
                ?? (node.onTap != nil || (ownLabel.map { !$0.isEmpty } ?? false))
            guard isElement else { return true }

            var traits = node.accessibilityContentTraits.union(settings.traits)
            if node.onTap != nil {
                traits.insert(.button)
                traits.remove(.staticText)
            }
            items.append(
                AccessibilityItem(
                    node: node.id,
                    frame: node.frame(from: origin),
                    label: ownLabel ?? spokenText(inside: node),
                    value: settings.value,
                    hint: settings.hint,
                    traits: traits
                )
            )
            return false
        }
    }

    /// The labels of the visible nodes inside `node`, in order — the name of an element made
    /// of several nodes.
    private func spokenText(inside node: Node) -> String {
        var parts: [String] = []
        node.walkVisible(from: .zero) { inner, _ in
            // The node itself only leads to its subnodes.
            guard inner !== node else { return true }
            guard inner.accessibility.isElement != false else { return false }

            if let label = inner.accessibility.label ?? inner.accessibilityContentLabel,
                !label.isEmpty
            {
                parts.append(label)
                return false
            }
            return true
        }
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
        viewportDependents = []
        screenTrackers = []
        root.unmount()
        root.hostOfRoot = nil
        onNeedsLayout = nil
        onNeedsRender = nil
        onFocusRequest = nil
    }

    /// Makes the tree match the placements: each node's subnodes are the nodes placed by its
    /// layout, in order. A node placed twice (both sides of a `Breakpoint`) belongs where it
    /// was laid out.
    private func mount(_ placements: [LayoutPlacement]) {
        var present: [NodeID: Node] = [root.id: root]
        var parent: [NodeID: Node] = [:]
        var dependents: [any ViewportDependent] = []
        var trackers: [Node] = []
        if let dependent = root as? any ViewportDependent {
            dependents.append(dependent)
        }
        if root.tracksScreen {
            trackers.append(root)
        }
        for placement in placements {
            guard let node = placement.element as? Node, node !== root else { continue }

            if present[node.id] == nil {
                if let dependent = node as? any ViewportDependent {
                    dependents.append(dependent)
                }
                if node.tracksScreen {
                    trackers.append(node)
                }
            }
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
        viewportDependents = dependents
        screenTrackers = trackers
    }
}
