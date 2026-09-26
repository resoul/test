extension FlexboxEngine {
    /// Performs a pure top-down frame pass using a measured container frame, using a fresh
    /// cache.
    ///
    /// Ownership: the returned result owns copied placements. Isolation: none; no live `Node`
    /// or platform object is accessed. Errors: throws `LayoutCancellationError.cancelled` if
    /// `context` reports cancellation — checked once per recursive call, at each level (D09).
    /// Cancellation: a cancelled pass produces no result; nothing partial is returned.
    public static func layoutContainer(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy = PixelRoundingPolicy(),
        context: LayoutContext = .noCancellation
    ) throws -> LayoutResult {
        var cache = FlexMeasureCache()
        return try layoutContainer(
            input: input,
            frame: frame,
            roundingPolicy: roundingPolicy,
            context: context,
            cache: &cache
        )
    }

    /// Performs layout using a request-local measurement cache shared with a prior measure pass.
    ///
    /// Ownership: the cache remains owned by the caller. Isolation: none. Errors: throws
    /// `LayoutCancellationError.cancelled` if `context` reports cancellation. Cancellation: the
    /// caller discards the cache with the request.
    public static func layoutContainer(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy = PixelRoundingPolicy(),
        context: LayoutContext = .noCancellation,
        cache: inout FlexMeasureCache
    ) throws -> LayoutResult {
        var placements: [LayoutPlacement] = []
        try placeContainer(
            input: input,
            frame: frame,
            roundingPolicy: roundingPolicy,
            context: context,
            cache: &cache,
            parentMeasure: nil,
            into: &placements
        )
        return LayoutResult(
            placements: placements,
            treeIdentity: input.identity,
            environmentRevision: input.environmentRevision,
            contentRevision: input.contentRevision
        )
    }

    /// The child constraint the parent's measurement offered this node (defect #14): the
    /// parent's main axis and the cross space it gave its items. A node whose frame is
    /// exactly that space on the cross axis and its own natural size on the main axis (it
    /// was stretched, and neither grew nor shrank) is already measured under that constraint;
    /// an `(exact, exact)` pass at the same numbers gives its children the same space, so the
    /// existing measurement is looked up instead of re-measuring the subtree at every level —
    /// which made nesting O(depth²). The measurement was taken with the main axis
    /// `.unspecified` (ADR 0009), so only the cross space identifies it.
    private struct ParentMeasure {
        let isHorizontal: Bool
        let availableCross: Double?
    }

    /// Appends this container's placement and its subtree's to `placements`. One array for
    /// the whole pass: returning a fresh array per level and copying it upward made a deep
    /// chain O(nodes × depth) (defect #23 — depth 3000: 1 s).
    private static func placeContainer(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy,
        context: LayoutContext,
        cache: inout FlexMeasureCache,
        parentMeasure: ParentMeasure?,
        into placements: inout [LayoutPlacement]
    ) throws {
        try context.checkCancellation()
        let roundedFrame = frame.rounded(to: roundingPolicy)
        placements.append(LayoutPlacement(identity: input.identity, frame: roundedFrame))
        let padding = input.style.padding.resolved(for: input.direction)
        let inner = LayoutFrame(
            origin: LayoutPoint(x: frame.origin.x + padding.left, y: frame.origin.y + padding.top),
            width: max(0, frame.width - padding.left - padding.right),
            height: max(0, frame.height - padding.top - padding.bottom)
        )
        let measured =
            try reusableMeasure(
                input: input,
                frame: frame,
                parentMeasure: parentMeasure,
                cache: &cache
            )
            ?? measureContainer(
                input: input,
                constraint: SizeConstraint(
                    width: .exact(frame.width),
                    height: .exact(frame.height)
                ),
                context: context,
                cache: &cache
            )
        let isHorizontal = input.style.flexDirection.isHorizontal
        // What this container's own measurement offered its items — the same formula
        // `measure` uses — so each child can find that measurement again below.
        let offered = availableSpace(input: input, constraint: measured.cacheKey.constraint)
        let childParentMeasure = ParentMeasure(
            isHorizontal: isHorizontal,
            availableCross: offered.cross
        )
        let reversed =
            input.style.flexDirection.isReversed
            != (isHorizontal && input.direction == .rightToLeft)
        let gap = input.style.gap
        let availableMain = isHorizontal ? inner.width : inner.height
        let availableCross = isHorizontal ? inner.height : inner.width
        let naturalCross =
            measured.lines.reduce(0) { $0 + $1.crossSize }
            + input.style.crossGap * Double(max(0, measured.lines.count - 1))
        // `frame` is always definite in this top-down pass — whether it came from an explicit
        // `width`/`height`, from the parent stretching or flexing this container, or from the
        // host's bounds at the root. So, as in CSS, a container's lines own its whole inner
        // cross size: a single line fills it (giving `alignItems`/`alignSelf: .center/.end`
        // something to align within) and `alignContent: .stretch` shares any remainder among
        // wrapped lines. When the frame equals the natural size there is nothing to share and
        // this is a no-op, so an auto-sized container laid out at its measured size is
        // unaffected.
        let crossFree = max(0, availableCross - naturalCross)
        let stretchLines = input.style.alignContent == .stretch && !measured.lines.isEmpty
        let lineCrossSizes = measured.lines.map { line in
            line.crossSize + (stretchLines ? crossFree / Double(measured.lines.count) : 0)
        }
        let distributedCrossFree = stretchLines ? 0 : crossFree
        let (crossOffset, crossSpacing) = crossDistribution(
            mode: input.style.alignContent,
            free: distributedCrossFree,
            count: measured.lines.count,
            baseSpacing: input.style.crossGap
        )
        let orderedLines: [(line: FlexLine, crossSize: Double)] =
            input.style.flexWrap == .wrapReverse
            ? zip(measured.lines, lineCrossSizes).reversed().map { (line: $0.0, crossSize: $0.1) }
            : zip(measured.lines, lineCrossSizes).map { (line: $0.0, crossSize: $0.1) }
        var crossCursor = crossOffset
        for entry in orderedLines {
            let line = entry.line
            let lineCrossSize = entry.crossSize
            let totalMain =
                line.items.reduce(0) { $0 + $1.mainSize }
                + gap * Double(max(0, line.items.count - 1))
            let (justifyOffset, justifyGap) = mainDistribution(
                mode: input.style.justifyContent,
                free: max(0, availableMain - totalMain),
                count: line.items.count,
                baseSpacing: gap
            )
            var cursor = justifyOffset
            for item in line.items {
                guard let child = input.children.first(where: { $0.identity == item.identity })
                else {
                    continue
                }
                let size =
                    isHorizontal
                    ? MeasuredSize(width: item.mainSize, height: item.crossSize)
                    : MeasuredSize(width: item.crossSize, height: item.mainSize)
                let margin = child.style.margin.resolved(for: input.direction)
                let main = isHorizontal ? size.width : size.height
                let cross: Double = isHorizontal ? size.height : size.width
                let crossAvailable: Double = lineCrossSize
                let lineBaseline = line.items.compactMap(\.baseline).max()
                let alignment: AlignItems
                switch child.style.alignSelf {
                case .auto: alignment = input.style.alignItems
                case .stretch: alignment = .stretch
                case .start: alignment = .start
                case .end: alignment = .end
                case .center: alignment = .center
                case .baseline: alignment = .baseline
                }
                let stretchedCross =
                    alignment == .stretch
                        && (isHorizontal ? child.style.height == .auto : child.style.width == .auto)
                    ? crossAvailable
                    : cross
                let resolvedSize =
                    isHorizontal
                    ? MeasuredSize(width: main, height: stretchedCross)
                    : MeasuredSize(width: stretchedCross, height: main)
                let crossOffset: Double
                switch alignment {
                case .start, .stretch: crossOffset = 0
                case .baseline:
                    crossOffset =
                        item.baseline.flatMap { baseline in
                            lineBaseline.map { max(0, $0 - baseline) }
                        } ?? 0
                case .end: crossOffset = max(0, crossAvailable - cross)
                case .center: crossOffset = max(0, (crossAvailable - cross) / 2)
                }
                let mainPosition = reversed ? availableMain - cursor - main : cursor
                var x =
                    isHorizontal
                    ? inner.origin.x + mainPosition + margin.left
                    : inner.origin.x + crossCursor + crossOffset + margin.left
                var y =
                    isHorizontal
                    ? inner.origin.y + crossCursor + crossOffset + margin.top
                    : inner.origin.y + mainPosition + margin.top
                if child.style.positionType == .absolute {
                    let offsets = child.style.offsets.resolved(for: input.direction)
                    x =
                        offsets.left.map { inner.origin.x + $0 } ?? offsets.right.map {
                            inner.origin.x + inner.width - $0 - size.width
                        } ?? inner.origin.x
                    y =
                        offsets.top.map { inner.origin.y + $0 } ?? offsets.bottom.map {
                            inner.origin.y + inner.height - $0 - size.height
                        } ?? inner.origin.y
                }
                let childFrame = LayoutFrame(
                    origin: LayoutPoint(x: x, y: y),
                    width: resolvedSize.width,
                    height: resolvedSize.height
                )
                logPlacement(identity: child.identity, frame: childFrame)
                try placeContainer(
                    input: child,
                    frame: childFrame,
                    roundingPolicy: roundingPolicy,
                    context: context,
                    cache: &cache,
                    parentMeasure: childParentMeasure,
                    into: &placements
                )
                cursor += main + justifyGap
            }
            crossCursor += lineCrossSize + crossSpacing
        }
        for child in input.children where child.style.positionType == .absolute {
            let childMeasure = try measureContainer(
                input: child,
                constraint: SizeConstraint(
                    width: .atMost(inner.width),
                    height: .atMost(inner.height)
                ),
                context: context,
                cache: &cache
            ).parentSize
            let offsets = child.style.offsets.resolved(for: input.direction)
            let x =
                offsets.left.map { inner.origin.x + $0 } ?? offsets.right.map {
                    inner.origin.x + inner.width - $0 - childMeasure.width
                } ?? inner.origin.x
            let y =
                offsets.top.map { inner.origin.y + $0 } ?? offsets.bottom.map {
                    inner.origin.y + inner.height - $0 - childMeasure.height
                } ?? inner.origin.y
            let childFrame = LayoutFrame(
                origin: LayoutPoint(x: x, y: y),
                width: childMeasure.width,
                height: childMeasure.height
            )
            logPlacement(identity: child.identity, frame: childFrame)
            try placeContainer(
                input: child,
                frame: childFrame,
                roundingPolicy: roundingPolicy,
                context: context,
                cache: &cache,
                parentMeasure: nil,
                into: &placements
            )
        }
    }

    private static func logPlacement(identity: NodeID, frame: LayoutFrame) {
        let zeroSize = frame.width == 0 || frame.height == 0
        Log.on(
            .place,
            zeroSize ? "ZERO-SIZE" : "frame",
            node: identity,
            "frame=(\(frame.origin.x),\(frame.origin.y),\(frame.width)x\(frame.height))"
        )
    }

    /// The parent's measurement of `input` under its child constraint, if it exists and
    /// describes exactly this frame — see `ParentMeasure`. `nil` otherwise: a node that grew,
    /// shrank, is narrower than the space it was offered, or resolves fractions somewhere
    /// below (`dependsOnAvailableSize`) is measured under its exact frame as before.
    private static func reusableMeasure(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        parentMeasure: ParentMeasure?,
        cache: inout FlexMeasureCache
    ) -> FlexMeasureResult? {
        guard let parentMeasure, let availableCross = parentMeasure.availableCross else {
            return nil
        }
        let main = parentMeasure.isHorizontal ? frame.width : frame.height
        let cross = parentMeasure.isHorizontal ? frame.height : frame.width
        guard cross == availableCross else { return nil }
        let constraint =
            parentMeasure.isHorizontal
            ? SizeConstraint(width: .unspecified, height: .atMost(availableCross))
            : SizeConstraint(width: .atMost(availableCross), height: .unspecified)
        guard
            let natural = cache.lookup(
                key: LayoutMeasureCacheKey(
                    treeIdentity: input.identity,
                    contentRevision: input.contentRevision,
                    environmentRevision: input.environmentRevision,
                    constraint: constraint,
                    direction: input.direction
                )
            )
        else { return nil }
        let naturalMain =
            parentMeasure.isHorizontal ? natural.parentSize.width : natural.parentSize.height
        return naturalMain == main && !natural.dependsOnAvailableSize ? natural : nil
    }

    private static func mainDistribution(
        mode: JustifyContent,
        free: Double,
        count: Int,
        baseSpacing: Double
    ) -> (offset: Double, spacing: Double) {
        guard count > 0 else { return (0, baseSpacing) }
        switch mode {
        case .start: return (0, baseSpacing)
        case .end: return (free, baseSpacing)
        case .center: return (free / 2, baseSpacing)
        case .spaceBetween:
            return (0, count > 1 ? baseSpacing + free / Double(count - 1) : 0)
        case .spaceAround:
            let spacing = baseSpacing + free / Double(count)
            return (spacing / 2, spacing)
        case .spaceEvenly:
            let spacing = baseSpacing + free / Double(count + 1)
            return (spacing, spacing)
        }
    }

    private static func crossDistribution(
        mode: AlignContent,
        free: Double,
        count: Int,
        baseSpacing: Double
    ) -> (offset: Double, spacing: Double) {
        guard count > 0 else { return (0, baseSpacing) }
        switch mode {
        case .start, .stretch: return (0, baseSpacing)
        case .end: return (free, baseSpacing)
        case .center: return (free / 2, baseSpacing)
        case .spaceBetween:
            return (0, count > 1 ? baseSpacing + free / Double(count - 1) : 0)
        case .spaceAround:
            let spacing = baseSpacing + free / Double(count)
            return (spacing / 2, spacing)
        case .spaceEvenly:
            let spacing = baseSpacing + free / Double(count + 1)
            return (spacing, spacing)
        }
    }
}

extension FlexDirection {
    var isReversed: Bool {
        switch self {
        case .rowReverse, .columnReverse: return true
        case .row, .column: return false
        }
    }
}
