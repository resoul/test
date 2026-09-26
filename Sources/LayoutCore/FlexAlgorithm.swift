// The flex layout algorithm, CSS Flexible Box Layout Module Level 1 §9. Each step is marked
// with its section so that the code can be checked against the specification line by line.
//
// Coordinates inside a container are logical until the very end: `main`/`cross` positions
// are measured from the main-start / cross-start edge of the content box, and are turned
// into physical x/y only when a child frame is written. That is what makes `row-reverse`,
// right-to-left and `wrap-reverse` the same code as the default case.

private let epsilon = 1e-9

/// One in-flow child while its container runs the algorithm.
struct FlexItem {
    let node: Int
    let marginMainStart: Double
    let marginMainEnd: Double
    let marginCrossStart: Double
    let marginCrossEnd: Double
    let autoMainStart: Bool
    let autoMainEnd: Bool
    let autoCrossStart: Bool
    let autoCrossEnd: Bool
    let sizeMain: Double?
    let sizeCross: Double?
    var minMain: Double
    /// The content size along the main axis that gives the flex base size, until it is
    /// measured.
    var basisRequest: SizeRequest?
    /// The min-content size along the main axis that gives the automatic minimum size, until
    /// it is measured.
    var minimumRequest: SizeRequest?
    /// The automatic minimum waits until a line shrinks; see `appendItem`.
    var defersMinimum = false
    let maxMain: Double
    let minCross: Double
    let maxCross: Double
    let paddingMain: Double
    let paddingCross: Double
    let grow: Double
    let shrink: Double
    let align: AlignSelf
    /// `align-self: stretch` takes effect: the cross size property is `auto` (a percentage
    /// is not, even when it cannot be resolved) and neither cross margin is `auto`.
    let stretches: Bool
    /// Main size per point of cross size, from `aspect-ratio`.
    let ratio: Double?
    /// Cross size already known while the flex base size is determined (§9.2 step 3, §9.8).
    let crossForBasis: Double?
    /// `flex-basis` is a length or a resolved percentage, not `auto` or an unresolvable
    /// percentage.
    let basisIsDefinite: Bool
    /// Whether the item's flexed main size counts as definite for its own children (§9.8):
    /// yes when the container's main size is definite or the item specifies its main size or
    /// its flex basis. The last one is Chromium's reading: a column item with `flex-basis: 0`
    /// in a content-sized column resolves its children's percentages against its flexed height.
    let mainIsDefinite: Bool

    var basis = 0.0
    var hypotheticalMain = 0.0
    var target = 0.0
    var frozen = false
    var hypotheticalCross = 0.0
    var cross = 0.0
    var mainPosition = 0.0
    var crossPosition = 0.0
    /// First baseline from the top of the border box, for an item aligned by baseline.
    var baseline: Double?

    var marginsMain: Double { marginMainStart + marginMainEnd }
    var marginsCross: Double { marginCrossStart + marginCrossEnd }
    var outerHypotheticalMain: Double { hypotheticalMain + marginsMain }
    var outerTarget: Double { target + marginsMain }
    var hasAutoCrossMargin: Bool { autoCrossStart || autoCrossEnd }
}

/// A size request for an item along its container's main axis, kept until it runs.
struct SizeRequest {
    let known: OptionalSize
    let parent: OptionalSize
    let available: AvailableSize
    let definite: DefiniteAxes
}

struct FlexLine {
    var items: [Int]
    var crossSize = 0.0
    var crossPosition = 0.0
    /// Distance from the top of the line to the shared baseline of its baseline-aligned
    /// items, when it has any.
    var ascent: Double?
}

/// Everything a container derives from its own style before looking at its children.
struct ContainerAxes {
    let isRow: Bool
    let reversedMain: Bool
    let reversedCross: Bool
    let mainGap: Double
    let crossGap: Double
    let paddingMain: Double
    let paddingCross: Double

    init(style: FlexStyle, direction: LayoutDirection, own: OwnSize) {
        isRow = style.direction.isRow
        let rtl = direction == .rightToLeft
        // A row runs from the inline start, which is the right edge in right-to-left text; a
        // column always runs top to bottom. `wrap-reverse` swaps cross-start and cross-end;
        // for a column the cross axis is inline, so right-to-left flips it too.
        reversedMain = isRow ? style.direction.isReverse != rtl : style.direction.isReverse
        reversedCross = (style.wrap == .wrapReverse) != (!isRow && rtl)
        mainGap = max(0, isRow ? style.columnGap : style.rowGap)
        crossGap = max(0, isRow ? style.rowGap : style.columnGap)
        paddingMain = isRow ? own.paddingWidth : own.paddingHeight
        paddingCross = isRow ? own.paddingHeight : own.paddingWidth
    }

    func main(_ size: LayoutSize) -> Double { isRow ? size.width : size.height }
    func cross(_ size: LayoutSize) -> Double { isRow ? size.height : size.width }

    /// Margin on the main-start/main-end/cross-start/cross-end side, from physical margins.
    func mainStart<Value>(_ edges: Physical<Value>) -> Value {
        isRow
            ? (reversedMain ? edges.right : edges.left) : (reversedMain ? edges.bottom : edges.top)
    }

    func mainEnd<Value>(_ edges: Physical<Value>) -> Value {
        isRow
            ? (reversedMain ? edges.left : edges.right) : (reversedMain ? edges.top : edges.bottom)
    }

    func crossStart<Value>(_ edges: Physical<Value>) -> Value {
        isRow
            ? (reversedCross ? edges.bottom : edges.top)
            : (reversedCross ? edges.right : edges.left)
    }

    func crossEnd<Value>(_ edges: Physical<Value>) -> Value {
        isRow
            ? (reversedCross ? edges.top : edges.bottom)
            : (reversedCross ? edges.left : edges.right)
    }
}

/// A container's own geometry and settings for one run of the algorithm, derived before its
/// children are looked at. Every container being laid out keeps one on the stack while its
/// descendants are, so it holds only what the later steps read, not the whole style.
struct ContainerRun {
    let index: Int
    let own: OwnSize
    let axes: ContainerAxes
    /// `flex-wrap` as specified.
    let styleWrap: FlexWrap
    /// `flex-wrap` as lines are collected: while a column's width is still being found,
    /// browsers size it as if its items did not wrap — its width is that of its widest item.
    /// Wrapping into columns happens once the width is known.
    let wrap: FlexWrap
    let justifyContent: JustifyContent
    let alignItems: AlignItems
    let alignContent: AlignContent
    let isReverse: Bool
    let minMain: Double
    let maxMain: Double
    let minCross: Double
    let maxCross: Double
    /// The content box along each axis, when the container's size is known.
    let innerMainDefinite: Double?
    let innerCrossDefinite: Double?
    /// The space available to the items (§9.2 step 2).
    let itemsAvailableMain: AvailableSpace
    let itemsAvailableCross: AvailableSpace
    /// The containing block of the items for percentages.
    let itemParent: OptionalSize

    var isRow: Bool { axes.isRow }
    var singleLine: Bool { wrap == .noWrap }
}

