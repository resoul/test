import Foundation

/// State a page keeps while the pager has evicted its UI (P6.9): a container's reading
/// position, a table's selection. Opaque to the pager.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PageState: Sendable {
    /// The captured value; only the node type that produced it interprets it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let value: any Sendable

    /// Wraps a captured value.
    ///
    /// Ownership: copies `value`. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ value: any Sendable) {
        self.value = value
    }
}

/// A node inside a page that keeps state across eviction (R13, P6.9). Before a page leaves
/// the mounted range the pager asks every such node in the page, in tree order, for its state;
/// when the page's factory builds it again the states go back in the same order.
///
/// Ownership: implemented by nodes. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
public protocol PageStateRestoring: AnyObject {
    /// The state to keep, or `nil` for nothing.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func capturePageState() -> PageState?

    /// Applies a state captured earlier by the same kind of node.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: an unknown state is ignored.
    /// Cancellation: not applicable.
    func restorePageState(_ state: PageState)
}

/// One page of a pager: a stable ID, a title and its content (P6.5). A factory builds the
/// content only while the page is mounted and may be called again after eviction — it must
/// not start requests; loading belongs to the mounted content (D14, ADR 0032). An eager
/// `content` node is never disposed by eviction, only detached.
///
/// Ownership: retains the factory or the eager node. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public struct Tab<ID: Hashable & Sendable> {
    /// Stable page identity; selection, progress and page state refer to it.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let id: ID

    /// Title shown by `TabsNode` and read by accessibility.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var title: String

    let factory: (@MainActor () -> Node)?
    let eagerContent: Node?

    /// A page built on demand.
    ///
    /// Ownership: retains `makeContent`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(id: ID, title: String, makeContent: @escaping @MainActor () -> Node) {
        self.id = id
        self.title = title
        self.factory = makeContent
        self.eagerContent = nil
    }

    /// A page with a prebuilt node — a convenience for small scenes. The node must not be
    /// used by another page or host.
    ///
    /// Ownership: retains `content`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(id: ID, title: String, content: Node) {
        self.id = id
        self.title = title
        self.factory = nil
        self.eagerContent = content
    }
}

/// Where the pager is between pages (P6.5): the committed page it leaves, the page it moves
/// toward, how far (0 at `from`, 1 at `to`) and, once released, the page it settles on.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PagerProgress<ID: Hashable & Sendable>: Sendable, Hashable {
    /// The page the movement started from.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let from: ID?

    /// The page the movement heads to (equal to `from` at rest).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let to: ID?

    /// Fraction of the way from `from` to `to`, in 0...1.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let fraction: Double

    /// The committed page once the movement is released; `nil` while a finger drives it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let settled: ID?

    /// Creates a progress value; `fraction` is clamped to 0...1.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(from: ID?, to: ID?, fraction: Double, settled: ID?) {
        self.from = from
        self.to = to
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.settled = settled
    }
}

/// Horizontal pan for pages (R13): begins when the first movement past the threshold is at
/// least as horizontal as vertical and `shouldBegin` agrees; a vertical start fails it and
/// leaves the gesture to the page's own vertical scroll. Reports the physical horizontal
/// translation and velocity (points per second, measured on delivery).
///
/// Ownership: owned by the pager. Isolation: MainActor. Errors: none. Cancellation: `reset()`
/// or a pointer cancel reports `.cancelled`.
@MainActor
public final class PagerPanRecognizer: GestureRecognizer {
    /// Recognition state.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var state: GestureState = .possible

    /// Called with the state, the translation and the velocity along x.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var onPan: (@MainActor (GestureState, Double, Double) -> Void)?

    /// Asked once, when horizontal movement passes the threshold.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var shouldBegin: (@MainActor () -> Bool)?

    /// Time source in seconds; replaceable for deterministic tests.
    var now: () -> Double = {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private let threshold: Double
    private var down: PointerData?
    private var last = 0.0
    private var samples: [(time: Double, x: Double)] = []

    /// Creates a recognizer with a movement threshold.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(threshold: Double = 10) {
        self.threshold = threshold
    }

