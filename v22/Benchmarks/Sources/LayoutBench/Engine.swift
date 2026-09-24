import LayoutCore

// The engine under test. Its input is built before timing starts; `run` is only the solve.

/// A tree prepared for one layout at one size.
struct PreparedLayout: Sendable {
    /// Lays the tree out and returns the number of frames; stops at the engine's next
    /// checkpoint once `isCancelled` returns `true`.
    let run: @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> Int
}

func prepareCurrent(_ box: Box, width: Double, height: Double) -> PreparedLayout {
    var nextID: UInt64 = 0
    let root = node(box, nextID: &nextID)
    let size = LayoutSize(width: width, height: height)
    return PreparedLayout { isCancelled in
        let context = LayoutContext(isCancelled: isCancelled)
        return try FlexboxEngine.layout(root, size: size, context: context).frames.count
    }
}

private func node(_ box: Box, nextID: inout UInt64) -> LayoutNode {
    let id = LayoutID(nextID)
    nextID += 1

    var style = FlexStyle()
    style.direction = box.direction == .row ? .row : .column
    style.wrap = box.wraps ? .wrap : .noWrap
    if box.direction == .row {
        style.columnGap = box.gap
    } else {
        style.rowGap = box.gap
    }
    if let width = box.width {
        style.width = .points(width)
    }
    if let height = box.height {
        style.height = .points(height)
    }
    style.padding = Edges(all: box.padding)
    style.grow = box.grow
    style.shrink = box.shrink
    if box.centersItems {
        style.alignItems = .center
    }

    let content = box.text.map { LeafContent.measured(Words(text: $0)) }
    var children: [LayoutNode] = []
    children.reserveCapacity(box.children.count)
    for child in box.children {
        children.append(node(child, nextID: &nextID))
    }
    return LayoutNode(id: id, style: style, content: content, children: children)
}

private struct Words: ContentMeasurer {
    let text: Box.Text

    func minContentWidth() -> Double { text.words.max() ?? 0 }

    func maxContentWidth() -> Double { text.words.reduce(0, +) }

    func height(forWidth width: Double) -> Double {
        Double(wrap(text.words, width: width).lines) * text.lineHeight
    }

    func firstBaseline(forWidth width: Double) -> Double? {
        text.words.isEmpty ? nil : text.lineHeight
    }
}
