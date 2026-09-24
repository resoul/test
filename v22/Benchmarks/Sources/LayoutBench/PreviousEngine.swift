import TrellisCore

// The previous engine, for comparison. Its input is the snapshot of a `Node` tree, taken
// before timing starts; `run` is only the solve, as for the engine under test.

@MainActor
func preparePrevious(_ box: Box, width: Double, height: Double) -> PreparedLayout {
    var revision: UInt64 = 0
    let root = node(box, revision: &revision)
    let input = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(width), height: .exact(height))
    )
    let frame = LayoutFrame(width: width, height: height)
    return PreparedLayout { isCancelled in
        let context = LayoutContext(cancellationCheck: isCancelled)
        return try FlexboxEngine.layoutContainer(input: input, frame: frame, context: context)
            .placements.count
    }
}

@MainActor
private func node(_ box: Box, revision: inout UInt64) -> Node {
    let result: Node
    if let text = box.text {
        revision += 1
        result = TextLeaf(Words(text: text, revision: revision))
    } else {
        result = Node()
    }

    var style = result.style
    style.flexDirection = box.direction == .row ? .row : .column
    style.flexWrap = box.wraps ? .wrap : .noWrap
    style.gap = box.gap
    if let width = box.width {
        style.width = .points(width)
    }
    if let height = box.height {
        style.height = .points(height)
    }
    style.padding = DirectionalEdgeInsets(
        top: box.padding,
        leading: box.padding,
        bottom: box.padding,
        trailing: box.padding
    )
    style.flexGrow = box.grow
    style.flexShrink = box.shrink
    if box.centersItems {
        style.alignItems = .center
    }
    result.style = style

    for child in box.children {
        result.addSubnode(node(child, revision: &revision))
    }
    return result
}

private final class TextLeaf: Node {
    private let metrics: LayoutContentMetrics

    init(_ words: Words) {
        metrics = LayoutContentMetrics(measurer: words)
        super.init()
    }

    override func layoutContentMetrics(for constraint: SizeConstraint) -> LayoutContentMetrics {
        metrics
    }
}

private struct Words: ContentMeasurer {
    let text: Box.Text
    let revision: UInt64

    var identity: ObjectIdentifier { ObjectIdentifier(Words.self) }

    func measure(_ constraint: SizeConstraint, context: LayoutContext) throws
        -> LayoutContentMetrics
    {
        try context.checkCancellation()
        let (width, lines) = wrap(text.words, width: constraint.width.knownValue ?? .infinity)
        return LayoutContentMetrics(
            intrinsic: MeasuredSize(width: width, height: Double(lines) * text.lineHeight),
            firstBaseline: text.words.isEmpty ? nil : text.lineHeight
        )
    }
}
