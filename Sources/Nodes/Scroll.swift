import LayoutCore
import StateCore

/// A node that shows a vertical scroll's pull to refresh: the scroll places it over the
/// top of its content, where the pull opens room, and tells it how far the pull goes.
///
/// Ownership: the scroll keeps its indicator. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
public protocol RefreshIndicator: AnyObject {
    /// Shows how far the scroll is pulled toward a refresh — 0 not at all, 1 far enough
    /// that letting go refreshes — and whether it refreshes now.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @MainActor
    func showRefresh(pull: Double, isRefreshing: Bool)
}

/// Where in a scroll's window a scroll to an item puts it, along the scroll's axis.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ScrollAlignment: Sendable, Hashable {
    /// At the window's start — its top, or its leading edge — after the nodes sticking there.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case start
    /// Halfway between the window's start, after the nodes sticking there, and its end.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case center
    /// At the window's end — its bottom, or its trailing edge.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case end
}

/// What a drag of a scroll does to the platform's keyboard.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum KeyboardDismissal: Sendable, Hashable {
    /// Nothing: the keyboard stays.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case none
    /// The keyboard goes away as the drag begins.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case onDrag
    /// The keyboard follows the finger down, and goes away when the finger takes it off the
    /// screen; drawn back up, it stays.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case interactive
}

/// The direction a `Scroll` moves its content in.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ScrollAxis: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case vertical
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case horizontal
}

