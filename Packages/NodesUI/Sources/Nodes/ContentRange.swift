import FlexEngine
import LayoutCore

/// How a container permits preparation and active display effects.
public enum ContentActivity: Sendable, Hashable {
    /// Evaluate ranges and allow visible effects inside the effective viewport.
    case active
    /// Evaluate preparation ranges, but never allow visible effects.
    /// A neighboring pane can supply its prospective viewport with this activity.
    case preparing
    /// Request no work, as for a discarded pane or a suspended host.
    case inactive
}

/// A viewport intersected with its ancestor clips, in one coordinate space.
///
/// A list may use estimated item frames without creating nodes. The caller converts
/// frames and clips into the same space and supplies host or pane activity explicitly.
/// This value does not inspect nodes, infer occlusion by other windows, or page data.
public struct ContentViewport: Sendable, Hashable {
    /// The positive-area intersection of bounds and clips, or `nil` when fully clipped.
    public let effectiveBounds: LayoutRect?

    /// Whether preparation and active effects are permitted.
    public let activity: ContentActivity

    /// Creates an effective viewport from bounds and any enclosing clipping rectangles.
    ///
    /// Non-finite, empty, or negative rectangles produce an empty viewport. A hidden pane
    /// that should prepare nearby content supplies prospective bounds and `.preparing`;
    /// a pane that should do no work uses `.inactive`.
    public init(
        bounds: LayoutRect,
        clips: [LayoutRect] = [],
        activity: ContentActivity = .active
    ) {
        var effective = validContentRect(bounds) ? bounds : nil
        for clip in clips {
            guard let current = effective else { break }
            effective = contentIntersection(current, clip)
        }
        effectiveBounds = effective
        self.activity = activity
    }
}

/// Fixed preparation ranges with wider retention thresholds to avoid boundary churn.
///
/// Distances are viewport widths horizontally and viewport heights vertically. The larger
/// normalized gap determines proximity, so both axes and partially shown panes use the
/// same rule. Visible requires a positive-area intersection and has no hysteresis.
public struct ContentRangePolicy: Sendable, Hashable {
    /// Distance at which data preparation starts.
    public let preloadDistance: Double

    /// Distance at which measurement and drawing preparation start.
    public let displayDistance: Double

    /// Distance beyond which existing preload demand is removed.
    public let preloadRetentionDistance: Double

    /// Distance beyond which existing display demand is removed.
    public let displayRetentionDistance: Double

    /// Creates nested entry and retention ranges, measured in viewport lengths.
    ///
    /// Negative or non-finite values become zero. Retention never falls below entry,
    /// and preload thresholds never fall below their corresponding display thresholds.
    public init(
        preloadDistance: Double = 2,
        displayDistance: Double = 0.5,
        preloadRetentionDistance: Double = 3,
        displayRetentionDistance: Double = 1
    ) {
        func distance(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        let display = distance(displayDistance)
        let preload = max(display, distance(preloadDistance))
        let displayRetention = max(display, distance(displayRetentionDistance))
        self.displayDistance = display
        self.preloadDistance = preload
        self.displayRetentionDistance = displayRetention
        self.preloadRetentionDistance = max(
            preload,
            displayRetention,
            distance(preloadRetentionDistance)
        )
    }

    /// Evaluates effective demand without creating a node or starting work.
    ///
    /// - Parameters:
    ///   - frame: The item's measured or estimated rectangle in the viewport's space.
    ///   - viewport: Bounds, clips, and activity supplied by the container.
    ///   - previous: This item's previous range demand, used only for hysteresis. Request
    ///     independent measurement separately by adding `.measure` to the returned demand.
    public func demand(
        for frame: LayoutRect,
        in viewport: ContentViewport,
        previous: ContentDemand = []
    ) -> ContentDemand {
        guard viewport.activity != .inactive, let bounds = viewport.effectiveBounds,
            validContentRect(frame)
        else { return [] }

        let gapX = max(
            0,
            frame.origin.x - (bounds.origin.x + bounds.size.width),
            bounds.origin.x - (frame.origin.x + frame.size.width)
        )
        let gapY = max(
            0,
            frame.origin.y - (bounds.origin.y + bounds.size.height),
            bounds.origin.y - (frame.origin.y + frame.size.height)
        )
        let distance = max(gapX / bounds.size.width, gapY / bounds.size.height)
        let old = previous.requirements
        var result: ContentDemand = []
        let preload = old.contains(.preload) ? preloadRetentionDistance : preloadDistance
        let display = old.contains(.display) ? displayRetentionDistance : displayDistance
        if distance <= preload { result.insert(.preload) }
        if distance <= display { result.insert(.display) }
        if viewport.activity == .active, contentIntersection(frame, bounds) != nil {
            result.insert(.visible)
        }
        return result.requirements
    }
}

private func validContentRect(_ rect: LayoutRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
        && rect.size.width.isFinite && rect.size.height.isFinite
        && rect.size.width > 0 && rect.size.height > 0
        && (rect.origin.x + rect.size.width).isFinite
        && (rect.origin.y + rect.size.height).isFinite
}

private func contentIntersection(_ first: LayoutRect, _ second: LayoutRect) -> LayoutRect? {
    guard validContentRect(first), validContentRect(second) else { return nil }

    let x = max(first.origin.x, second.origin.x)
    let y = max(first.origin.y, second.origin.y)
    let endX = min(first.origin.x + first.size.width, second.origin.x + second.size.width)
    let endY = min(first.origin.y + first.size.height, second.origin.y + second.size.height)
    guard x < endX, y < endY else { return nil }

    return LayoutRect(x: x, y: y, width: endX - x, height: endY - y)
}
