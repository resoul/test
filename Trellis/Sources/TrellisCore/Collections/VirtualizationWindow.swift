import Foundation

/// Positions of a run of items along the scrolled axis, built from measured lengths where
/// known and an estimate otherwise (R10, ADR 0030). Prefix sums make offset and hit lookups
/// O(log N); building is O(N) over plain doubles, never over nodes.
///
/// Anchor restoration (R11) reads the same offsets, so a measured length before the anchor
/// is always counted by its measured value — Weave defect #64 used the estimate there.
///
/// Ownership: a value. Isolation: none — built on any executor. Errors: none; negative or
/// non-finite lengths are treated as zero. Cancellation: not applicable.
public struct ItemExtentIndex: Sendable, Equatable {
    /// Leading offset of each item, plus one trailing entry equal to `totalExtent`.
    private let starts: [Double]

    /// Gap between consecutive items.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let spacing: Double

    /// Creates an index from resolved per-item lengths.
    ///
    /// Ownership: copies `lengths`. Isolation: none. Errors: none — invalid lengths count as
    /// zero. Cancellation: not applicable.
    public init(lengths: [Double], spacing: Double = 0) {
        let gap = spacing.isFinite ? max(0, spacing) : 0
        var starts: [Double] = []
        starts.reserveCapacity(lengths.count + 1)
        var cursor = 0.0
        for (index, length) in lengths.enumerated() {
            starts.append(cursor)
            cursor += length.isFinite ? max(0, length) : 0
            if index < lengths.count - 1 {
                cursor += gap
            }
        }
        starts.append(cursor)
        self.starts = starts
        self.spacing = gap
    }

    /// Number of items.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var count: Int { starts.count - 1 }

    /// Length of the whole run, spacing included.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var totalExtent: Double { starts[starts.count - 1] }

    /// Leading offset of the item at `index`; `totalExtent` for `index == count`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none; the index is clamped.
    /// Cancellation: not applicable.
    public func offset(of index: Int) -> Double {
        starts[min(max(0, index), count)]
    }

    /// Length of the item at `index`, without spacing.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none; out of range is zero.
    /// Cancellation: not applicable.
    public func length(of index: Int) -> Double {
        guard index >= 0, index < count else { return 0 }

        let end = index == count - 1 ? starts[index + 1] : starts[index + 1] - spacing
        return max(0, end - starts[index])
    }

    /// Index of the item whose extent (with its trailing gap) contains `position`, clamped to
    /// the run; `nil` only for an empty run.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func index(at position: Double) -> Int? {
        guard count > 0 else { return nil }

        var low = 0
        var high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= position {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Items intersecting `[lower, upper)` along the axis.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func range(from lower: Double, to upper: Double) -> Range<Int> {
        guard count > 0, upper > lower, upper > 0, lower < totalExtent,
            let first = index(at: max(0, lower)), let last = index(at: upper)
        else { return 0..<0 }

        let end = starts[last] < upper ? last + 1 : last
        return first..<max(first, end)
    }
}

/// Direction the viewport last moved along its axis — decides which side of a preparation
/// range is "leading".
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ScrollDirectionHint: Sendable, Hashable {
    /// Toward larger offsets.
    case forward
    /// Toward smaller offsets.
    case backward
}

/// UI preparation distances around the viewport, in viewport lengths (P6.8). They are
/// independent of data pagination: fetching models never forces their nodes into existence.
/// `display` bounds live, laid-out nodes; `preload` is the wider range a provider may prepare
/// without materializing nodes.
///
/// Ownership: a value. Isolation: none. Errors: none; negative or non-finite distances become
/// zero. Cancellation: not applicable.
public struct PreparationRanges: Sendable, Hashable {
    /// Display range ahead of the movement direction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let displayLeading: Double

    /// Display range behind the movement direction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let displayTrailing: Double

    /// Preload range ahead of the movement direction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let preloadLeading: Double