/// A window onto content longer than itself: `content` is laid out at its full length along
/// `axis`, and the part at `contentOffset` shows. The platform adapter moves the offset with
/// its own physics — a finger, a trackpad, the scroll wheel — and focus moving to a node
/// inside scrolls it into view.
///
///     let feed = Scroll(.vertical, content: FeedList())
///
///     override func layoutSpec() -> LayoutSpec? {
///         FlexContainer(.column) {
///             header
///             feed
///         }
///     }
///
/// A scroll takes the room its parent has, not its content's length. Short of room it
/// shrinks before the nodes beside it, down to nothing along `axis` (as a CSS scroll
/// container may), so a header above a list keeps its size and the list gets the rest. A
/// vertical scroll also grows into free room (`flex(grow: 1)`), so the list fills the screen.
/// A horizontal scroll — usually a row of cards in a column — is stretched across by the
/// column and is as tall as its content. A size or flex set where the scroll is placed
/// overrides all that. Where the parent sizes itself to its content, a scroll takes its
/// content's length and shows it all.
/// Across `axis` the content is stretched to the scroll's width (or height), and along it the
/// content takes at least the whole window.
///
/// Ownership: the scroll owns `content` while it is mounted, as a node owns its subnodes.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public final class Scroll: Node {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let axis: ScrollAxis

    /// The node scrolled.
    ///
    /// Ownership: the scroll keeps the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var content: Node? {
        didSet { if content !== oldValue { setNeedsLayout() } }
    }

    /// Called whenever `contentOffset` changes, by the user or by code.
    ///
    /// Ownership: the scroll keeps the closure; it must not keep the scroll. Isolation:
    /// MainActor. Errors: none. Cancellation: set to `nil`.
    public var onScroll: (@MainActor (LayoutPoint) -> Void)?

    /// The offset asked for last; what shows is it kept within `offsetRange`.
    private let requestedOffset = State(LayoutPoint.zero)

    /// How far past the end of the content the platform's physics has pulled it — while it
    /// bounces back, on iOS. Not part of `contentOffset`: nothing is laid out for it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var overscroll = LayoutPoint.zero

    // MARK: - Pull to refresh

    /// What a pull to refresh does: set, pulling a vertical scroll down past its top by
    /// `refreshDistance` and letting go calls it, and the scroll holds `refreshSpace` open
    /// over its content, where `refreshIndicator` shows, until it returns. `nil`, the
    /// default, pulls with no refresh.
    ///
    /// Ownership: the scroll keeps the closure; it must not keep the scroll. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable; the scroll does not cancel it.
    public var onRefresh: (@MainActor () async -> Void)? {
        didSet { setNeedsLayout() }
    }

    /// The node over the top of the content that shows the pull and the refresh; it is told
    /// how far the pull goes if it is a `RefreshIndicator`. `refreshSpace` high, across the
    /// scroll's width.
    ///
    /// Ownership: the scroll keeps the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var refreshIndicator: Node? {
        didSet { if refreshIndicator !== oldValue { setNeedsLayout() } }
    }

    /// Whether a refresh goes on: the room over the content stays open.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isRefreshing = false

    /// Points the pull must reach past the top, at any time while held, for letting go to
    /// refresh — as far as the room it opens.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let refreshDistance = 56.0

    /// The pull held now reached `refreshDistance`: letting go refreshes, even if it eased
    /// off since — as with the system's refresh control.
    private var pullReachedRefresh = false

    /// Points of room over the content while it refreshes.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let refreshSpace = 56.0

    /// Whether the scroll refreshes when pulled: vertical, with `onRefresh`.
    private var refreshes: Bool { axis == .vertical && onRefresh != nil }

    /// Starts a refresh, as a pull let go does: the scroll opens the room over its content,
    /// with the animation of `withAnimation` or a short spring, and closes it when
    /// `onRefresh` returns. Nothing happens while one goes on or without `onRefresh`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func beginRefresh() {
        guard refreshes, !isRefreshing, let onRefresh else { return }

        isRefreshing = true
        showRefresh()
        withAnimation(Animation.current ?? Scroll.refreshMove) {
            // At the top, the room shows; further down, the content stays where it is.
            if contentOffset.y <= offsetRange.lowest.y + Scroll.refreshSpace {
                place(at: offsetRange.lowest)
            }
            host?.setNeedsRender()
        }
        Task { @MainActor [weak self] in
            await onRefresh()
            self?.endRefresh()
        }
    }

    /// For platform adapters: the finger or the fingers let the scroll go. Returns whether
    /// that starts a refresh — the pull reached `refreshDistance` — so that the platform's
    /// scrolling comes to rest at `contentOffset`, with the room open, rather than at the top.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func platformDidRelease() -> Bool {
        let reached = pullReachedRefresh
        pullReachedRefresh = false
        guard refreshes, !isRefreshing, reached else { return false }

        beginRefresh()
        return true
    }

    private func endRefresh() {
        guard isRefreshing else { return }

        withAnimation(Scroll.refreshMove) {
            isRefreshing = false
            requestedOffset.value = offsetRange.clamp(requestedOffset.value)
            host?.setNeedsRender()
            host?.viewportMoved()
        }
        onScroll?(contentOffset)
        showRefresh()
    }

    /// How the room over the content opens and closes.
    private static let refreshMove = Animation.spring(response: 0.35, dampingRatio: 1)

    /// Tells the indicator how far the pull goes.
    private func showRefresh() {
        guard refreshes, let indicator = refreshIndicator as? any RefreshIndicator else { return }

        let pull = isRefreshing ? 1 : min(max(-overscroll.y / Scroll.refreshDistance, 0), 1)
        indicator.showRefresh(pull: pull, isRefreshing: isRefreshing)
    }

    /// A scroll of `content` along `axis`.
    ///
    /// Ownership: keeps `content`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ axis: ScrollAxis = .vertical, content: Node? = nil) {
        self.axis = axis
        self.content = content
        super.init()
        appearance.clipsContent = true
    }

    /// An animated move of the offset made frame by frame, while it goes on.
    private var move: OffsetMove?

    /// The point of the content at the scroll's top left corner, in the scroll's
    /// coordinates, where the content's frame is. Reading it in `layoutSpec()` or `update()`
    /// is a dependency, like a state's value. Setting it scrolls there at once, or with the
    /// animation of `withAnimation`; a value past the content's ends shows its end.
    ///
    /// Content laid out by where it shows (a `LazyStack`) has only the part near the window
    /// laid out. An animated move longer than that part goes frame by frame instead, so
    /// that the content is laid out all along the way: the offset reads where the move is,
    /// and gets where it was set when the animation ends. A move of the scroll by the
    /// platform, or a set without animation, stops it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var contentOffset: LayoutPoint {
        get { offsetRange.clamp(requestedOffset.value) }
        set {
            var following: (@MainActor () -> LayoutPoint?)?
            if isMounted, offsetRange.clamp(newValue) == offsetRange.highest {
                // The content's length changes as its parts get laid out on the way.
                following = { [weak self] in self?.offsetRange.highest }
            }
            scroll(to: newValue, following: following)
        }
    }

    /// Sets the offset to `newValue`, as `contentOffset` does. A move made frame by frame
    /// asks `following` on every frame where its end is now — content on the way may turn
    /// out longer or shorter than it was thought — and ends once a frame finds the offset
    /// there.
    func scroll(to newValue: LayoutPoint, following: (@MainActor () -> LayoutPoint?)?) {
        if let animation = Animation.current, let host, isMounted,
            host.movesFrameByFrame(self, by: offsetRange.clamp(newValue) - contentOffset)
        {
            move = OffsetMove(
                from: contentOffset,
                to: offsetRange.clamp(newValue),
                following: following,
                animation: animation
            )
            host.startFrames(for: self)
            return
        }
        move = nil
        place(at: newValue)
    }

    /// Where the offset goes: the end of the move under way, or where it is.
    var targetOffset: LayoutPoint { move?.to ?? contentOffset }

    /// Whether an animated move goes on frame by frame.
    var isMoving: Bool { move != nil }

    /// Moves the offset to where the move under way is at `time`, in seconds of the
    /// display's clock; returns whether it goes on after.
    func advanceMove(to time: Double) -> Bool {
        guard var move else { return false }

        let start = move.start ?? time
        move.start = start
        if let now = move.following?() {
            move.to = offsetRange.clamp(now)
        }
        guard time - start < move.animation.duration else {
            // The layout of the frame that got to the end lays out the content there, which
            // may be longer or shorter than was thought: a move that follows its end ends
            // once a frame finds the offset still there — or after a few frames, should the
            // content never settle.
            move.framesPast += 1
            let settled =
                move.following == nil || contentOffset == move.to
                || move.framesPast > OffsetMove.settlingFrames
            self.move = settled ? nil : move
            place(at: move.to)
            return !settled
        }

        let progress = move.animation.progress(at: time - start)
        move.progress = progress
        self.move = move
        place(
            at: LayoutPoint(
                x: move.from.x + (move.to.x - move.from.x) * progress,
                y: move.from.y + (move.to.y - move.from.y) * progress
            )
        )
        return true
    }

    /// Stops the move under way where it is.
    func stopMove() {
        move = nil
    }

    private func place(at newValue: LayoutPoint) {
        let shown = contentOffset
        // Before its first layout the scroll has no content to keep the offset within: the
        // offset asked for waits for it.
        let requested = isMounted ? offsetRange.clamp(newValue) : newValue
        guard requested != requestedOffset.value else { return }

        overscroll = .zero
        requestedOffset.value = requested
        let now = contentOffset
        guard now != shown else { return }

        host?.setNeedsScrollRender(self)
        host?.viewportMoved()
        onScroll?(now)
    }

    /// Moves the offset by `delta`, keeping any overscroll: the content before what shows
    /// got longer or shorter, and what shows stays where it is on screen. A move under way
    /// goes on from there: where it ends shifts too when `movesTarget` — the content changed
    /// lies between the start and it — and otherwise stays.
    func shiftOffset(by delta: LayoutPoint, movesTarget: Bool = true) {
        if var move {
            if movesTarget {
                move.from = move.from + delta
                move.to = move.to + delta
            } else {
                // The start moves so that the way from it to the end passes where the offset
                // is now, at the progress the move is at.
                let rest = 1 - move.progress
                let scale = abs(rest) > 0.01 ? 1 / rest : 1
                move.from = LayoutPoint(
                    x: move.from.x + delta.x * scale,
                    y: move.from.y + delta.y * scale
                )
            }
            self.move = move
        }
        let shown = contentOffset
        requestedOffset.value = offsetRange.clamp(
            LayoutPoint(x: shown.x + delta.x, y: shown.y + delta.y)
        )
        let now = contentOffset
        guard now != shown else { return }

        host?.setNeedsScrollRender(self)
        host?.viewportMoved()
        onScroll?(now)
    }

    /// What the window shows: `contentOffset` with `overscroll`.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var shownOffset: LayoutPoint {
        let offset = contentOffset
        return LayoutPoint(x: offset.x + overscroll.x, y: offset.y + overscroll.y)
    }

    /// For platform adapters: the platform's scrolling moved the content to `offset`, which
    /// may be past the ends while it bounces. The part within them becomes `contentOffset`,
    /// the rest `overscroll`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func platformDidScroll(to offset: LayoutPoint) {
        let within = offsetRange.clamp(offset)
        let past = LayoutPoint(x: offset.x - within.x, y: offset.y - within.y)
        let movedPast = past != overscroll
        move = nil
        place(at: within)
        overscroll = past
        if movedPast {
            host?.setNeedsScrollRender(self)
            if -past.y >= Scroll.refreshDistance {
                pullReachedRefresh = true
            }
            showRefresh()
        }
    }

    /// Where the content is, in the scroll's coordinates: the frame of `content` from the
    /// last layout, covering at least the scroll's own box.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var contentBounds: LayoutRect {
        var minX = 0.0
        var minY = 0.0
        var maxX = frame.size.width
        var maxY = frame.size.height
        // Zoomed, the content is drawn that many times bigger from its origin.
        let scale = zoomScale
        for subnode in subnodes where !subnode.isHidden && subnode !== refreshIndicator {
            minX = min(minX, subnode.frame.origin.x * scale)
            minY = min(minY, subnode.frame.origin.y * scale)
            maxX = max(maxX, (subnode.frame.origin.x + subnode.frame.size.width) * scale)
            maxY = max(maxY, (subnode.frame.origin.y + subnode.frame.size.height) * scale)
        }
        return LayoutRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The offsets that keep the window within the content: from the content's top left
    /// corner to where its end meets the window's. Across `axis` there is only one.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var offsetRange: ScrollRange {
        let content = contentBounds
        let lowest = LayoutPoint(x: content.origin.x, y: content.origin.y)
        let highest = LayoutPoint(
            x: content.origin.x + content.size.width - frame.size.width,
            y: content.origin.y + content.size.height - frame.size.height
        )
        // Zoomable content moves both ways.
        if isZoomable {
            let room = axis == .vertical && isRefreshing ? Scroll.refreshSpace : 0
            return ScrollRange(
                lowest: LayoutPoint(x: lowest.x, y: lowest.y - room),
                highest: LayoutPoint(x: max(lowest.x, highest.x), y: max(lowest.y, highest.y))
            )
        }
        switch axis {
        case .vertical:
            // While it refreshes, the room over the content is in reach.
            let room = isRefreshing ? Scroll.refreshSpace : 0
            return ScrollRange(
                lowest: LayoutPoint(x: 0, y: lowest.y - room),
                highest: LayoutPoint(x: 0, y: highest.y)
            )
        case .horizontal:
            return ScrollRange(
                lowest: LayoutPoint(x: lowest.x, y: 0),
                highest: LayoutPoint(x: highest.x, y: 0)
            )
        }
    }

    /// Whether the content is longer than the window, so there is anywhere to scroll.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var canScroll: Bool {
        let range = offsetRange
        return range.highest.x > range.lowest.x || range.highest.y > range.lowest.y
    }

    /// Scrolls as little as it takes to show `rect`, given in the scroll's coordinates as
    /// laid out (not moved by the offset); a rect longer than the window shows its start.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func scrollToReveal(_ rect: LayoutRect) {
        var offset = contentOffset
        switch axis {
        case .vertical:
            offset.y = Scroll.reveal(
                rect.origin.y,
                rect.size.height,
                from: offset.y,
                window: frame.size.height
            )
        case .horizontal:
            offset.x = Scroll.reveal(
                rect.origin.x,
                rect.size.width,
                from: offset.x,
                window: frame.size.width
            )
        }
        contentOffset = offset
    }

    /// Scrolls as little as it takes to show `node`, which must be inside the scroll.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func scrollToReveal(_ node: Node) {
        guard let rect = frame(of: node) else { return }

        scrollToReveal(rect)
    }

    /// The frame of `node` in the scroll's coordinates, as laid out (not moved by the
    /// offset); `nil` when it is not inside. Scrolls in between count at their offsets.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func frame(of node: Node) -> LayoutRect? {
        placement(of: node)?.rect(LayoutRect(origin: .zero, size: node.frame.size))
    }

    /// Where the box of `node` is in the scroll's coordinates, as laid out, and how many
    /// times bigger it is drawn there: the zoom, when it is in the content.
    func placement(of node: Node) -> Placement? {
        guard var placement = node.placement(in: self, shown: false) else { return nil }

        // That took this scroll's own offset out too: frames here are as laid out.
        placement.origin.x += contentOrigin.x
        placement.origin.y += contentOrigin.y
        return placement
    }

    /// How far into the window from where it starts along `axis` — its top, or its leading
    /// edge — nodes sticking there cover it, were the offset `offset`: what goes to the
    /// window's start goes this much after it, to show.
    func stuckLength(at offset: LayoutPoint) -> Double {
        var covered = 0.0
        var pending = subnodes
        while let node = pending.popLast() {
            guard !node.isHidden else { continue }

            if !(node is Scroll) {
                pending.append(contentsOf: node.subnodes)
            }
            guard let sticky = node.sticky, let placement = placement(of: node) else { continue }

            let rect = placement.rect(LayoutRect(origin: .zero, size: node.frame.size))
            // The offset and the insets are as laid out: drawn, they are zoomed too.
            let scale = placement.scale
            let shift = node.stickyOffset(showing: offset)
            switch axis {
            case .vertical:
                guard let top = sticky.top else { continue }

                let start = rect.origin.y + shift.y * scale
                let end = start + rect.size.height
                if start <= offset.y + top * scale, end > offset.y {
                    covered = max(covered, end - offset.y)
                }
            case .horizontal where host?.direction == .rightToLeft:
                guard let right = sticky.right else { continue }

                let windowEnd = offset.x + frame.size.width
                let start = rect.origin.x + shift.x * scale
                if start + rect.size.width >= windowEnd - right * scale, start < windowEnd {
                    covered = max(covered, windowEnd - start)
                }
            case .horizontal:
                guard let left = sticky.left else { continue }

                let start = rect.origin.x + shift.x * scale
                let end = start + rect.size.width
                if start <= offset.x + left * scale, end > offset.x {
                    covered = max(covered, end - offset.x)
                }
            }
        }
        return covered
    }

    // MARK: - Zoom

    /// The scales the content can be zoomed to, pinching it or with `zoom(to:around:)`: at
    /// 2 it is drawn twice as big from its top left corner, and the scroll moves across it
    /// both ways. The default, 1…1, does not zoom. The content keeps its layout; taps,
    /// focus and accessibility follow what is drawn.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var zoomRange: ClosedRange<Double> = 1...1 {
        didSet {
            guard zoomRange != oldValue else { return }

            let scale = min(max(zoomScale, zoomRange.lowerBound), zoomRange.upperBound)
            if scale != zoomScale {
                zoom(to: scale)
            }
            host?.setNeedsRender()
        }
    }

    /// How many times bigger than laid out the content is drawn.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var zoomScale = 1.0

    /// Whether the content can be zoomed: `zoomRange` is more than one scale.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isZoomable: Bool { zoomRange.lowerBound < zoomRange.upperBound }

    /// Zooms the content to `scale`, kept within `zoomRange`, keeping the point of it at
    /// `point` — in the scroll's box, the window's center by default — where it is. At once,
    /// or with the animation of `withAnimation`.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func zoom(to scale: Double, around point: LayoutPoint? = nil) {
        let scale = min(max(scale, zoomRange.lowerBound), zoomRange.upperBound)
        let anchor =
            point ?? LayoutPoint(x: frame.size.width / 2, y: frame.size.height / 2)
        let shown = shownOffset
        // The point of the content under the anchor, as laid out.
        let content = LayoutPoint(
            x: (anchor.x + shown.x) / zoomScale,
            y: (anchor.y + shown.y) / zoomScale
        )
        setZoom(
            scale,
            offset: LayoutPoint(x: content.x * scale - anchor.x, y: content.y * scale - anchor.y)
        )
    }

    /// For platform adapters: the platform's pinch zoomed the content to `scale`, with the
    /// offset at `offset` — which, as `platformDidScroll(to:)` takes it, may be past the
    /// ends while it bounces.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func platformDidZoom(to scale: Double, offset: LayoutPoint) {
        guard scale != zoomScale else {
            platformDidScroll(to: offset)
            return
        }

        zoomScale = scale
        requestedOffset.value = offset
        platformDidScroll(to: offset)
        host?.setNeedsRender()
        host?.viewportMoved()
    }

    private func setZoom(_ scale: Double, offset: LayoutPoint) {
        guard scale != zoomScale else {
            contentOffset = offset
            return
        }

        move = nil
        zoomScale = scale
        overscroll = .zero
        requestedOffset.value = offsetRange.clamp(offset)
        host?.setNeedsRender()
        host?.viewportMoved()
        onScroll?(contentOffset)
    }

    override var contentScale: Double { zoomScale }

    // MARK: - Paging

    /// Whether the scroll comes to rest only where a page starts: a page is the window's
    /// length along `axis`, counted from the content's start — its leading edge in a row laid
    /// out from the right — and the last one ends at the content's end. A swipe goes one page
    /// at most, as a pager does; a slow drag goes to the page nearest where it is let go.
    /// Code still sets any offset.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isPaging = false {
        didSet { if isPaging != oldValue { host?.setNeedsRender() } }
    }

    /// What a drag of the scroll does to the platform's keyboard. A list under a field that
    /// sends — a chat — lets the keyboard follow the finger down.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var keyboardDismissal = KeyboardDismissal.none {
        didSet { if keyboardDismissal != oldValue { host?.setNeedsRender() } }
    }

    /// The page that shows, from 0: the one whose start is nearest the offset.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var page: Int {
        let length = pageLength
        guard length > 0 else { return 0 }

        return min(
            max(0, Int((distanceFromStart(of: contentOffset) / length).rounded())),
            pageCount - 1
        )
    }

    /// How many pages the content takes: the last one may be shorter than the window.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var pageCount: Int {
        let length = pageLength
        guard length > 0 else { return 1 }

        let travel = along(offsetRange.highest) - along(offsetRange.lowest)
        return Int((travel / length - 0.001).rounded(.up)) + 1
    }

    /// Scrolls to where page `page` starts — at once, or with the animation of
    /// `withAnimation` — the last page ending at the content's end.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: another move of
    /// the scroll, or the platform moving it, stops the move.
    public func scroll(toPage page: Int) {
        contentOffset = offset(ofPage: page)
    }

    /// For platform adapters: where a drag that started at `start` and is let go at
    /// `current`, moving at `velocity` points a second, comes to rest when the scroll pages.
    /// A swipe goes one page on from the page it started on, in its direction; a slow drag
    /// goes to the page nearest where it is let go, but not beyond the next.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func pagingTarget(
        from start: LayoutPoint,
        at current: LayoutPoint,
        velocity: LayoutPoint
    ) -> LayoutPoint {
        let length = pageLength
        guard length > 0 else { return offsetRange.clamp(current) }

        let first = (distanceFromStart(of: start) / length).rounded()
        let now = distanceFromStart(of: current) / length
        // Toward the content's end is forward, whichever way the offset goes for it.
        let speed = along(velocity) * (startsAtHighest ? -1 : 1)
        var target: Double
        if abs(speed) > Scroll.swipeSpeed {
            target = speed > 0 ? now.rounded(.up) : now.rounded(.down)
        } else {
            target = now.rounded()
        }
        target = min(max(target, first - 1), first + 1)
        return offset(ofPage: Int(target))
    }

    /// Points a second a finger must move for its lift to go on to the next page.
    private static let swipeSpeed = 300.0

    private var pageLength: Double {
        axis == .vertical ? frame.size.height : frame.size.width
    }

    /// A row laid out from the right starts at its right: at the highest offset.
    private var startsAtHighest: Bool {
        axis == .horizontal && host?.direction == .rightToLeft
    }

    private func along(_ point: LayoutPoint) -> Double {
        axis == .vertical ? point.y : point.x
    }

    /// How far `offset` is from the content's start, along `axis`.
    private func distanceFromStart(of offset: LayoutPoint) -> Double {
        let range = offsetRange
        return startsAtHighest
            ? along(range.highest) - along(offset) : along(offset) - along(range.lowest)
    }

    /// The offset where page `page` starts, kept within the content.
    private func offset(ofPage page: Int) -> LayoutPoint {
        let range = offsetRange
        let distance = Double(max(0, page)) * pageLength
        let value =
            startsAtHighest ? along(range.highest) - distance : along(range.lowest) + distance
        var offset = contentOffset
        switch axis {
        case .vertical: offset.y = value
        case .horizontal: offset.x = value
        }
        return range.clamp(offset)
    }

    /// Scrolls by one window toward the content's end, or its start, and returns the page
    /// shown then — `nil`, not moving, when already at that end.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func scrollPage(forward: Bool) -> ScrollPage? {
        let vertical = axis == .vertical
        let window = vertical ? frame.size.height : frame.size.width
        guard window > 0 else { return nil }

        let before = contentOffset
        var offset = before
        let step = forward ? window : -window
        if vertical {
            offset.y += step
        } else {
            offset.x += step
        }
        contentOffset = offset
        // An animated move may still be on its way there.
        let after = targetOffset
        guard after != before else { return nil }

        let range = offsetRange
        let done = vertical ? after.y - range.lowest.y : after.x - range.lowest.x
        let travel = vertical ? range.highest.y - range.lowest.y : range.highest.x - range.lowest.x
        let count = Int((travel / window).rounded(.up)) + 1
        // The last page is the one at the end, however little of a window it adds.
        let number = done >= travel ? count : Int((done / window).rounded(.down)) + 1
        return ScrollPage(number: number, count: count)
    }

    /// Where the start of a span of `length` at `start` must be for it to show in a window
    /// of `window` now at `offset`, moving as little as possible.
    private static func reveal(
        _ start: Double,
        _ length: Double,
        from offset: Double,
        window: Double
    ) -> Double {
        if start < offset || length > window { return start }
        if start + length > offset + window { return start + length - window }
        return offset
    }

    override var contentOrigin: LayoutPoint { shownOffset }

    /// A shrink factor that leaves the neighbors' share of a shortage below a pixel.
    private static let shrinkFirst = 1_000_000.0

    /// Ownership: returns a value borrowing `content`. Isolation: MainActor. Errors: none.
    /// Cancellation: none.
    public override func layoutSpec() -> LayoutSpec? {
        // Along the axis the content keeps its whole length (it does not shrink) and fills
        // at least the window (it grows); across it, it stretches to the window's width.
        let spec = FlexContainer(axis == .vertical ? .column : .row) {
            if let content {
                content.flex(grow: 1, shrink: 0)
            }
            if refreshes, let refreshIndicator {
                // Over the content's top, in the room a pull opens.
                refreshIndicator
                    .absolute(top: -Scroll.refreshSpace, leading: 0, trailing: 0)
                    .height(.points(Scroll.refreshSpace))
            }
        }
        // The scroll's base size stays its content's, so a size set where it is placed works
        // as for any node. Short of room it shrinks before the nodes beside it — they shrink
        // in proportion to their shrink factors, and its is far larger — down to nothing, as
        // a CSS scroll container may. A shrink factor rather than a zero flex basis: a zero
        // basis would override a height set by the parent, as CSS says it does.
        switch axis {
        case .vertical:
            // Takes the free room too: a list under a header fills the screen.
            return spec.flex(grow: 1, shrink: Scroll.shrinkFirst).limits(minHeight: .points(0))
        case .horizontal:
            // Usually a row of cards in a column: the column stretches it across, and its
            // height is its content's.
            return spec.flex(shrink: Scroll.shrinkFirst).limits(minWidth: .points(0))
        }
    }
}

