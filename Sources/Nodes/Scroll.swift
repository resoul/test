import LayoutCore
import StateCore

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
        for subnode in subnodes where !subnode.isHidden {
            minX = min(minX, subnode.frame.origin.x)
            minY = min(minY, subnode.frame.origin.y)
            maxX = max(maxX, subnode.frame.origin.x + subnode.frame.size.width)
            maxY = max(maxY, subnode.frame.origin.y + subnode.frame.size.height)
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
        switch axis {
        case .vertical:
            return ScrollRange(
                lowest: LayoutPoint(x: 0, y: lowest.y),
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
        var origin = LayoutPoint.zero
        var current = node
        while current !== self {
            guard let supernode = current.supernode else { return nil }

            origin.x += current.frame.origin.x - supernode.contentOrigin.x
            origin.y += current.frame.origin.y - supernode.contentOrigin.y
            current = supernode
        }
        // The loop took this scroll's own offset out too: frames here are as laid out.
        origin.x += contentOrigin.x
        origin.y += contentOrigin.y
        return LayoutRect(
            x: origin.x,
            y: origin.y,
            width: node.frame.size.width,
            height: node.frame.size.height
        )
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
            guard let sticky = node.sticky, let rect = frame(of: node) else { continue }

            let shift = node.stickyOffset(showing: offset)
            switch axis {
            case .vertical:
                guard let top = sticky.top else { continue }

                let start = rect.origin.y + shift.y
                let end = start + rect.size.height
                if start <= offset.y + top, end > offset.y {
                    covered = max(covered, end - offset.y)
                }
            case .horizontal where host?.direction == .rightToLeft:
                guard let right = sticky.right else { continue }

                let windowEnd = offset.x + frame.size.width
                let start = rect.origin.x + shift.x
                if start + rect.size.width >= windowEnd - right, start < windowEnd {
                    covered = max(covered, windowEnd - start)
                }
            case .horizontal:
                guard let left = sticky.left else { continue }

                let start = rect.origin.x + shift.x
                let end = start + rect.size.width
                if start <= offset.x + left, end > offset.x {
                    covered = max(covered, end - offset.x)
                }
            }
        }
        return covered
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