    /// Consumes pointer events of one pointer.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func handle(_ event: Event) -> GestureResult {
        guard let data = event.pointer else { return .ignored }

        switch event.type {
        case .pointerDown where down == nil && state == .possible:
            down = data
            samples = [(now(), data.point.x)]
            return .ignored
        case .pointerMove where down?.pointerID == data.pointerID:
            guard let down else { return .ignored }

            record(data.point.x)
            let dx = data.point.x - down.point.x
            let dy = data.point.y - down.point.y
            switch state {
            case .possible:
                guard max(abs(dx), abs(dy)) > threshold else { return .ignored }
                guard abs(dx) >= abs(dy), shouldBegin?() ?? true else {
                    state = .failed
                    return .failed
                }

                return step(.began, dx)
            case .began, .changed:
                return step(.changed, dx)
            default:
                return .ignored
            }
        case .pointerUp where down?.pointerID == data.pointerID:
            defer { down = nil }
            guard state == .began || state == .changed, let down else {
                state = .failed
                return .failed
            }

            record(data.point.x)
            return step(.ended, data.point.x - down.point.x)
        case .pointerCancel where down?.pointerID == data.pointerID:
            defer { down = nil }
            guard state == .began || state == .changed else {
                state = .cancelled
                return .cancelled
            }

            return step(.cancelled, last)
        default:
            return .ignored
        }
    }

    /// Returns to `.possible`, cancelling a running pan.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: this is the
    /// cancellation point.
    public func reset() {
        if state == .began || state == .changed {
            _ = step(.cancelled, last)
        }
        down = nil
        last = 0
        samples = []
        state = .possible
    }

    private func record(_ x: Double) {
        let time = now()
        samples.append((time, x))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Velocity over the last 100 ms of samples.
    private var velocity: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else {
            return 0
        }

        return (last.x - first.x) / (last.time - first.time)
    }

    private func step(_ next: GestureState, _ translation: Double) -> GestureResult {
        state = next
        last = translation
        onPan?(next, translation, next == .ended ? velocity : 0)
        switch next {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .cancelled: return .cancelled
        default: return .ignored
        }
    }
}

/// Weak registration of an observer of a pager (a `TabsNode`).
@MainActor
struct PagerObservation<ID: Hashable & Sendable> {
    weak var owner: AnyObject?
    let tabsChanged: @MainActor () -> Void
    let progressChanged: @MainActor (PagerProgress<ID>, Animation) -> Void
}

/// Horizontal pages with stable IDs, moved by the pager's own pan (user decision R13:
/// Telegram-style, not a native paging scroll view), by `select(_:animated:)` and by
/// `TabsNode` (P6.5, ADR 0036).
///
/// Only the selected page and its neighbours are mounted; other pages are evicted after the
/// movement settles, their `PageStateRestoring` nodes' states kept by page ID and handed back
/// when the factory builds the page again. The pager sets `RowSwipeContextKey` to `false` for
/// its pages, so tables leave the horizontal gesture to it (P6.6). One gesture owner: a pan
/// starting while a page's vertical scroll is user-driven fails, and a running pan disables
/// the mounted pages' scroll interaction until it ends (ADR 0029).
///
/// `progress` is the single model the pages and the tab indicator follow: during a drag it
/// changes with the finger and no animation; on release the selection commits at once and the
/// remaining movement is one animation published with the progress, so observers animate with
/// the same curve and duration. A pan grabbing a settling pager continues from the position on
/// screen.
///
/// Ownership: owns mounted page nodes built by factories (disposed on eviction) and hosts
/// eager nodes without disposing them on eviction; keeps the host weakly. Isolation:
/// MainActor. Errors: none. Cancellation: leaving the host cancels a running pan (the pager
/// returns to the selected page) and pending eviction; `dispose()` disposes all mounted pages.
@MainActor
public final class PagerNode<ID: Hashable & Sendable>: Node, HostedContainer {
    /// The pages in reading order. Assigning keeps the selection by ID; when the selected
    /// page is removed, the page now at its index (else the last page) is selected.
    ///
    /// Ownership: retains factories and eager nodes. Isolation: MainActor. Errors: duplicate
    /// IDs keep the first page. Cancellation: not applicable.
    public var tabs: [Tab<ID>] {
        didSet { tabsDidChange(from: oldValue) }
    }