extension Solver {
    /// Runs the algorithm over container `index`. The steps are separate functions so that
    /// each keeps its temporaries in its own stack frame: this function is on the stack once
    /// per nesting level, and only its few locals stay there while descendants are solved.
    mutating func flexLayout(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        mode: RunMode,
        contentOnly: Axis? = nil,
        definite: DefiniteAxes = .both,
        ratio: RatioTransfer = .size,
        percentHeight: Double? = nil
    ) throws -> LayoutSize {
        try context.checkpoint()
        try checkStack()
        let reportsBaseline = wantsBaseline
        wantsBaseline = false
        if ratio == .size, nodes[index].hasAspectRatio,
            let size = try ratioLayout(
                index,
                known: known,
                parent: parent,
                available: available,
                mode: mode,
                contentOnly: contentOnly,
                definite: definite,
                reportsBaseline: reportsBaseline
            )
        {
            return size
        }

        if contentOnly != .horizontal, known.width == nil, nodes[index].sizesWidthFirst {
            let style = self.style(index, parentWidth: parent.width)
            let own = ownSize(
                index,
                style: style,
                known: known,
                parent: parent,
                ratio: .none,
                definite: definite
            )
            if own.width == nil {
                // CSS sizes a box's width before its children: while it comes from the
                // content, a child's percentage width is cyclic (`auto`); then it resolves
                // against the width, and the child lays out — and wraps — at that width. A
                // row breaks its lines at that width too, not at the space it is offered. A
                // content height is such a layout as well.
                let content = try compute(
                    index,
                    known: known,
                    parent: parent,
                    available: available,
                    mode: .size,
                    contentOnly: .horizontal,
                    definite: definite
                )
                wantsBaseline = reportsBaseline
                return try flexLayout(
                    index,
                    known: OptionalSize(
                        width: clamp(content.width, own.minWidth, own.maxWidth, own.paddingWidth),
                        height: known.height
                    ),
                    parent: parent,
                    available: available,
                    mode: mode,
                    contentOnly: contentOnly,
                    definite: DefiniteAxes(width: true, height: definite.height),
                    ratio: ratio
                )
            }
        }

        let run = beginContainer(
            index,
            known: known,
            parent: parent,
            available: available,
            contentOnly: contentOnly,
            definite: definite,
            ratio: ratio,
            percentHeight: percentHeight
        )

        let children = flowChildren(run)
        var items: [FlexItem] = []
        items.reserveCapacity(children.count)
        for (offset, child) in children.enumerated() {
            if offset > 0 && offset % 256 == 0 { try context.checkpoint() }
            appendItem(child, run: run, to: &items)
            try measureItem(&items, items.count - 1, axes: run.axes)
        }

        // §9.3: collect items into flex lines — at the inner main size, or where it is not
        // definite, at the space a row is offered. A column is offered no height: it breaks
        // at a definite height it does not take yet (the aspect ratio's, while its content is
        // measured), else at its maximum height, and without one it is a single line (as in
        // Chromium).
        let lineLimit =
            run.innerMainDefinite
            ?? (run.axes.isRow
                ? run.itemsAvailableMain.definiteValue
                : run.itemParent.height
                    ?? (run.maxMain.isFinite ? max(0, run.maxMain - run.axes.paddingMain) : nil))
        var lines = collectLines(
            items,
            wrap: run.wrap,
            gap: run.axes.mainGap,
            limit: lineLimit,
            minContent: run.innerMainDefinite == nil && run.axes.isRow
                && run.itemsAvailableMain == .minContent
        )
        let innerMain = try innerMainSize(run, items: items, lines: lines)

        // §9.7: resolve flexible lengths, line by line.
        for line in lines {
            try resolvePendingMinimums(
                line.items,
                &items,
                axes: run.axes,
                innerMain: innerMain,
                gap: run.axes.mainGap
            )
            resolveFlexibleLengths(line.items, &items, innerMain: innerMain, gap: run.axes.mainGap)
        }

        try crossSizes(run, &items)
        if !run.isRow && !run.singleLine {
            try fitToLines(run, lines, &items)
        }
        let innerCross = placeLines(run, &lines, &items, innerMain: innerMain)

        let isRow = run.isRow
        let axes = run.axes
        let result = LayoutSize(
            width: run.own.width
                ?? (isRow ? innerMain + axes.paddingMain : innerCross + axes.paddingCross),
            height: run.own.height
                ?? (isRow ? innerCross + axes.paddingCross : innerMain + axes.paddingMain)
        )

        if reportsBaseline {
            lastBaseline = try containerBaseline(
                lines: lines,
                items: items,
                axes: axes,
                isReverse: run.isReverse,
                own: run.own,
                innerMain: innerMain,
                innerCross: innerCross,
                itemParent: run.itemParent
            )
        }

        guard case let .layout(origin) = mode else { return result }

        try layoutItems(run, items, origin: origin, innerMain: innerMain, innerCross: innerCross)
        try layoutAbsoluteChildren(
            run,
            size: result,
            origin: origin,
            innerMain: innerMain,
            innerCross: innerCross
        )
        return result
    }

    /// The container's own geometry.
    @inline(never)
    private func beginContainer(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        contentOnly: Axis?,
        definite: DefiniteAxes,
        ratio: RatioTransfer,
        percentHeight: Double?
    ) -> ContainerRun {
        let style = self.style(index, parentWidth: parent.width)
        var own = ownSize(
            index,
            style: style,
            known: known,
            parent: parent,
            contentOnly: contentOnly,
            ratio: ratio,
            definite: definite
        )
        if let percentHeight { own.definiteHeight = percentHeight }
        let axes = ContainerAxes(style: style, direction: nodes[index].direction, own: own)
        let isRow = axes.isRow
        let ownMain = isRow ? own.width : own.height
        let ownCross = isRow ? own.height : own.width

        // §9.2 step 2: the space available to the items — the content box when the container
        // size is definite, otherwise the space offered to the container minus its padding.
        let innerMainDefinite = ownMain.map { max(0, $0 - axes.paddingMain) }
        let innerCrossDefinite = ownCross.map { max(0, $0 - axes.paddingCross) }
        // The containing block of the items for percentages: the content box, where it is
        // definite. A size that is merely known (content-sized) does not count.
        let percentMain = (isRow ? own.definiteWidth : own.definiteHeight)
            .map { max(0, $0 - axes.paddingMain) }
        let percentCross = (isRow ? own.definiteHeight : own.definiteWidth)
            .map { max(0, $0 - axes.paddingCross) }

        return ContainerRun(
            index: index,
            own: own,
            axes: axes,
            styleWrap: style.wrap,
            // Under a min-content width a column is as wide as its widest item, not its lines
            // side by side (Chromium): it is measured as one line.
            wrap: !isRow && available.width == .minContent ? .noWrap : style.wrap,
            justifyContent: style.justifyContent,
            alignItems: style.alignItems,
            alignContent: style.alignContent,
            isReverse: style.direction.isReverse,
            minMain: isRow ? own.minWidth : own.minHeight,
            maxMain: isRow ? own.maxWidth : own.maxHeight,
            minCross: isRow ? own.minHeight : own.minWidth,
            maxCross: isRow ? own.maxHeight : own.maxWidth,
            innerMainDefinite: innerMainDefinite,
            innerCrossDefinite: innerCrossDefinite,
            itemsAvailableMain: innerMainDefinite.map { AvailableSpace.definite($0) }
                ?? (isRow ? available.width : available.height).shrunk(by: axes.paddingMain),
            itemsAvailableCross: innerCrossDefinite.map { AvailableSpace.definite($0) }
                ?? (isRow ? available.height : available.width).shrunk(by: axes.paddingCross),
            itemParent: OptionalSize(main: percentMain, cross: percentCross, isRow: isRow)
        )
    }