/// The offsets a scroll can take, from `lowest` to `highest` on each axis.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ScrollRange: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var lowest: LayoutPoint
    /// Never below `lowest`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var highest: LayoutPoint

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(lowest: LayoutPoint, highest: LayoutPoint) {
        self.lowest = lowest
        self.highest = LayoutPoint(x: max(lowest.x, highest.x), y: max(lowest.y, highest.y))
    }

    /// `point` moved into the range.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func clamp(_ point: LayoutPoint) -> LayoutPoint {
        LayoutPoint(
            x: min(max(point.x, lowest.x), highest.x),
            y: min(max(point.y, lowest.y), highest.y)
        )
    }
}

/// One window of a scroll's content, counted from the start: what VoiceOver says after a
/// three-finger swipe.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ScrollPage: Sendable, Hashable {
    /// From 1.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let number: Int
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let count: Int

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(number: Int, count: Int) {
        self.number = number
        self.count = count
    }
}

/// An animated move of a scroll's offset, made frame by frame.
private struct OffsetMove {
    var from: LayoutPoint
    var to: LayoutPoint
    /// Where the end is now, asked on every frame; `nil` keeps `to`.
    let following: (@MainActor () -> LayoutPoint?)?
    let animation: Animation
    /// When the first frame of the move was drawn.
    var start: Double?
    /// How far along the way the last frame was, from 0 to 1.
    var progress = 0.0
    /// Frames after the animation's time that did not find the offset at the end.
    var framesPast = 0

    /// Frames a move that follows its end goes on past its time at most.
    static let settlingFrames = 8
}

extension LayoutPoint {
    fileprivate static func + (lhs: LayoutPoint, rhs: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    fileprivate static func - (lhs: LayoutPoint, rhs: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }
}
