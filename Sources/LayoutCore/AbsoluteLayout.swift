// Absolutely positioned children of a flex container (CSS Flexbox §4.1, CSS Position §4–5).
// Every node is a positioned box, so the containing block of an absolute child is its
// parent's padding box. Absolute children never affect their parent's size.

extension Solver {
    @inline(never)
    mutating func layoutAbsoluteChildren(
        _ run: ContainerRun,
        size: LayoutSize,
        origin: LayoutPoint,
        innerMain: Double,
        innerCross: Double
    ) throws {
        let index = run.index
        let own = run.own
        let axes = run.axes
        let containingBlock = OptionalSize(width: size.width, height: size.height)
        let direction = nodes[index].direction

        for child in nodes[index].children {
            if nodes[child].variants.isEmpty && nodes[child].style.position != .absolute {
                continue
            }

            let style = self.style(child, parentWidth: size.width)
            guard style.position == .absolute, style.display != .none else { continue }

            let childOwn = ownSize(
                child,
                style: style,
                known: OptionalSize(),
                parent: containingBlock,
                ratio: .none
            )
            let margin = style.margin.physical(nodes[child].direction)
            var margins = Physical(
                top: margin.top.points,
                left: margin.left.points,
                bottom: margin.bottom.points,
                right: margin.right.points
            )
            let insets = style.insets.physical(nodes[child].direction)
            // CSS Align §5.1 as Chromium has it: pinned by `top` and `bottom`, a box with an
            // `align-self` other than `auto`/`stretch` is not stretched between them but sized
            // by its content and aligned in the space they leave — vertically in any flex
            // direction, `flex-start` at the top even in `wrap-reverse`.
            let verticalAlignment: AlignSelf? =
                insets.top != nil && insets.bottom != nil
                    && style.alignSelf != .auto && style.alignSelf != .stretch
                ? style.alignSelf : nil

            // Size: specified, else stretched between two insets, else shrink-to-fit.
            var width = childOwn.width
            if width == nil, let left = insets.left, let right = insets.right {
                width = clamp(
                    size.width - left - right - margins.left - margins.right,
                    childOwn.minWidth,
                    childOwn.maxWidth,
                    childOwn.paddingWidth
                )
            }

            var height = childOwn.height
            if height == nil, verticalAlignment == nil, let top = insets.top,
                let bottom = insets.bottom
            {
                height = clamp(
                    size.height - top - bottom - margins.top - margins.bottom,
                    childOwn.minHeight,
                    childOwn.maxHeight,
                    childOwn.paddingHeight
                )
            }

            // With an aspect ratio Chromium settles the width first: specified — but, when the
            // height is specified too and the minimum is `auto`, not below the content's
            // min-content width — or between two
            // insets, or through the ratio from a height (specified or between two insets).
            // The height then follows from the width through the ratio, raised to the
            // content, unless it is specified: insets no longer stretch it.
            let hasRatio = (style.aspectRatio ?? 0) > 0
            if hasRatio {
                let insetHeight = childOwn.height == nil ? height : nil
                height = childOwn.height
                if let specified = childOwn.width, childOwn.height != nil,
                    style.minWidth == .auto
                {
                    let minContent = try minContentWidth(child, parent: containingBlock)
                    width = max(specified, min(minContent, childOwn.maxWidth))
                } else if width == nil, let base = height ?? insetHeight {
                    width =
                        try compute(
                            child,
                            known: OptionalSize(width: nil, height: base),
                            parent: containingBlock,
                            available: AvailableSize(width: .maxContent, height: .definite(base)),
                            mode: .size
                        )
                        .width
                }
            }

            if width == nil || height == nil {
                // Without horizontal insets the box starts at its static position, inside the
                // parent's padding on the start side: that padding is not space it can take.
                let staticStart =
                    insets.left == nil && insets.right == nil
                    ? (direction == .rightToLeft ? own.padding.right : own.padding.left) : 0
                let availableWidth =
                    size.width - (insets.left ?? 0) - (insets.right ?? 0) - staticStart
                    - margins.left - margins.right
                let availableHeight =
                    size.height - (insets.top ?? 0) - (insets.bottom ?? 0) - margins.top
                    - margins.bottom
                let measured = try compute(
                    child,
                    known: OptionalSize(width: width, height: height),
                    parent: containingBlock,
                    available: AvailableSize(
                        width: .definite(max(0, availableWidth)),
                        height: .definite(max(0, availableHeight))
                    ),
                    mode: .size
                )
                width = width ?? measured.width
                height = height ?? measured.height
            }

            let childSize = LayoutSize(width: width ?? 0, height: height ?? 0)
            // A height is definite when it is specified or pinned by both insets; a
            // shrink-to-fit height comes from the content, like an auto height anywhere.
            let heightIsDefinite =
                childOwn.height != nil || hasRatio
                || (insets.top != nil && insets.bottom != nil && verticalAlignment == nil)

            // Auto margins of a box pinned by both insets take what is left, even when that is
            // negative; horizontally a negative remainder goes to the end margin.
            if let left = insets.left, let right = insets.right {
                let remaining =
                    size.width - left - right - childSize.width - margins.left - margins.right
                switch (margin.left.isAuto, margin.right.isAuto) {
                case (true, true):
                    if remaining >= 0 {
                        margins.left += remaining / 2
                        margins.right += remaining / 2
                    } else if direction == .rightToLeft {
                        margins.left += remaining
                    } else {
                        margins.right += remaining
                    }
                case (true, false): margins.left += remaining
                case (false, true): margins.right += remaining
                case (false, false): break
                }
            }
            if let top = insets.top, let bottom = insets.bottom {
                let remaining =
                    size.height - top - bottom - childSize.height - margins.top - margins.bottom
                switch (margin.top.isAuto, margin.bottom.isAuto) {
                case (true, true):
                    margins.top += remaining / 2
                    margins.bottom += remaining / 2
                case (true, false): margins.top += remaining
                case (false, true): margins.bottom += remaining
                case (false, false): break
                }
            }
            let staticPosition = absoluteStaticPosition(
                child,
                size: childSize,
                childStyle: style,
                margins: margins,
                container: run,
                own: own,
                axes: axes,
                innerMain: innerMain,
                innerCross: innerCross
            )

            // Over-constrained (both insets and a width): the end inset gives way — `right` in
            // left-to-right, `left` in right-to-left.
            let x: Double
            if let left = insets.left, insets.right == nil || direction == .leftToRight {
                x = left + margins.left
            } else if let right = insets.right {
                x = size.width - right - margins.right - childSize.width
            } else {
                x = staticPosition.x
            }

            let y: Double
            if style.alignSelf != .auto, let top = insets.top, let bottom = insets.bottom,
                !margin.top.isAuto, !margin.bottom.isAuto
            {
                // Aligned — `stretch` of a box that has a height too, at the start — and then,
                // unlike a box placed by `top` alone, kept inside the containing block where
                // it overflows the space between the insets, its top edge first.
                let start = top + margins.top
                let end = size.height - bottom - margins.bottom - childSize.height
                let aligned =
                    switch style.alignSelf {
                    case .end: end
                    case .center: (start + end) / 2
                    case .auto, .stretch, .start, .baseline: start
                    }
                y = max(0, min(aligned, size.height - childSize.height))
            } else if let top = insets.top {
                y = top + margins.top
            } else if let bottom = insets.bottom {
                y = size.height - bottom - margins.bottom - childSize.height
            } else {
                y = staticPosition.y
            }

            let frame = LayoutRect(
                origin: LayoutPoint(x: origin.x + x, y: origin.y + y),
                size: childSize
            )
            frames[child] = frame
            // A height that follows from the ratio is left to the child, so that it keeps the
            // ratio's height as its children's percentage base when raised to its content.
            _ = try compute(
                child,
                known: OptionalSize(
                    width: childSize.width,
                    height: hasRatio && childOwn.height == nil ? nil : childSize.height
                ),
                parent: containingBlock,
                available: AvailableSize(
                    width: .definite(childSize.width),
                    height: .definite(childSize.height)
                ),
                mode: .layout(frame.origin),
                definite: DefiniteAxes(width: true, height: heightIsDefinite)
            )
        }
    }