    /// A container with an aspect ratio and no height: the width is known, specified or comes
    /// from the content (within min/max width), and the height follows from it through the
    /// ratio — but, with an `auto` minimum height, never below the content's height (CSS Sizing 4
    /// §5.2.1), as for a leaf. The content is measured as Chromium does it: against the ratio's
    /// height, so a stretched child takes that height instead of its own content's and only
    /// children sized otherwise can raise it. `nil` when the height is given, or the ratio does
    /// not apply.
    @inline(never)
    private mutating func ratioLayout(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        mode: RunMode,
        contentOnly: Axis?,
        definite: DefiniteAxes,
        reportsBaseline: Bool
    ) throws -> LayoutSize? {
        let style = self.style(index, parentWidth: parent.width)
        let own = ownSize(
            index,
            style: style,
            known: known,
            parent: parent,
            contentOnly: contentOnly,
            ratio: .none,
            definite: definite
        )
        guard let ratio = style.aspectRatio, ratio > 0 else { return nil }

        if let axis = contentOnly {
            return try ratioContent(
                index,
                axis: axis,
                ratio: ratio,
                own: own,
                known: known,
                parent: parent,
                available: available,
                mode: mode,
                definite: definite,
                reportsBaseline: reportsBaseline
            )
        }

        if let height = own.height {
            // The width follows from the height — but, with an `auto` minimum width, never
            // below the content's min-content width.
            guard own.width == nil, style.minWidth == .auto else { return nil }

            let minContent = try compute(
                index,
                known: known,
                parent: parent,
                available: AvailableSize(width: .minContent, height: available.height),
                mode: .size,
                contentOnly: .horizontal,
                definite: definite
            )
            let width = ratioDependent(
                height * ratio,
                content: minContent.width,
                minimum: own.minWidth,
                maximum: own.maxWidth,
                floor: own.paddingWidth,
                automaticMinimum: true
            )
            wantsBaseline = reportsBaseline
            return try flexLayout(
                index,
                known: OptionalSize(width: width, height: known.height),
                parent: parent,
                available: available,
                mode: mode,
                definite: DefiniteAxes(width: true, height: definite.height)
            )
        }

        let automaticMinimum = style.minHeight == .auto && style.height == .auto
        // Without an automatic minimum a known width leaves the transfer to `ownSize`.
        guard own.width == nil || automaticMinimum else { return nil }

        var width = own.width
        if width == nil {
            let content = try compute(
                index,
                known: known,
                parent: parent,
                available: available,
                mode: .size,
                contentOnly: .horizontal,
                definite: definite
            )
            // Min/max heights limit the width too, through the ratio (CSS Sizing 4 §5.2); so
            // does the vertical padding, below which the height cannot go.
            width = clamp(
                max(
                    max(own.minHeight, own.paddingHeight) * ratio,
                    min(own.maxHeight * ratio, content.width)
                ),
                own.minWidth,
                own.maxWidth,
                own.paddingWidth
            )
        }

        var height: Double?
        if automaticMinimum, let width {
            let content = try flexLayout(
                index,
                known: OptionalSize(width: width, height: nil),
                parent: parent,
                available: available,
                mode: .size,
                definite: DefiniteAxes(width: true, height: definite.height),
                ratio: .definiteSize
            )
            height = ratioDependent(
                width / ratio,
                content: content.height,
                minimum: own.minHeight,
                maximum: own.maxHeight,
                floor: own.paddingHeight,
                automaticMinimum: true
            )
        }

        // Raised to the content, the box keeps the ratio's height as the base for its
        // children's percentages (Chromium).
        let ratioHeight = width.map {
            clamp($0 / ratio, own.minHeight, own.maxHeight, own.paddingHeight)
        }
        wantsBaseline = reportsBaseline
        return try flexLayout(
            index,
            known: OptionalSize(width: width, height: height ?? known.height),
            parent: parent,
            available: available,
            mode: mode,
            contentOnly: contentOnly,
            definite: DefiniteAxes(width: true, height: height != nil || definite.height),
            percentHeight: height != nil ? ratioHeight : nil
        )
    }

    /// The content size along `axis` of a container with an aspect ratio whose other side is
    /// known: the content's size, but not below the size the ratio transfers from the other
    /// side — as Chromium measures it, a transferred size is a floor even for the content
    /// size, and the content can raise it. Without a known width the height is transferred
    /// from the content's width; without a known height the content's width is limited by the
    /// min/max heights through the ratio.
    @inline(never)
    private mutating func ratioContent(
        _ index: Int,
        axis: Axis,
        ratio: Double,
        own: OwnSize,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        mode: RunMode,
        definite: DefiniteAxes,
        reportsBaseline: Bool
    ) throws -> LayoutSize? {
        let transferred: Double
        // Min/max heights limit the content width through the ratio as well.
        var limit = Double.infinity
        var measuredKnown = known
        var measuredAvailable = available
        switch axis {
        case .horizontal:
            if let height = own.height {
                // The width is the ratio's; the content only sets its minimum: min-content.
                transferred = max(own.paddingWidth, height * ratio)
                measuredAvailable.width = .minContent
            } else {
                transferred = max(own.minHeight, own.paddingHeight) * ratio
                limit = max(transferred, own.maxHeight * ratio)
            }
        case .vertical:
            var width = own.width
            if width == nil {
                let content = try compute(
                    index,
                    known: known,
                    parent: parent,
                    available: available,
                    mode: .size,
                    contentOnly: .horizontal,
                    definite: definite
                )
                width = clamp(content.width, own.minWidth, own.maxWidth, own.paddingWidth)
            }
            transferred = max(own.paddingHeight, (width ?? 0) / ratio)
            // The width is settled, so the height it transfers is the one stretched children
            // take while the content is measured.
            measuredKnown.width = width
        }

        wantsBaseline = reportsBaseline
        let content = try flexLayout(
            index,
            known: measuredKnown,
            parent: parent,
            available: measuredAvailable,
            mode: mode,
            contentOnly: axis,
            definite: definite,
            ratio: .definiteSize
        )
        switch axis {
        case .horizontal:
            return LayoutSize(
                width: max(transferred, min(limit, content.width)),
                height: content.height
            )
        case .vertical:
            return LayoutSize(width: content.width, height: max(content.height, transferred))
        }
    }

    /// §9.1, §5.4: in-flow children in `order`, document order breaking ties.
    @inline(never)
    private func flowChildren(_ run: ContainerRun) -> [Int] {
        let children = nodes[run.index].children
        var flow: [(child: Int, order: Int)] = []
        flow.reserveCapacity(children.count)
        var reordered = false
        for child in children {
            let order: Int?
            if nodes[child].variants.isEmpty {
                order = nodes[child].flowOrder
            } else {
                let childStyle = self.style(child, parentWidth: run.itemParent.width)
                order = FlatNode.flowOrder(childStyle)
            }
            guard let order else { continue }

            flow.append((child, order))
            reordered = reordered || order != 0
        }
        if reordered {
            // Children are indexed in document order, so the index breaks ties.
            flow.sort { $0.order != $1.order ? $0.order < $1.order : $0.child < $1.child }
        }
        return flow.map(\.child)
    }