    /// The committed page.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var selection: ID?

    /// Where the pages are between pages; see the type documentation.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var progress: PagerProgress<ID>

    /// Whether the horizontal pan moves pages; `select(_:animated:)` and tabs always work.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var isSwipeEnabled = true

    /// Animation of the movement after release and of `select(_:animated:)`. Reduce Motion
    /// replaces it with no animation.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var settleAnimation = Animation.easeOut(duration: .milliseconds(280))

    /// Called when the committed page changes.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var onSelectionChange: (@MainActor (ID) -> Void)?

    /// Called with every progress change and the animation it runs with (`.none` while a
    /// finger drives it).
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var onProgressChange: (@MainActor (PagerProgress<ID>, Animation) -> Void)?

    /// The pan recognizer, exposed for arbitration by composite containers.
    ///
    /// Ownership: owned. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let pan = PagerPanRecognizer()

    /// The pager's own horizontal scroll view: user scrolling off, moved only by the pager.
    /// Pages and their native scroll views live in its content, so it clips and moves them.
    private let scroll = ScrollNode()
    private let strip = Node()
    private var slots: [ID: Slot] = [:]
    private var states: [ID: [PageState]] = [:]
    private var position = 0.0
    private var jump: (id: ID, displayIndex: Int)?
    private var pageWidth = 0.0
    private var drag: (base: Double, start: Int)?
    private var frozenScrolls: [ScrollNode] = []
    private var settleGeneration: UInt64 = 0
    private var isSettling = false
    private var observers: [PagerObservation<ID>] = []
    private weak var host: (any ContainerHost)?

    private struct Slot {
        let wrapper: Node
        let content: Node
        let isEager: Bool
    }

    /// Creates a pager showing `selection` (the first page by default).
    ///
    /// Ownership: retains `tabs`. Isolation: MainActor. Errors: an unknown selection selects
    /// the first page. Cancellation: not applicable.
    public init(tabs: [Tab<ID>], selection: ID? = nil, style: LayoutStyle = LayoutStyle()) {
        let unique = Self.unique(tabs)
        self.tabs = unique
        let selected =
            selection.flatMap { id in unique.contains { $0.id == id } ? id : nil }
            ?? unique.first?.id
        self.selection = selected
        self.progress = PagerProgress(from: selected, to: selected, fraction: 0, settled: selected)
        super.init(style: style)
        scroll.configuration = ScrollConfiguration(
            axis: .horizontal,
            userInteractionEnabled: false,
            indicators: .hidden,
            bounce: .never
        )
        scroll.style {
            $0.positionType = .absolute
            $0.offsets = DirectionalEdgeOffsets(top: 0, leading: 0)
            $0.width = .fraction(1)
            $0.height = .fraction(1)
        }
        strip.style {
            $0.alignSelf = .stretch
            $0.width = .points(0)
            $0.flexShrink = 0
        }
        strip.setEnvironment(RowSwipeContextKey.self, to: false)
        scroll.addSubnode(strip)
        addSubnode(scroll)
        position = Double(selectedIndex ?? 0)
        pan.shouldBegin = { [weak self] in self?.panMayBegin() ?? false }
        pan.onPan = { [weak self] state, translation, velocity in
            self?.panned(state, translation: translation, velocity: velocity)
        }
        addGestureRecognizer(pan)
        reconcileMounted(immediate: true)
        applyPosition()
    }