    /// Preload range behind the movement direction.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let preloadTrailing: Double

    /// Creates preparation ranges. Preload is widened to contain display when smaller.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none — invalid values
    /// become zero. Cancellation: not applicable.
    public init(
        displayLeading: Double = 1,
        displayTrailing: Double = 0.5,
        preloadLeading: Double = 2,
        preloadTrailing: Double = 1
    ) {
        func clean(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        self.displayLeading = clean(displayLeading)
        self.displayTrailing = clean(displayTrailing)
        self.preloadLeading = max(clean(preloadLeading), self.displayLeading)
        self.preloadTrailing = max(clean(preloadTrailing), self.displayTrailing)
    }

    /// Ranges that keep only the visible items — the low-memory mode.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let visibleOnly = PreparationRanges(
        displayLeading: 0,
        displayTrailing: 0,
        preloadLeading: 0,
        preloadTrailing: 0
    )
}

/// The item ranges derived from one viewport position (R10): what is visible, what keeps
/// live nodes, and what may be prepared ahead. `display` is additionally capped by the
/// container's materialization limit, so live UI is bounded by the window, not the model
/// count.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct VirtualizationWindow: Sendable, Hashable {
    /// Items intersecting the viewport.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let visible: Range<Int>

    /// Items that keep live nodes: visible plus display distances, capped.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let display: Range<Int>

    /// Items a provider may prepare without nodes: contains `display`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let preload: Range<Int>

    /// Creates a window from explicit ranges — for tests and replayed diagnostics.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(visible: Range<Int>, display: Range<Int>, preload: Range<Int>) {
        self.visible = visible
        self.display = display
        self.preload = preload
    }

    /// Computes the window for a viewport over `extents`.
    ///
    /// `maximumDisplayCount` caps live items; when the cap bites, the visible items are kept
    /// first and the remainder goes to the leading side.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none — a zero or negative
    /// viewport yields empty ranges. Cancellation: not applicable.
    public static func compute(
        extents: ItemExtentIndex,
        viewportOffset: Double,
        viewportLength: Double,
        direction: ScrollDirectionHint = .forward,
        ranges: PreparationRanges = PreparationRanges(),
        maximumDisplayCount: Int = .max
    ) -> VirtualizationWindow {
        guard viewportLength.isFinite, viewportLength > 0, viewportOffset.isFinite else {
            return VirtualizationWindow(visible: 0..<0, display: 0..<0, preload: 0..<0)
        }

        let start = viewportOffset
        let end = viewportOffset + viewportLength
        let forward = direction == .forward
        let visible = extents.range(from: start, to: end)

        func span(leading: Double, trailing: Double) -> Range<Int> {
            let before = (forward ? trailing : leading) * viewportLength
            let after = (forward ? leading : trailing) * viewportLength
            return extents.range(from: start - before, to: end + after)
        }

        let preload = span(leading: ranges.preloadLeading, trailing: ranges.preloadTrailing)
        var display = span(leading: ranges.displayLeading, trailing: ranges.displayTrailing)
        let cap = max(0, maximumDisplayCount)
        if display.count > cap {
            display = capped(display, visible: visible, cap: cap, forward: forward)
        }
        return VirtualizationWindow(visible: visible, display: display, preload: preload)
    }

    private static func capped(
        _ display: Range<Int>,
        visible: Range<Int>,
        cap: Int,
        forward: Bool
    ) -> Range<Int> {
        guard cap > visible.count else {
            let lower = forward ? visible.lowerBound : visible.upperBound - cap
            return lower..<(lower + cap)
        }

        let spare = cap - visible.count
        if forward {
            let upper = min(display.upperBound, visible.upperBound + spare)
            let lower = max(display.lowerBound, upper - cap)
            return lower..<upper
        }

        let lower = max(display.lowerBound, visible.lowerBound - spare)
        let upper = min(display.upperBound, lower + cap)
        return lower..<upper
    }
}