    /// §9.2 step 4 / §9.3: the container's inner main size.
    @inline(never)
    private mutating func innerMainSize(
        _ run: ContainerRun,
        items: [FlexItem],
        lines: [FlexLine]
    ) throws -> Double {
        if let definite = run.innerMainDefinite { return definite }

        let axes = run.axes
        var content: Double
        if run.isRow {
            // The intrinsic width of a row, as browsers compute it. An item contributes its
            // width if it has one, else its content width — kept at its flex-basis when it
            // could not grow or shrink to reach it — within its min/max. Max-content is the
            // sum of those; min-content is their sum without wrapping, or the largest plain
            // contribution with wrapping; max-content is never below min-content. Under a
            // definite available width the result is fit-content.
            let gaps = axes.mainGap * Double(max(0, items.count - 1))
            var maxContent = gaps
            var minContentSum = gaps
            var minContentLargest = 0.0
            for item in items {
                let maxRaw = try rawContribution(
                    item,
                    .maxContent,
                    axes: axes,
                    itemParent: run.itemParent
                )
                let minRaw = try rawContribution(
                    item,
                    .minContent,
                    axes: axes,
                    itemParent: run.itemParent
                )
                maxContent += flexedContribution(item, maxRaw)
                minContentSum += flexedContribution(item, minRaw)
                minContentLargest = max(minContentLargest, plainContribution(item, minRaw))
            }
            let minContent = run.styleWrap == .noWrap ? minContentSum : minContentLargest
            maxContent = max(maxContent, minContent)
            switch run.itemsAvailableMain {
            case .maxContent: content = maxContent
            case .minContent: content = minContent
            case let .definite(space): content = min(maxContent, max(minContent, space))
            }
        } else {
            content = lines.map { lineOuterHypothetical($0, items, gap: axes.mainGap) }.max() ?? 0
        }

        return max(
            0,
            clamp(content + axes.paddingMain, run.minMain, run.maxMain) - axes.paddingMain
        )
    }

    /// §9.4 steps 7–8: the hypothetical cross size of each item, and the baselines of items
    /// aligned by baseline.
    @inline(never)
    private mutating func crossSizes(_ run: ContainerRun, _ items: inout [FlexItem]) throws {
        // A stretched item of a single line whose cross size is already known will be as
        // large as the line: measuring it at an unknown cross size would only be thrown away.
        for itemIndex in items.indices {
            if itemIndex > 0 && itemIndex % 256 == 0 { try context.checkpoint() }
            if run.singleLine, let lineCross = run.innerCrossDefinite, items[itemIndex].stretches {
                let item = items[itemIndex]
                items[itemIndex].hypotheticalCross = clamp(
                    lineCross - item.marginsCross,
                    item.minCross,
                    item.maxCross,
                    item.paddingCross
                )
                continue
            }

            if run.singleLine, items[itemIndex].stretches,
                let cross = items[itemIndex].crossForBasis
            {
                // The container's own cross size is still open, but a definite one is at hand
                // (the aspect ratio's, while its content is measured): Chromium stretches the
                // item to it rather than measuring it.
                items[itemIndex].hypotheticalCross = cross
                continue
            }

            items[itemIndex].hypotheticalCross = try hypotheticalCross(
                items[itemIndex],
                axes: run.axes,
                itemParent: run.itemParent,
                innerCrossDefinite: run.innerCrossDefinite,
                availableCross: run.itemsAvailableCross
            )
        }

        // §8.3, §9.4 step 8: items aligned by baseline share the baseline of their line. A
        // column's items have no baseline across the column, so it is synthesized at their
        // cross-start edge: their start edges line up past the largest start margin. In
        // `wrap-reverse` the cross axis runs upwards, so the baseline is kept as a distance
        // from the item's bottom: the group sits at the bottom of its line.
        for itemIndex in items.indices
        where items[itemIndex].align == .baseline && !items[itemIndex].hasAutoCrossMargin {
            guard run.isRow else {
                items[itemIndex].baseline = 0
                continue
            }

            let size = LayoutSize(
                width: items[itemIndex].target,
                height: items[itemIndex].hypotheticalCross
            )
            let fromTop =
                try baseline(items[itemIndex].node, size: size, parent: run.itemParent)
                ?? size.height
            items[itemIndex].baseline = run.axes.reversedCross ? size.height - fromTop : fromTop
        }
    }

    /// In a multi-line column an item that is not stretched takes its width within its line,
    /// not within the container: a wider item in the same line gives it room (Chromium).
    @inline(never)
    private mutating func fitToLines(
        _ run: ContainerRun,
        _ lines: [FlexLine],
        _ items: inout [FlexItem]
    ) throws {
        for line in lines {
            let lineCross = line.items.reduce(0) {
                max($0, items[$1].hypotheticalCross + items[$1].marginsCross)
            }
            for itemIndex in line.items {
                let item = items[itemIndex]
                let room = lineCross - item.marginsCross
                guard !item.stretches, item.sizeCross == nil, item.hypotheticalCross < room
                else { continue }

                items[itemIndex].hypotheticalCross = try hypotheticalCross(
                    item,
                    axes: run.axes,
                    itemParent: run.itemParent,
                    innerCrossDefinite: lineCross,
                    availableCross: .definite(lineCross)
                )
            }
        }
    }