    /// IDs of pages that have nodes now, in page order.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var mountedIDs: [ID] {
        tabs.map(\.id).filter { slots[$0] != nil }
    }

    /// The mounted content node of page `id`, or `nil`.
    ///
    /// Ownership: the pager keeps owning it. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func page(for id: ID) -> Node? {
        slots[id]?.content
    }

    /// Commits `id` as the selected page; `animated` slides to it with `settleAnimation`. A
    /// page more than one step away slides in next to the current one. A running pan is
    /// cancelled. An unknown ID is ignored.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: a later select or pan
    /// retargets from the position on screen.
    public func select(_ id: ID, animated: Bool = true) {
        guard let target = index(of: id) else { return }

        if drag != nil {
            pan.reset()
        }
        normalizeJump()
        let current = Int(position.rounded())
        if animated, abs(target - current) > 1, pageWidth > 0 {
            // Slide the distant page in next to the current one; normalized after settling.
            let neighbour = current + (target > current ? 1 : -1)
            jump = (id, neighbour)
            mount(id)
            placeSlots()
            settle(toDisplay: neighbour, committing: id, animated: true)
        } else {
            settle(toDisplay: target, committing: id, animated: animated)
        }
    }

    // MARK: HostedContainer

    /// Keeps the host for presentation sampling.
    ///
    /// Ownership: keeps `host` weakly. Isolation: MainActor. Errors: none. Cancellation: undone
    /// by `hostDidDetach()`.
    public func hostDidAttach(_ host: any ContainerHost) {
        self.host = host
    }

    /// Reads the committed page width; a new width re-places the pages at the selected page.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func hostDidCommit(_ commit: ContainerCommit) {
        if let width = calculatedFrame?.width, width != pageWidth {
            let first = pageWidth == 0
            pageWidth = width
            Log.on(
                .host,
                "pager-width",
                host: host?.hostID,
                node: id,
                "width=\(width) pages=\(tabs.count)"
            )
            if drag == nil {
                normalizeJump()
                position = Double(selectedIndex ?? 0)
            }
            if first { reconcileMounted(immediate: true) }
            placeSlots()
        }
        // The native offset follows the model once content sizes are committed.
        if drag == nil, !isSettling, let host, pageWidth > 0,
            host.presentedScrollOffset(of: scroll)?.x != targetOffset.x
        {
            applyPosition()
        }
    }

    /// Cancels a running pan and pending eviction.
    ///
    /// Ownership: releases host resources. Isolation: MainActor. Errors: none. Cancellation:
    /// this is the cancellation point.
    public func hostDidDetach() {
        if drag != nil {
            pan.reset()
        }
        settleGeneration &+= 1
        isSettling = false
        normalizeJump()
        reconcileMounted(immediate: true)
        host = nil
    }

    /// Disposes every mounted page and stops pending work.
    ///
    /// Ownership: releases pages. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public override func dispose() {
        guard !isDisposed else { return }

        settleGeneration &+= 1
        onSelectionChange = nil
        onProgressChange = nil
        observers.removeAll()
        super.dispose()
    }

    // MARK: Observers (TabsNode)

    func addObserver(_ observation: PagerObservation<ID>) {
        observers.removeAll { $0.owner == nil || $0.owner === observation.owner }
        observers.append(observation)
    }

    func index(of id: ID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    // MARK: Pan

    private var direction: Double {
        environment.layoutDirection == .rightToLeft ? -1 : 1
    }

    private var selectedIndex: Int? {
        selection.flatMap(index(of:))
    }

    private func panMayBegin() -> Bool {
        guard isSwipeEnabled, tabs.count > 1, pageWidth > 0, !isDisposed else { return false }

        // One owner (ADR 0029): a page already scrolling under the finger keeps the gesture.
        let busy = scrollNodes(in: slots.values.map(\.wrapper)).contains {
            $0.state.isUserDriven
        }
        return !busy
    }

    private func panned(_ state: GestureState, translation: Double, velocity: Double) {
        switch state {
        case .began:
            beginDrag()
            updateDrag(translation)
        case .changed:
            updateDrag(translation)
        case .ended:
            endDrag(translation: translation, velocity: velocity)
        case .cancelled:
            guard let drag else { return }

            finishDrag()
            let start = drag.start
            settle(toDisplay: start, committing: tabs[start].id, animated: true)
        default:
            break
        }
    }

    private func beginDrag() {
        settleGeneration &+= 1
        isSettling = false
        // Continue from what is on screen when grabbing a settling pager.
        if let presented = host?.presentedScrollOffset(of: scroll), pageWidth > 0 {
            position = self.position(forOffset: presented.x)
        }
        normalizeJump()
        let start = min(max(0, Int(position.rounded())), tabs.count - 1)
        drag = (position, start)
        for index in [start - 1, start, start + 1] where tabs.indices.contains(index) {
            mount(tabs[index].id)
        }
        placeSlots()
        frozenScrolls = scrollNodes(in: slots.values.map(\.wrapper)).filter {
            $0.configuration.userInteractionEnabled
        }
        for scroll in frozenScrolls {
            scroll.configuration.userInteractionEnabled = false
            // In effect now, not at the next commit: a drag tick does not commit (#93).
            host?.applyScrollConfiguration(of: scroll)
        }
        Log.on(
            .event,
            "pager-drag-begin",
            host: host?.hostID,
            node: id,
            "position=\(position) start=\(start)"
        )
    }

    private func updateDrag(_ translation: Double) {
        guard let drag, pageWidth > 0 else { return }

        let raw = drag.base - direction * translation / pageWidth
        let low = Double(max(0, drag.start - 1))
        let high = Double(min(tabs.count - 1, drag.start + 1))
        // Never more than one page per gesture and never past the first or last page.
        let next = min(high, max(low, raw))
        position = next
        applyPosition()
        let offset = next - Double(drag.start)
        let neighbour = drag.start + (offset < 0 ? -1 : 1)
        let to = tabs.indices.contains(neighbour) ? tabs[neighbour].id : tabs[drag.start].id
        publish(
            PagerProgress(from: tabs[drag.start].id, to: to, fraction: abs(offset), settled: nil),
            .none
        )
    }

    private func endDrag(translation: Double, velocity: Double) {
        guard let drag else { return }

        updateDrag(translation)
        finishDrag()
        let pageVelocity = pageWidth > 0 ? -direction * velocity / pageWidth : 0
        let offset = position - Double(drag.start)
        var target = drag.start
        if abs(pageVelocity) > 0.8 {
            target += pageVelocity > 0 ? 1 : -1
        } else if abs(offset) > 0.5 {
            target += offset > 0 ? 1 : -1
        }
        target = min(max(0, target), tabs.count - 1)
        settle(toDisplay: target, committing: tabs[target].id, animated: true)
    }

    private func finishDrag() {
        drag = nil
        for scroll in frozenScrolls where !scroll.isDisposed {
            scroll.configuration.userInteractionEnabled = true
            host?.applyScrollConfiguration(of: scroll)
        }
        frozenScrolls = []
    }

    // MARK: Settling

    private func settle(toDisplay displayIndex: Int, committing id: ID, animated: Bool) {
        let from = selection
        let animation =
            animated && !environment.reduceMotion && pageWidth > 0 ? settleAnimation : .none
        position = Double(displayIndex)
        // Commit first: the movement's completion can run synchronously and reads the selection.
        if selection != id {
            selection = id
            updateAccessibility()
            onSelectionChange?(id)
        }
        publish(PagerProgress(from: from, to: id, fraction: 1, settled: id), animation)
        settleGeneration &+= 1
        let generation = settleGeneration
        isSettling = animation.duration > .zero && host != nil
        applyPosition(animation: animation) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }

            self.isSettling = false
            self.normalizeJump()
            self.reconcileMounted(immediate: true)
        }
        Log.on(
            .event,
            "pager-settle",
            host: host?.hostID,
            node: self.id,
            "page=\(id) display=\(displayIndex) animated=\(animation.duration > .zero)"
        )
        if !isSettling {
            normalizeJump()
            reconcileMounted(immediate: true)
        }
    }

    /// Ends a distant-page slide: the page moves to its real index without visible change.
    private func normalizeJump() {
        guard jump != nil else { return }

        jump = nil
        position = Double(selectedIndex ?? 0)
        // The offset follows in `hostDidCommit`, once the page is laid out at its real index.
        placeSlots()
    }

    private func publish(_ next: PagerProgress<ID>, _ animation: Animation) {
        progress = next
        onProgressChange?(next, animation)
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.progressChanged(next, animation)
        }
    }

    // MARK: Mounting

    private func displayIndex(of id: ID) -> Int? {
        if let jump, jump.id == id { return jump.displayIndex }
        return index(of: id)
    }

    /// Mounts the selected page and its neighbours (only the selected page before the width is
    /// known) and evicts the rest.
    private func reconcileMounted(immediate: Bool) {
        var wanted: Set<ID> = []
        if let selected = selectedIndex {
            let range = pageWidth > 0 ? (selected - 1)...(selected + 1) : selected...selected
            for index in range where tabs.indices.contains(index) {
                wanted.insert(tabs[index].id)
            }
        }
        if let jump { wanted.insert(jump.id) }
        for id in Array(slots.keys) where !wanted.contains(id) {
            evict(id)
        }
        for id in tabs.map(\.id) where wanted.contains(id) {
            mount(id)
        }
        placeSlots()
        updateAccessibility()
    }

    private func mount(_ id: ID) {
        guard slots[id] == nil, let tab = tabs.first(where: { $0.id == id }) else { return }

        let content: Node
        let isEager: Bool
        if let eager = tab.eagerContent {
            eager.removeFromSupernode()
            content = eager
            isEager = true
        } else if let factory = tab.factory {
            content = factory()
            isEager = false
        } else {
            return
        }
        if content.style.height == .auto, content.style.flexGrow == 0 {
            content.style.flexGrow = 1
        }
        let wrapper = Node()
        wrapper.style {
            $0.positionType = .absolute
            $0.height = .fraction(1)
            $0.flexDirection = .column
        }
        wrapper.addSubnode(content)
        strip.addSubnode(wrapper)
        slots[id] = Slot(wrapper: wrapper, content: content, isEager: isEager)
        if let saved = states.removeValue(forKey: id) {
            let restorers = Self.restorers(in: content)
            for (restorer, state) in zip(restorers, saved) {
                restorer.restorePageState(state)
            }
        }
        Log.on(
            .host,
            "pager-mount",
            host: host?.hostID,
            node: self.id,
            "page=\(id) eager=\(isEager)"
        )
    }

    private func evict(_ id: ID) {
        guard let slot = slots.removeValue(forKey: id) else { return }

        let captured = Self.restorers(in: slot.content).compactMap { $0.capturePageState() }
        if !captured.isEmpty, tabs.contains(where: { $0.id == id }) {
            states[id] = captured
        }
        if slot.isEager {
            slot.content.removeFromSupernode()
        }
        slot.wrapper.removeFromSupernode()
        slot.wrapper.dispose()
        Log.on(
            .host,
            "pager-evict",
            host: host?.hostID,
            node: self.id,
            "page=\(id) states=\(captured.count)"
        )
    }

    private func placeSlots() {
        strip.style.width = .points(Double(tabs.count) * pageWidth)
        // The strip starts at the physical left edge in both directions: a right-to-left row
        // would place it at negative x, outside the scroll content, so the scroll row is
        // reversed there. Pages inside the strip still follow reading order.
        scroll.style.flexDirection = direction > 0 ? .row : .rowReverse
        for (id, slot) in slots {
            let index = Double(displayIndex(of: id) ?? 0)
            slot.wrapper.style.offsets = DirectionalEdgeOffsets(
                top: 0,
                leading: index * pageWidth
            )
            slot.wrapper.style.width = .points(pageWidth)
        }
    }

    /// Native offset that shows `position`.
    private var targetOffset: LayoutPoint {
        let pages = Double(max(0, tabs.count - 1))
        let logical = direction > 0 ? position : pages - position
        return LayoutPoint(x: logical * pageWidth, y: 0)
    }

    private func position(forOffset x: Double) -> Double {
        guard pageWidth > 0 else { return position }

        let logical = x / pageWidth
        return direction > 0 ? logical : Double(max(0, tabs.count - 1)) - logical
    }

    /// Moves the native offset to `position`, with `animation` when given; `done` runs once
    /// the movement ended (at once without a host or animation).
    private func applyPosition(
        animation: Animation = .none,
        done: (@MainActor () -> Void)? = nil
    ) {
        guard let host, pageWidth > 0 else {
            done?()
            return
        }

        let command: ScrollCommand =
            animation.duration > .zero
            ? .timed(targetOffset, animation: animation) : .to(targetOffset, animated: false)
        host.scrollContainer(scroll, command) { _ in done?() }
    }

    /// Only the selected page is exposed to accessibility; neighbours are off screen.
    private func updateAccessibility() {
        for (id, slot) in slots {
            slot.wrapper.accessibility.childrenPolicy = id == selection ? .contain : .hide
        }
    }

    // MARK: Tabs changes

    private func tabsDidChange(from old: [Tab<ID>]) {
        let unique = Self.unique(tabs)
        if unique.count != tabs.count {
            Log.on(
                .host,
                "pager-duplicate-tabs",
                host: host?.hostID,
                node: id,
                "dropped=\(tabs.count - unique.count)"
            )
            // Reassigning inside didSet does not re-enter it; continue with the unique list.
            tabs = unique
        }
        if drag != nil {
            pan.reset()
        }
        settleGeneration &+= 1
        isSettling = false
        jump = nil
        let ids = Set(tabs.map(\.id))
        for id in Array(slots.keys) where !ids.contains(id) {
            evict(id)
        }
        states = states.filter { ids.contains($0.key) }
        // A tab whose eager node changed gets the new node.
        for tab in tabs {
            if let slot = slots[tab.id], let eager = tab.eagerContent, eager !== slot.content {
                evict(tab.id)
            }
        }

        let previous = selection
        if let current = selection, ids.contains(current) {
            // Kept by ID.
        } else if let current = selection,
            let oldIndex = old.firstIndex(where: { $0.id == current }),
            !tabs.isEmpty
        {
            selection = tabs[min(oldIndex, tabs.count - 1)].id
        } else {
            selection = tabs.first?.id
        }
        position = Double(selectedIndex ?? 0)
        reconcileMounted(immediate: true)
        for observer in observers where observer.owner != nil {
            observer.tabsChanged()
        }
        publish(
            PagerProgress(from: selection, to: selection, fraction: 0, settled: selection),
            .none
        )
        if selection != previous, let selection {
            onSelectionChange?(selection)
        }
    }

    // MARK: Helpers

    private func scrollNodes(in roots: [Node]) -> [ScrollNode] {
        var found: [ScrollNode] = []
        func visit(_ node: Node) {
            if let scroll = node as? ScrollNode { found.append(scroll) }
            node.subnodes.forEach(visit)
        }
        roots.forEach(visit)
        return found
    }

    private static func restorers(in root: Node) -> [any PageStateRestoring] {
        var found: [any PageStateRestoring] = []
        func visit(_ node: Node) {
            if let restorer = node as? any PageStateRestoring { found.append(restorer) }
            node.subnodes.forEach(visit)
        }
        visit(root)
        return found
    }

    private static func unique(_ tabs: [Tab<ID>]) -> [Tab<ID>] {
        var seen: Set<ID> = []
        return tabs.filter { seen.insert($0.id).inserted }
    }
}
