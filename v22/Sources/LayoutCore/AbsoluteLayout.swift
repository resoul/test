// Absolutely positioned children of a flex container (CSS Flexbox §4.1, CSS Position §4–5).
// Every node is a positioned box, so the containing block of an absolute child is its
// parent's padding box. Absolute children never affect their parent's size.

extension Solver {
    mutating func layoutAbsoluteChildren(
        _ index: Int,
        size: LayoutSize,
        origin: LayoutPoint,
        own: OwnSize,
        axes: ContainerAxes,
        innerMain: Double,
        innerCross: Double
    ) throws {
        let node = nodes[index]
        let containingBlock = OptionalSize(width: size.width, height: size.height)

        for child in node.children where nodes[child].style.position == .absolute {
            let childNode = nodes[child]
            let style = childNode.style
            let childOwn = ownSize(child, known: OptionalSize(), parent: containingBlock)
            let margin = style.margin.physical(childNode.direction)
            var margins = Physical(
                top: margin.top.points,
                left: margin.left.points,
                bottom: margin.bottom.points,
                right: margin.right.points
            )
            let insets = style.insets.physical(childNode.direction)

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
            if height == nil, let top = insets.top, let bottom = insets.bottom {
                height = clamp(
                    size.height - top - bottom - margins.top - margins.bottom,
                    childOwn.minHeight,
                    childOwn.maxHeight,
                    childOwn.paddingHeight
                )
            }

            if let ratio = style.aspectRatio, ratio > 0 {
                if let definite = width, height == nil {
                    height = clamp(
                        definite / ratio,
                        childOwn.minHeight,
                        childOwn.maxHeight,
                        childOwn.paddingHeight
                    )
                } else if let definite = height, width == nil {
                    width = clamp(
                        definite * ratio,
                        childOwn.minWidth,
                        childOwn.maxWidth,
                        childOwn.paddingWidth
                    )
                }
            }

            if width == nil || height == nil {
                let availableWidth =
                    size.width - (insets.left ?? 0) - (insets.right ?? 0) - margins.left
                    - margins.right
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
                childOwn.height != nil || (insets.top != nil && insets.bottom != nil)

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
                    } else if node.direction == .rightToLeft {
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
                margins: margins,
                container: node.style,
                own: own,
                axes: axes,
                innerMain: innerMain,
                innerCross: innerCross
            )

            // Over-constrained (both insets and a width): the end inset gives way — `right` in
            // left-to-right, `left` in right-to-left.
            let x: Double
            if let left = insets.left, insets.right == nil || node.direction == .leftToRight {
                x = left + margins.left
            } else if let right = insets.right {
                x = size.width - right - margins.right - childSize.width
            } else {
                x = staticPosition.x
            }

            let y: Double
            if let top = insets.top {
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
            _ = try compute(
                child,
                known: OptionalSize(width: childSize.width, height: childSize.height),
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

    /// §4.1: the static position of an absolute child is where it would be as the sole flex
    /// item of its parent — placed by `justify-content` and `align-self` in the content box.
    private func absoluteStaticPosition(
        _ child: Int,
        size: LayoutSize,
        margins: Physical<Double>,
        container: FlexStyle,
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
            switch nodes[child].style.alignSelf {
            case .auto: container.alignItems
            case .stretch: .stretch
            case .start: .start
            case .end: .end
            case .center: .center
            case .baseline: .baseline
            }
        let crossOffset: Double =
            switch alignment {
            case .end: freeCross
            case .center: freeCross / 2
            case .stretch, .start, .baseline: 0
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