    /// §9.4 steps 8–15, §9.5, §9.6: line cross sizes, used cross sizes and every item's
    /// position in the content box. Returns the container's inner cross size.
    @inline(never)
    private func placeLines(
        _ run: ContainerRun,
        _ lines: inout [FlexLine],
        _ items: inout [FlexItem],
        innerMain: Double
    ) -> Double {
        let axes = run.axes
        let singleLine = run.singleLine

        // §9.4 step 8: cross size of each line.
        for lineIndex in lines.indices {
            var outer = 0.0
            var ascent: Double?
            // A baseline can lie outside the item (content overflowing a smaller box): the
            // distance to it is negative then, and the line is that much shorter.
            var descent = -Double.infinity
            for itemIndex in lines[lineIndex].items {
                let item = items[itemIndex]
                if let baseline = item.baseline {
                    let above = baseline + item.marginCrossStart
                    ascent = max(ascent ?? -.infinity, above)
                    descent = max(descent, item.hypotheticalCross + item.marginsCross - above)
                } else {
                    outer = max(outer, item.hypotheticalCross + item.marginsCross)
                }
            }
            lines[lineIndex].ascent = ascent

            if singleLine, let definite = run.innerCrossDefinite {
                lines[lineIndex].crossSize = definite
            } else {
                lines[lineIndex].crossSize = max(outer, ascent.map { $0 + descent } ?? 0)
                if singleLine {
                    lines[lineIndex].crossSize = max(
                        0,
                        clamp(
                            lines[lineIndex].crossSize + axes.paddingCross,
                            run.minCross,
                            run.maxCross
                        ) - axes.paddingCross
                    )
                }
            }
        }

        // §9.4 step 15 (applied early: stretching needs it): the container's inner cross size.
        // A column's lines side by side are its max-content width, its widest item the
        // min-content one; in a definite space it takes the fit-content width between them.
        let crossGaps = axes.crossGap * Double(max(0, lines.count - 1))
        var crossContent = lines.reduce(0) { $0 + $1.crossSize } + crossGaps
        if !run.isRow, !singleLine, case let .definite(space) = run.itemsAvailableCross {
            let widest = items.reduce(0) { max($0, $1.hypotheticalCross + $1.marginsCross) }
            crossContent = min(crossContent, max(widest, space))
        }
        let innerCross =
            run.innerCrossDefinite
            ?? max(
                0,
                clamp(crossContent + axes.paddingCross, run.minCross, run.maxCross)
                    - axes.paddingCross
            )

        // §9.4 step 9: `align-content: stretch` shares free cross space among the lines of a
        // multi-line container.
        if !singleLine && run.alignContent == .stretch && !lines.isEmpty {
            let free = innerCross - lines.reduce(0) { $0 + $1.crossSize } - crossGaps
            if free > epsilon {
                for lineIndex in lines.indices {
                    lines[lineIndex].crossSize += free / Double(lines.count)
                }
            }
        }

        // §9.4 step 11: used cross size — stretched items fill their line, minus their cross
        // margins, then respect their own min/max cross size.
        for line in lines {
            for itemIndex in line.items {
                let item = items[itemIndex]
                if item.stretches {
                    items[itemIndex].cross = clamp(
                        line.crossSize - item.marginsCross,
                        item.minCross,
                        item.maxCross,
                        item.paddingCross
                    )
                } else {
                    items[itemIndex].cross = item.hypotheticalCross
                }
            }
        }

        // §9.5: main-axis alignment — auto margins first, then `justify-content`.
        for line in lines {
            alignMain(
                line.items,
                &items,
                innerMain: innerMain,
                gap: axes.mainGap,
                justify: run.justifyContent,
                startIsFlexEnd: run.isReverse
            )
        }

        // §9.6: cross-axis alignment — lines by `align-content`, items by auto margins or
        // `align-self` within their line.
        let linesFree = innerCross - lines.reduce(0) { $0 + $1.crossSize } - crossGaps
        let lineOffsets = distribute(
            singleLine ? .start : contentDistribution(run.alignContent),
            free: linesFree,
            count: lines.count,
            gap: axes.crossGap,
            startIsFlexEnd: run.styleWrap == .wrapReverse
        )
        var lineCursor = lineOffsets.offset
        for lineIndex in lines.indices {
            lines[lineIndex].crossPosition = lineCursor
            lineCursor += lines[lineIndex].crossSize + lineOffsets.spacing
            for itemIndex in lines[lineIndex].items {
                items[itemIndex].crossPosition =
                    lines[lineIndex].crossPosition
                    + crossOffset(
                        items[itemIndex],
                        lineCross: lines[lineIndex].crossSize,
                        ascent: lines[lineIndex].ascent
                    )
            }
        }
        return innerCross
    }

    /// Writes the frames of the in-flow items — logical positions become physical x/y in the
    /// content box — and lays each item out in its frame.
    @inline(never)
    private mutating func layoutItems(
        _ run: ContainerRun,
        _ items: [FlexItem],
        origin: LayoutPoint,
        innerMain: Double,
        innerCross: Double
    ) throws {
        let axes = run.axes
        let isRow = axes.isRow
        for itemIndex in items.indices {
            if itemIndex > 0 && itemIndex % 256 == 0 { try context.checkpoint() }
            let frame = itemFrame(
                items[itemIndex],
                run: run,
                origin: origin,
                innerMain: innerMain,
                innerCross: innerCross
            )
            let node = items[itemIndex].node
            frames[node] = frame
            // §9.8: the flexed main size is definite when the container's main size is; a
            // stretched cross size is definite; otherwise only specified sizes are.
            let mainIsDefinite = items[itemIndex].mainIsDefinite
            let crossIsDefinite =
                items[itemIndex].sizeCross != nil || items[itemIndex].stretches
                || (items[itemIndex].ratio != nil && mainIsDefinite)
            // A row item's height that follows from its aspect ratio is left to it: raised to
            // its content, it keeps the ratio's height as its children's percentage base.
            let ratioHeight =
                isRow && items[itemIndex].ratio != nil && items[itemIndex].sizeCross == nil
                && !items[itemIndex].stretches
            _ = try compute(
                node,
                known: OptionalSize(
                    width: frame.size.width,
                    height: ratioHeight ? nil : frame.size.height
                ),
                parent: run.itemParent,
                available: AvailableSize(
                    width: .definite(frame.size.width),
                    height: .definite(frame.size.height)
                ),
                mode: .layout(frame.origin),
                definite: DefiniteAxes(main: mainIsDefinite, cross: crossIsDefinite, isRow: isRow)
            )
        }
    }

    @inline(never)
    private func itemFrame(
        _ item: FlexItem,
        run: ContainerRun,
        origin: LayoutPoint,
        innerMain: Double,
        innerCross: Double
    ) -> LayoutRect {
        let axes = run.axes
        let isRow = axes.isRow
        let main =
            axes.reversedMain ? innerMain - item.mainPosition - item.target : item.mainPosition
        let cross =
            axes.reversedCross ? innerCross - item.crossPosition - item.cross : item.crossPosition
        return LayoutRect(
            x: origin.x + run.own.padding.left + (isRow ? main : cross),
            y: origin.y + run.own.padding.top + (isRow ? cross : main),
            width: isRow ? item.target : item.cross,
            height: isRow ? item.cross : item.target
        )
    }

    /// §8.5: a container's first baseline is that of its first line's first baseline-aligned
    /// item (a row), or else of its first item, offset by where that item sits; a container
    /// without items has none.
    @inline(never)
    private mutating func containerBaseline(
        lines: [FlexLine],
        items: [FlexItem],
        axes: ContainerAxes,
        isReverse: Bool,
        own: OwnSize,
        innerMain: Double,
        innerCross: Double,
        itemParent: OptionalSize
    ) throws -> Double? {
        // The line physically at the top: with `wrap-reverse` lines stack from the bottom,
        // so it is the last one.
        let top = axes.isRow && axes.reversedCross ? lines.last : lines.first
        // In a reversed direction the item that gives the baseline is taken from the end of
        // the line — the one physically first (Chromium).
        guard let line = top,
            let first = isReverse ? line.items.last : line.items.first
        else { return nil }

        let inOrder = isReverse ? Array(line.items.reversed()) : line.items
        let chosen = axes.isRow ? inOrder.first { items[$0].baseline != nil } ?? first : first
        let item = items[chosen]
        let size = LayoutSize(
            width: axes.isRow ? item.target : item.cross,
            height: axes.isRow ? item.cross : item.target
        )
        // `baseline` is the item's text baseline only in a row that is not `wrap-reverse`;
        // otherwise it is the alignment edge the line uses.
        let aligned = axes.isRow && !axes.reversedCross ? item.baseline : nil
        let itemBaseline =
            try aligned ?? baseline(item.node, size: size, parent: itemParent) ?? size.height
        let offset: Double
        if axes.isRow {
            offset =
                axes.reversedCross
                ? innerCross - item.crossPosition - item.cross : item.crossPosition
        } else {
            offset =
                axes.reversedMain ? innerMain - item.mainPosition - item.target : item.mainPosition
        }
        return own.padding.top + offset + itemBaseline
    }

