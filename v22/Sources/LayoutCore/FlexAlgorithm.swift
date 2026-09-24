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
    let maxMain: Double
    let minCross: Double
    let maxCross: Double
    let paddingMain: Double
    let paddingCross: Double
    let grow: Double
    let shrink: Double
    let align: AlignSelf
    /// Main size per point of cross size, from `aspect-ratio`.
    let ratio: Double?
    /// Cross size already known while the flex base size is determined (§9.2 step 3, §9.8).
    let crossForBasis: Double?

    var basis = 0.0
    var hypotheticalMain = 0.0
    var target = 0.0
    var frozen = false
    var hypotheticalCross = 0.0
    var cross = 0.0
    var mainPosition = 0.0
    var crossPosition = 0.0

    var marginsMain: Double { marginMainStart + marginMainEnd }
    var marginsCross: Double { marginCrossStart + marginCrossEnd }
    var outerHypotheticalMain: Double { hypotheticalMain + marginsMain }
    var outerTarget: Double { target + marginsMain }
    var hasAutoCrossMargin: Bool { autoCrossStart || autoCrossEnd }
}

struct FlexLine {
    var items: [Int]
    var crossSize = 0.0
    var crossPosition = 0.0
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

extension Solver {
    mutating func flexLayout(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        mode: RunMode,
        contentOnly: Bool = false
    ) throws -> LayoutSize {
        try context.checkpoint()
        let node = nodes[index]
        let style = node.style
        let own = ownSize(index, known: known, parent: parent, contentOnly: contentOnly)
        let axes = ContainerAxes(style: style, direction: node.direction, own: own)
        let isRow = axes.isRow
        let ownMain = isRow ? own.width : own.height
        let ownCross = isRow ? own.height : own.width
        let minMain = isRow ? own.minWidth : own.minHeight
        let maxMain = isRow ? own.maxWidth : own.maxHeight
        let minCross = isRow ? own.minHeight : own.minWidth
        let maxCross = isRow ? own.maxHeight : own.maxWidth

        // §9.2 step 2: the space available to the items — the content box when the container
        // size is definite, otherwise the space offered to the container minus its padding.
        let innerMainDefinite = ownMain.map { max(0, $0 - axes.paddingMain) }
        let innerCrossDefinite = ownCross.map { max(0, $0 - axes.paddingCross) }
        let itemsAvailableMain =
            innerMainDefinite.map { AvailableSpace.definite($0) }
            ?? (isRow ? available.width : available.height).shrunk(by: axes.paddingMain)
        let itemsAvailableCross =
            innerCrossDefinite.map { AvailableSpace.definite($0) }
            ?? (isRow ? available.height : available.width).shrunk(by: axes.paddingCross)
        // The containing block of the items for percentages: the content box, if definite.
        let itemParent = OptionalSize(
            main: innerMainDefinite,
            cross: innerCrossDefinite,
            isRow: isRow
        )

        // §9.1, §5.4: in-flow children in `order`, document order breaking ties.
        let flowChildren = node.children.enumerated()
            .filter { nodes[$0.element].style.position != .absolute }
            .sorted { lhs, rhs in
                let left = nodes[lhs.element].style.order
                let right = nodes[rhs.element].style.order
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)

        var items: [FlexItem] = []
        items.reserveCapacity(flowChildren.count)
        for (offset, child) in flowChildren.enumerated() {
            if offset > 0 && offset % 256 == 0 { try context.checkpoint() }
            items.append(
                try makeItem(
                    child,
                    container: style,
                    axes: axes,
                    itemParent: itemParent,
                    innerMainDefinite: innerMainDefinite,
                    innerCrossDefinite: innerCrossDefinite,
                    availableMain: itemsAvailableMain,
                    availableCross: itemsAvailableCross
                )
            )
        }

        // §9.3: collect items into flex lines.
        var lines = collectLines(
            items,
            wrap: style.wrap,
            gap: axes.mainGap,
            limit: innerMainDefinite ?? itemsAvailableMain.definiteValue,
            minContent: innerMainDefinite == nil && itemsAvailableMain == .minContent
        )

        // §9.2 step 4 / §9.3: the container's inner main size.
        let innerMain: Double
        if let definite = innerMainDefinite {
            innerMain = definite
        } else {
            var content =
                lines.map { lineOuterHypothetical($0, items, gap: axes.mainGap) }.max() ?? 0
            if case let .definite(space) = itemsAvailableMain, content > space + epsilon {
                // Fit-content: never narrower than the min-content size.
                let minContent = try compute(
                    index,
                    known: known,
                    parent: parent,
                    available: AvailableSize(
                        main: .minContent,
                        cross: isRow ? available.height : available.width,
                        isRow: isRow
                    ),
                    mode: .size,
                    contentOnly: contentOnly
                )
                content = max(axes.main(minContent) - axes.paddingMain, space)
            }
            innerMain = max(
                0,
                clamp(content + axes.paddingMain, minMain, maxMain) - axes.paddingMain
            )
        }

        // §9.7: resolve flexible lengths, line by line.
        for line in lines {
            resolveFlexibleLengths(line.items, &items, innerMain: innerMain, gap: axes.mainGap)
        }

        // §9.4 step 7: hypothetical cross size of each item.
        for itemIndex in items.indices {
            items[itemIndex].hypotheticalCross = try hypotheticalCross(
                items[itemIndex],
                axes: axes,
                itemParent: itemParent,
                innerCrossDefinite: innerCrossDefinite,
                availableCross: itemsAvailableCross
            )
        }

        // §9.4 step 8: cross size of each line.
        let singleLine = style.wrap == .noWrap
        for lineIndex in lines.indices {
            if singleLine, let definite = innerCrossDefinite {
                lines[lineIndex].crossSize = definite
            } else {
                lines[lineIndex].crossSize =
                    lines[lineIndex].items.map {
                        items[$0].hypotheticalCross + items[$0].marginsCross
                    }.max() ?? 0
                if singleLine {
                    lines[lineIndex].crossSize = max(
                        0,
                        clamp(lines[lineIndex].crossSize + axes.paddingCross, minCross, maxCross)
                            - axes.paddingCross
                    )
                }
            }
        }

        // §9.4 step 15 (applied early: stretching needs it): the container's inner cross size.
        let crossGaps = axes.crossGap * Double(max(0, lines.count - 1))
        let innerCross =
            innerCrossDefinite
            ?? max(
                0,
                clamp(
                    lines.reduce(0) { $0 + $1.crossSize } + crossGaps + axes.paddingCross,
                    minCross,
                    maxCross
                )
                    - axes.paddingCross
            )

        // §9.4 step 9: `align-content: stretch` shares free cross space among the lines of a
        // multi-line container.
        if !singleLine && style.alignContent == .stretch && !lines.isEmpty {
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
                if item.align == .stretch && item.sizeCross == nil && !item.hasAutoCrossMargin {
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
                justify: style.justifyContent
            )
        }

        // §9.6: cross-axis alignment — lines by `align-content`, items by auto margins or
        // `align-self` within their line.
        let lineOffsets = distribute(
            singleLine ? .start : contentDistribution(style.alignContent),
            free: innerCross - lines.reduce(0) { $0 + $1.crossSize } - crossGaps,
            count: lines.count,
            gap: axes.crossGap
        )
        var lineCursor = lineOffsets.offset
        for lineIndex in lines.indices {
            lines[lineIndex].crossPosition = lineCursor
            lineCursor += lines[lineIndex].crossSize + lineOffsets.spacing
            for itemIndex in lines[lineIndex].items {
                items[itemIndex].crossPosition =
                    lines[lineIndex].crossPosition
                    + crossOffset(items[itemIndex], lineCross: lines[lineIndex].crossSize)
            }
        }

        let size = LayoutSize(
            width: isRow ? innerMain + axes.paddingMain : innerCross + axes.paddingCross,
            height: isRow ? innerCross + axes.paddingCross : innerMain + axes.paddingMain
        )
        let result = LayoutSize(width: own.width ?? size.width, height: own.height ?? size.height)

        guard case let .layout(origin) = mode else { return result }

        // Write frames: logical positions become physical x/y in the content box.
        for item in items {
            let main =
                axes.reversedMain ? innerMain - item.mainPosition - item.target : item.mainPosition
            let cross =
                axes.reversedCross
                ? innerCross - item.crossPosition - item.cross : item.crossPosition
            let frame = LayoutRect(
                x: origin.x + own.padding.left + (isRow ? main : cross),
                y: origin.y + own.padding.top + (isRow ? cross : main),
                width: isRow ? item.target : item.cross,
                height: isRow ? item.cross : item.target
            )
            frames[item.node] = frame
            _ = try compute(
                item.node,
                known: OptionalSize(width: frame.size.width, height: frame.size.height),
                parent: itemParent,
                available: AvailableSize(
                    width: .definite(frame.size.width),
                    height: .definite(frame.size.height)
                ),
                mode: .layout(frame.origin)
            )
        }

        try layoutAbsoluteChildren(
            index,
            size: result,
            origin: origin,
            own: own,
            axes: axes,
            innerMain: innerMain,
            innerCross: innerCross
        )
        return result
    }