    /// The narrowest width `index` takes by its content, without its own sizes or ratio.
    @inline(never)
    private mutating func minContentWidth(_ index: Int, parent: OptionalSize) throws -> Double {
        guard nodes[index].children.isEmpty else {
            return try flexLayout(
                index,
                known: OptionalSize(),
                parent: parent,
                available: AvailableSize(width: .minContent, height: .maxContent),
                mode: .size,
                contentOnly: .horizontal,
                definite: DefiniteAxes(width: false, height: false),
                ratio: .none
            )
            .width
        }

        let own = ownSize(
            index,
            known: OptionalSize(),
            parent: parent,
            contentOnly: .horizontal,
            ratio: .none
        )
        return (nodes[index].content?.minContentWidth ?? 0) + own.paddingWidth
    }

    /// §4.1: the static position of an absolute child is where it would be as the sole flex
    /// item of its parent — placed by `justify-content` and `align-self` in the content box.
    @inline(never)
    private func absoluteStaticPosition(
        _ child: Int,
        size: LayoutSize,
        childStyle: FlexStyle,
        margins: Physical<Double>,
        container: ContainerRun,
        own: OwnSize,
        axes: ContainerAxes,
        innerMain: Double,
        innerCross: Double
    ) -> LayoutPoint {
        let childMain = axes.main(size)
        let childCross = axes.cross(size)
        let marginMainStart = axes.mainStart(margins)
        let marginCrossStart = axes.crossStart(margins)
        let freeMain = innerMain - childMain - marginMainStart - axes.mainEnd(margins)
        let freeCross = innerCross - childCross - marginCrossStart - axes.crossEnd(margins)

        // A sole item: `space-between` packs at the start, `space-around`/`space-evenly`
        // center it — without the safe fallback that applies to lines of in-flow items.
        let mainOffset: Double =
            switch container.justifyContent {
            case .start, .spaceBetween: 0
            case .end: freeMain
            case .center, .spaceAround, .spaceEvenly: freeMain / 2
            }
        let alignment: AlignItems =
            switch childStyle.alignSelf {
            case .auto: container.alignItems
            case .stretch: .stretch
            case .start: .start
            case .end: .end
            case .center: .center
            case .baseline: .baseline
            }
        // A sole item has no baseline to share: it falls back to the start of the writing
        // mode, which `wrap-reverse` does not turn over.
        let crossOffset: Double =
            switch alignment {
            case .end: freeCross
            case .center: freeCross / 2
            case .stretch, .start: 0
            case .baseline: container.styleWrap == .wrapReverse ? freeCross : 0
            }

        let mainLogical = mainOffset + marginMainStart
        let crossLogical = crossOffset + marginCrossStart
        let main = axes.reversedMain ? innerMain - mainLogical - childMain : mainLogical
        let cross = axes.reversedCross ? innerCross - crossLogical - childCross : crossLogical
        return LayoutPoint(
            x: own.padding.left + (axes.isRow ? main : cross),
            y: own.padding.top + (axes.isRow ? cross : main)
        )
    }
}