    // MARK: - §9.2 Line length determination

    /// Appends the item of `child` with everything that follows from its style. The sizes
    /// that need a pass over its subtree are left as requests for `measureItem`, so that this
    /// frame, with the whole style in it, is not on the stack while the subtree is solved.
    @inline(never)
    private func appendItem(_ child: Int, run container: ContainerRun, to items: inout [FlexItem]) {
        let axes = container.axes
        let itemParent = container.itemParent
        let availableMain = container.itemsAvailableMain
        let availableCross = container.itemsAvailableCross
        let style = self.style(child, parentWidth: itemParent.width)
        let isRow = axes.isRow
        // Sizes as specified, without transferring the aspect ratio: a size that only follows
        // from the ratio is still `auto`, so the item can be stretched and its ratio applies
        // to the main size through the flex base size instead.
        let own = ownSize(
            child,
            style: style,
            known: OptionalSize(),
            parent: itemParent,
            ratio: .none
        )
        let margin = style.margin.physical(nodes[child].direction)
        let margins = Physical(
            top: margin.top.points,
            left: margin.left.points,
            bottom: margin.bottom.points,
            right: margin.right.points
        )
        let autos = Physical(
            top: margin.top.isAuto,
            left: margin.left.isAuto,
            bottom: margin.bottom.isAuto,
            right: margin.right.isAuto
        )
        let align: AlignSelf =
            switch style.alignSelf {
            case .auto:
                switch container.alignItems {
                case .stretch: .stretch
                case .start: .start
                case .end: .end
                case .center: .center
                case .baseline: .baseline
                }
            default: style.alignSelf
            }
        let sizeMain = isRow ? own.width : own.height
        let sizeCross = isRow ? own.height : own.width
        let minCross = isRow ? own.minHeight : own.minWidth
        let maxCross = isRow ? own.maxHeight : own.maxWidth
        let paddingCross = isRow ? own.paddingHeight : own.paddingWidth
        let autoCross = axes.crossStart(autos) || axes.crossEnd(autos)
        let marginsCross = axes.crossStart(margins) + axes.crossEnd(margins)

        let crossStyle = isRow ? style.height : style.width
        let stretches = align == .stretch && crossStyle == .auto && !autoCross

        // §9.8 / §9.4 step 11: in a single-line container with a definite cross size, a
        // stretched item's cross size is definite before its main size is known.
        var crossForBasis = sizeCross
        if crossForBasis == nil, container.styleWrap == .noWrap,
            let innerCross = isRow ? itemParent.height : itemParent.width,
            stretches
        {
            crossForBasis = clamp(innerCross - marginsCross, minCross, maxCross, paddingCross)
        }

        let ratio = style.aspectRatio.flatMap { $0 > 0 ? (isRow ? $0 : 1 / $0) : nil }
        let basisIsDefinite =
            style.basis.resolve(isRow ? itemParent.width : itemParent.height) != nil
        var item = FlexItem(
            node: child,
            marginMainStart: axes.mainStart(margins),
            marginMainEnd: axes.mainEnd(margins),
            marginCrossStart: axes.crossStart(margins),
            marginCrossEnd: axes.crossEnd(margins),
            autoMainStart: axes.mainStart(autos),
            autoMainEnd: axes.mainEnd(autos),
            autoCrossStart: axes.crossStart(autos),
            autoCrossEnd: axes.crossEnd(autos),
            sizeMain: sizeMain,
            sizeCross: sizeCross,
            minMain: isRow ? own.minWidth : own.minHeight,
            maxMain: isRow ? own.maxWidth : own.maxHeight,
            minCross: minCross,
            maxCross: maxCross,
            paddingMain: isRow ? own.paddingWidth : own.paddingHeight,
            paddingCross: paddingCross,
            grow: max(0, style.grow),
            shrink: max(0, style.shrink),
            align: align,
            stretches: stretches,
            ratio: ratio,
            crossForBasis: crossForBasis,
            basisIsDefinite: basisIsDefinite,
            mainIsDefinite: sizeMain != nil || basisIsDefinite
                || (isRow ? itemParent.width : itemParent.height) != nil
        )
        let measureDefinite = DefiniteAxes(main: false, cross: crossForBasis != nil, isRow: isRow)

        let crossAvailable =
            crossForBasis.map { AvailableSpace.definite($0) }
            ?? availableCross.shrunk(by: marginsCross)

        // §9.2 step 3: the flex base size.
        // When it is the item's max-content size or its specified size, it is never below its
        // automatic minimum.
        var basisCoversMinimum = false
        let percentMainBase = isRow ? itemParent.width : itemParent.height
        let mainStyle = isRow ? style.width : style.height
        if let basis = style.basis.resolve(percentMainBase) {
            item.basis = basis  // A: definite flex-basis
        } else if style.basis == .auto, let size = mainStyle.resolve(percentMainBase) {
            // `flex-basis: auto` uses the main size property, unclamped. A percentage basis
            // that cannot be resolved behaves as `content` instead and skips this.
            item.basis = size
            basisCoversMinimum = true
        } else if let ratio, let cross = crossForBasis {
            item.basis = cross * ratio  // B: aspect ratio with a definite cross size
        } else {
            // C–E: size the item as max-content (min-content under a min-content constraint).
            basisCoversMinimum = true
            item.basisRequest = SizeRequest(
                known: OptionalSize(main: nil, cross: crossForBasis, isRow: isRow),
                parent: itemParent,
                available: AvailableSize(
                    main: availableMain == .minContent ? .minContent : .maxContent,
                    cross: crossAvailable,
                    isRow: isRow
                ),
                definite: measureDefinite
            )
        }

        // §4.5: automatic minimum size — the content size suggestion, capped by the specified
        // size suggestion when there is one. It takes a min-content pass over the item's
        // subtree, so when the base size is never below it, it waits until a line actually
        // shrinks.
        let minMainStyle = isRow ? style.minWidth : style.minHeight
        if minMainStyle == .auto {
            item.minimumRequest = SizeRequest(
                known: OptionalSize(main: nil, cross: crossForBasis, isRow: isRow),
                parent: itemParent,
                available: AvailableSize(main: .minContent, cross: crossAvailable, isRow: isRow),
                definite: measureDefinite
            )
            item.defersMinimum = basisCoversMinimum
        }
        items.append(item)
    }

    /// Runs the size requests of `items[index]` that cannot wait, then fixes its flex base
    /// size and hypothetical main size.
    @inline(never)
    private mutating func measureItem(
        _ items: inout [FlexItem],
        _ index: Int,
        axes: ContainerAxes
    ) throws {
        if let request = items[index].basisRequest {
            let measured = try compute(
                items[index].node,
                known: request.known,
                parent: request.parent,
                available: request.available,
                mode: .size,
                contentOnly: axes.isRow ? .horizontal : .vertical,
                definite: request.definite
            )
            items[index].basis = axes.main(measured)
            items[index].basisRequest = nil
        }
        if !items[index].defersMinimum, let request = items[index].minimumRequest {
            items[index].minMain = try automaticMinimum(
                items[index].node,
                request,
                maxMain: items[index].maxMain,
                sizeMain: items[index].sizeMain,
                axes: axes
            )
            items[index].minimumRequest = nil
        }

        // In a border-box, the flex base size cannot be smaller than the padding.
        let item = items[index]
        items[index].basis = max(item.basis, item.paddingMain)
        items[index].hypotheticalMain = clamp(
            items[index].basis,
            item.minMain,
            item.maxMain,
            item.paddingMain
        )
    }