    // MARK: - §9.2 Line length determination

    private mutating func makeItem(
        _ child: Int,
        container: FlexStyle,
        axes: ContainerAxes,
        itemParent: OptionalSize,
        innerMainDefinite: Double?,
        innerCrossDefinite: Double?,
        availableMain: AvailableSpace,
        availableCross: AvailableSpace
    ) throws -> FlexItem {
        let node = nodes[child]
        let style = node.style
        let isRow = axes.isRow
        let own = ownSize(child, known: OptionalSize(), parent: itemParent)
        let margin = style.margin.physical(node.direction)
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

        // §9.8 / §9.4 step 11: in a single-line container with a definite cross size, a
        // stretched item's cross size is definite before its main size is known.
        var crossForBasis = sizeCross
        if crossForBasis == nil, container.wrap == .noWrap, let innerCross = innerCrossDefinite,
            align == .stretch, !autoCross
        {
            crossForBasis = clamp(innerCross - marginsCross, minCross, maxCross, paddingCross)
        }

        let ratio = style.aspectRatio.flatMap { $0 > 0 ? (isRow ? $0 : 1 / $0) : nil }
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
            ratio: ratio,
            crossForBasis: crossForBasis
        )

        let crossAvailable =
            crossForBasis.map { AvailableSpace.definite($0) }
            ?? availableCross.shrunk(by: marginsCross)