    /// The automatic minimum main size of item `node`: its min-content size along the main
    /// axis, within its maximum and its specified size.
    @inline(never)
    private mutating func automaticMinimum(
        _ node: Int,
        _ request: SizeRequest,
        maxMain: Double,
        sizeMain: Double?,
        axes: ContainerAxes
    ) throws -> Double {
        let minContent = try compute(
            node,
            known: request.known,
            parent: request.parent,
            available: request.available,
            mode: .size,
            contentOnly: axes.isRow ? .horizontal : .vertical,
            definite: request.definite
        )
        var suggestion = min(axes.main(minContent), maxMain)
        if let specified = sizeMain {
            suggestion = min(suggestion, specified)
        }
        return suggestion
    }

    /// Computes the automatic minimums a line needs: those of its shrinkable items, when the
    /// line overflows. Otherwise no item goes below its base size, and a deferred minimum is
    /// never above it.
    @inline(never)
    private mutating func resolvePendingMinimums(
        _ line: [Int],
        _ items: inout [FlexItem],
        axes: ContainerAxes,
        innerMain: Double,
        gap: Double
    ) throws {
        let gaps = gap * Double(max(0, line.count - 1))
        let hypotheticalSum = line.reduce(0) { $0 + items[$1].outerHypotheticalMain } + gaps
        guard hypotheticalSum > innerMain + epsilon else { return }

        for index in line {
            guard let request = items[index].minimumRequest, items[index].shrink > 0 else {
                continue
            }

            items[index].minMain = try automaticMinimum(
                items[index].node,
                request,
                maxMain: items[index].maxMain,
                sizeMain: items[index].sizeMain,
                axes: axes
            )
            items[index].minimumRequest = nil
        }
    }

    /// An item's width under `constraint` before any clamping: its specified width, else its
    /// min-content or max-content width.
    @inline(never)
    private mutating func rawContribution(
        _ item: FlexItem,
        _ constraint: AvailableSpace,
        axes: ContainerAxes,
        itemParent: OptionalSize
    ) throws -> Double {
        if let specified = item.sizeMain { return specified }

        let measured = try compute(
            item.node,
            known: OptionalSize(main: nil, cross: item.crossForBasis, isRow: axes.isRow),
            parent: itemParent,
            available: AvailableSize(
                main: constraint,
                cross: item.crossForBasis.map { .definite($0) } ?? .maxContent,
                isRow: axes.isRow
            ),
            mode: .size,
            definite: DefiniteAxes(main: false, cross: item.crossForBasis != nil, isRow: axes.isRow)
        )
        return axes.main(measured)
    }

    /// The outer contribution within the item's min/max.
    private func plainContribution(_ item: FlexItem, _ raw: Double) -> Double {
        clamp(raw, item.minMain, item.maxMain, item.paddingMain) + item.marginsMain
    }

    /// The outer contribution of an item with a definite flex-basis that stays at that basis
    /// when it cannot grow (or shrink) towards `raw`.
    private func flexedContribution(_ item: FlexItem, _ raw: Double) -> Double {
        let cannotReach =
            item.basisIsDefinite
            && ((raw > item.basis && item.grow == 0) || (raw < item.basis && item.shrink == 0))
        return plainContribution(item, cannotReach ? item.basis : raw)
    }

    // MARK: - §9.3 Main size determination

    @inline(never)
    private func collectLines(
        _ items: [FlexItem],
        wrap: FlexWrap,
        gap: Double,
        limit: Double?,
        minContent: Bool
    ) -> [FlexLine] {
        guard !items.isEmpty else { return [FlexLine(items: [])] }

        if wrap == .noWrap { return [FlexLine(items: Array(items.indices))] }

        if minContent { return items.indices.map { FlexLine(items: [$0]) } }

        var lines: [FlexLine] = []
        var current: [Int] = []
        var used = 0.0
        for index in items.indices {
            let outer = items[index].outerHypotheticalMain
            let next = current.isEmpty ? outer : used + gap + outer
            if let limit, !current.isEmpty, next > limit + epsilon {
                lines.append(FlexLine(items: current))
                current = [index]
                used = outer
            } else {
                current.append(index)
                used = next
            }
        }
        lines.append(FlexLine(items: current))
        return lines
    }

    @inline(never)
    private func lineOuterHypothetical(_ line: FlexLine, _ items: [FlexItem], gap: Double) -> Double
    {
        line.items.reduce(0) { $0 + items[$1].outerHypotheticalMain } + gap
            * Double(max(0, line.items.count - 1))
    }

    // MARK: - §9.7 Resolving flexible lengths

    @inline(never)
    private func resolveFlexibleLengths(
        _ line: [Int],
        _ items: inout [FlexItem],
        innerMain: Double,
        gap: Double
    ) {
        guard !line.isEmpty else { return }

        let gaps = gap * Double(line.count - 1)
        // Step 1: grow when the hypothetical sizes leave space, shrink otherwise.
        let hypotheticalSum = line.reduce(0) { $0 + items[$1].outerHypotheticalMain } + gaps
        let growing = hypotheticalSum < innerMain

        // Step 2: freeze inflexible items at their hypothetical size.
        for index in line {
            let item = items[index]
            let factor = growing ? item.grow : item.shrink
            let inflexible =
                factor == 0
                || (growing && item.basis > item.hypotheticalMain)
                || (!growing && item.basis < item.hypotheticalMain)
            items[index].frozen = inflexible
            items[index].target = inflexible ? item.hypotheticalMain : item.basis
        }

        // Step 3: initial free space.
        func freeSpace() -> Double {
            innerMain - gaps
                - line.reduce(0) { sum, index in
                    let item = items[index]
                    return sum + (item.frozen ? item.target : item.basis) + item.marginsMain
                }
        }
        let initialFree = freeSpace()

        // Step 4: loop until every item is frozen.
        for _ in 0...line.count {
            let unfrozen = line.filter { !items[$0].frozen }
            if unfrozen.isEmpty { break }

            var remaining = freeSpace()
            let factorSum = unfrozen.reduce(0) {
                $0 + (growing ? items[$1].grow : items[$1].shrink)
            }
            if factorSum < 1 {
                let scaled = initialFree * factorSum
                if abs(scaled) < abs(remaining) { remaining = scaled }
            }

            if abs(remaining) > epsilon {
                if growing {
                    for index in unfrozen {
                        items[index].target =
                            items[index].basis + remaining * items[index].grow / factorSum
                    }
                } else {
                    // Shrinking is weighted by the inner (content-box) flex base size.
                    let scaled = unfrozen.map {
                        items[$0].shrink * max(0, items[$0].basis - items[$0].paddingMain)
                    }
                    let scaledSum = scaled.reduce(0, +)
                    for (offset, index) in unfrozen.enumerated() {
                        items[index].target =
                            scaledSum > 0
                            ? items[index].basis + remaining * scaled[offset] / scaledSum
                            : items[index].basis
                    }
                }
            } else {
                for index in unfrozen {
                    items[index].target = items[index].basis
                }
            }

            // Fix min/max violations and freeze accordingly.
            var totalViolation = 0.0
            var violations: [Int: Double] = [:]
            for index in unfrozen {
                let item = items[index]
                let clamped = clamp(item.target, item.minMain, item.maxMain, item.paddingMain)
                violations[index] = clamped - item.target
                totalViolation += clamped - item.target
                items[index].target = clamped
            }

            for index in unfrozen {
                let violation = violations[index] ?? 0
                if abs(totalViolation) <= epsilon
                    || (totalViolation > 0 && violation > epsilon)
                    || (totalViolation < 0 && violation < -epsilon)
                {
                    items[index].frozen = true
                }
            }
        }
    }

    // MARK: - §9.4 Cross size determination

    @inline(never)
    private mutating func hypotheticalCross(
        _ item: FlexItem,
        axes: ContainerAxes,
        itemParent: OptionalSize,
        innerCrossDefinite: Double?,
        availableCross: AvailableSpace
    ) throws -> Double {
        if let size = item.sizeCross { return size }

        let crossAvailable =
            innerCrossDefinite.map { AvailableSpace.definite(max(0, $0 - item.marginsCross)) }
            ?? availableCross.shrunk(by: item.marginsCross)

        if !axes.isRow, innerCrossDefinite == nil, item.ratio != nil {
            // While a column's width is still its content's, only a specified height is a
            // base for a width through an item's aspect ratio — not its flexed height: without
            // one the item contributes its content's width (Chromium).
            let measured = try compute(
                item.node,
                known: OptionalSize(width: nil, height: item.sizeMain),
                parent: itemParent,
                available: AvailableSize(width: crossAvailable, height: .maxContent),
                mode: .size,
                contentOnly: .horizontal,
                definite: DefiniteAxes(width: false, height: false)
            )
            return clamp(measured.width, item.minCross, item.maxCross, item.paddingCross)
        }
        let measured = try compute(
            item.node,
            known: OptionalSize(main: item.target, cross: nil, isRow: axes.isRow),
            parent: itemParent,
            available: AvailableSize(
                main: .definite(item.target),
                cross: crossAvailable,
                isRow: axes.isRow
            ),
            mode: .size,
            definite: DefiniteAxes(main: item.mainIsDefinite, cross: false, isRow: axes.isRow)
        )
        return clamp(axes.cross(measured), item.minCross, item.maxCross, item.paddingCross)
    }

    // MARK: - §9.5 Main-axis alignment

    @inline(never)
    private func alignMain(
        _ line: [Int],
        _ items: inout [FlexItem],
        innerMain: Double,
        gap: Double,
        justify: JustifyContent,
        startIsFlexEnd: Bool
    ) {
        guard !line.isEmpty else { return }

        let used = line.reduce(0) { $0 + items[$1].outerTarget } + gap * Double(line.count - 1)
        let free = innerMain - used
        let autoMargins = line.reduce(0) { count, index in
            count + (items[index].autoMainStart ? 1 : 0) + (items[index].autoMainEnd ? 1 : 0)
        }

        var cursor: Double
        var spacing = gap
        var autoMargin = 0.0
        if free > epsilon && autoMargins > 0 {
            autoMargin = free / Double(autoMargins)
            cursor = 0
        } else {
            let distribution = distribute(
                justifyDistribution(justify),
                free: free,
                count: line.count,
                gap: gap,
                startIsFlexEnd: startIsFlexEnd
            )
            cursor = distribution.offset
            spacing = distribution.spacing
        }

        for index in line {
            let item = items[index]
            cursor += item.marginMainStart + (item.autoMainStart ? autoMargin : 0)
            items[index].mainPosition = cursor
            cursor +=
                item.target + item.marginMainEnd + (item.autoMainEnd ? autoMargin : 0) + spacing
        }
    }

    // MARK: - §9.6 Cross-axis alignment

    @inline(never)
    private func crossOffset(_ item: FlexItem, lineCross: Double, ascent: Double?) -> Double {
        if let baseline = item.baseline, let ascent {
            return ascent - baseline
        }

        let free = lineCross - item.cross - item.marginsCross
        if item.hasAutoCrossMargin {
            guard free > epsilon else { return item.marginCrossStart }

            switch (item.autoCrossStart, item.autoCrossEnd) {
            case (true, true): return item.marginCrossStart + free / 2
            case (true, false): return item.marginCrossStart + free
            default: return item.marginCrossStart
            }
        }

        switch item.align {
        case .end: return item.marginCrossStart + free
        case .center: return item.marginCrossStart + free / 2
        case .auto, .stretch, .start, .baseline: return item.marginCrossStart
        }
    }
}

// MARK: - Distribution of free space (§8.2, §8.4)

enum Distribution {
    case start
    case end
    case center
    case spaceBetween
    case spaceAround
    case spaceEvenly
}

func justifyDistribution(_ value: JustifyContent) -> Distribution {
    switch value {
    case .start: .start
    case .end: .end
    case .center: .center
    case .spaceBetween: .spaceBetween
    case .spaceAround: .spaceAround
    case .spaceEvenly: .spaceEvenly
    }
}

func contentDistribution(_ value: AlignContent) -> Distribution {
    switch value {
    case .stretch, .start: .start
    case .end: .end
    case .center: .center
    case .spaceBetween: .spaceBetween
    case .spaceAround: .spaceAround
    case .spaceEvenly: .spaceEvenly
    }
}

/// Where the first of `count` boxes starts and the spacing between them, for `free` space
/// left over (negative when they overflow). Offsets are measured from the flex-start side.
///
/// With negative free space the distributed values fall back as CSS Box Alignment §5.1 says:
/// `space-between` to flex-start, and `space-around` / `space-evenly` to *safe* center, which
/// with not enough room aligns to the *writing-mode* start of the axis. That start is the
/// flex-end side when the axis is reversed by `row-reverse`/`column-reverse` (main axis) or
/// `wrap-reverse` (cross axis) — `startIsFlexEnd`. Plain `center` and `end` are not safe.
@inline(never)
func distribute(
    _ mode: Distribution,
    free: Double,
    count: Int,
    gap: Double,
    startIsFlexEnd: Bool
) -> (offset: Double, spacing: Double) {
    guard count > 0 else { return (0, gap) }

    let n = Double(count)
    switch mode {
    case .start:
        return (0, gap)
    case .end:
        return (free, gap)
    case .center:
        return (free / 2, gap)
    case .spaceBetween:
        guard free > 0, count > 1 else { return (0, gap) }

        return (0, gap + free / (n - 1))
    case .spaceAround:
        guard free > 0 else { return (startIsFlexEnd ? free : 0, gap) }

        return (free / n / 2, gap + free / n)
    case .spaceEvenly:
        guard free > 0 else { return (startIsFlexEnd ? free : 0, gap) }

        return (free / (n + 1), gap + free / (n + 1))
    }
}