        // §9.2 step 3: the flex base size.
        if let basis = style.basis.resolve(innerMainDefinite) {
            item.basis = basis  // A: definite flex-basis
        } else if let size = sizeMain {
            item.basis = size  // `flex-basis: auto` uses the main size property
        } else if let ratio, let cross = crossForBasis {
            item.basis = cross * ratio  // B: aspect ratio with a definite cross size
        } else {
            // C–E: size the item as max-content (min-content under a min-content constraint).
            let measured = try compute(
                child,
                known: OptionalSize(main: nil, cross: crossForBasis, isRow: isRow),
                parent: itemParent,
                available: AvailableSize(
                    main: availableMain == .minContent ? .minContent : .maxContent,
                    cross: crossAvailable,
                    isRow: isRow
                ),
                mode: .size
            )
            item.basis = axes.main(measured)
        }

        // §4.5: automatic minimum size — the content size suggestion, capped by the specified
        // size suggestion (or the ratio-transferred one) when there is one.
        let minMainStyle = isRow ? style.minWidth : style.minHeight
        if minMainStyle == .auto {
            let minContent = try compute(
                child,
                known: OptionalSize(main: nil, cross: crossForBasis, isRow: isRow),
                parent: itemParent,
                available: AvailableSize(main: .minContent, cross: crossAvailable, isRow: isRow),
                mode: .size,
                contentOnly: true
            )
            var suggestion = min(axes.main(minContent), item.maxMain)
            if let specified = sizeMain {
                suggestion = min(suggestion, specified)
            } else if let ratio, let cross = crossForBasis {
                suggestion = min(suggestion, cross * ratio)
            }
            item.minMain = suggestion
        }

        item.hypotheticalMain = clamp(item.basis, item.minMain, item.maxMain, item.paddingMain)
        return item
    }

    // MARK: - §9.3 Main size determination

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

    private func lineOuterHypothetical(_ line: FlexLine, _ items: [FlexItem], gap: Double) -> Double
    {
        line.items.reduce(0) { $0 + items[$1].outerHypotheticalMain } + gap
            * Double(max(0, line.items.count - 1))
    }

    // MARK: - §9.7 Resolving flexible lengths

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

    private mutating func hypotheticalCross(
        _ item: FlexItem,
        axes: ContainerAxes,
        itemParent: OptionalSize,
        innerCrossDefinite: Double?,
        availableCross: AvailableSpace
    ) throws -> Double {
        if let size = item.sizeCross { return size }

        if let ratio = item.ratio {
            return clamp(item.target / ratio, item.minCross, item.maxCross, item.paddingCross)
        }

        let crossAvailable =
            innerCrossDefinite.map { AvailableSpace.definite(max(0, $0 - item.marginsCross)) }
            ?? availableCross.shrunk(by: item.marginsCross)
        let measured = try compute(
            item.node,
            known: OptionalSize(main: item.target, cross: nil, isRow: axes.isRow),
            parent: itemParent,
            available: AvailableSize(
                main: .definite(item.target),
                cross: crossAvailable,
                isRow: axes.isRow
            ),
            mode: .size
        )
        return clamp(axes.cross(measured), item.minCross, item.maxCross, item.paddingCross)
    }

    // MARK: - §9.5 Main-axis alignment

    private func alignMain(
        _ line: [Int],
        _ items: inout [FlexItem],
        innerMain: Double,
        gap: Double,
        justify: JustifyContent
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
                gap: gap
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

    private func crossOffset(_ item: FlexItem, lineCross: Double) -> Double {
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
/// left over (negative when they overflow). Negative free space falls back as CSS Flexbox §8.2
/// and §8.4 say: `space-between` to start, `space-around`/`space-evenly` to center.
func distribute(_ mode: Distribution, free: Double, count: Int, gap: Double) -> (
    offset: Double, spacing: Double
) {
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
        guard free > 0 else { return (free / 2, gap) }

        return (free / n / 2, gap + free / n)
    case .spaceEvenly:
        guard free > 0 else { return (free / 2, gap) }

        return (free / (n + 1), gap + free / (n + 1))
    }
}
