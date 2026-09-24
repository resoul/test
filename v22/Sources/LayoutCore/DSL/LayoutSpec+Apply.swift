import Foundation

extension LayoutSpec {
    /// Lays the spec out in `rect` and gives every element its frame, in the coordinate space
    /// of `rect`. Frames are snapped to the pixel grid of `scale` (edges are rounded, so
    /// neighbours never overlap or leave hairline gaps).
    ///
    /// Ownership: borrows the elements for the call. Isolation: MainActor; runs synchronously.
    /// Errors: none. Cancellation: not applicable.
    public func apply(
        in rect: CGRect,
        direction: LayoutDirection = .leftToRight,
        scale: Double = 1
    ) {
        var elements: [any LayoutElement] = []
        var containers = 0
        let root = makeNode(direction: direction, elements: &elements, containers: &containers)
        let size = LayoutSize(width: Double(rect.width), height: Double(rect.height))
        guard let result = try? FlexboxEngine.layout(root, size: size) else { return }

        let snap = scale > 0 ? scale : 1
        func snapped(_ value: Double) -> Double { (value * snap).rounded() / snap }
        for (offset, element) in elements.enumerated() {
            guard let frame = result.frame(for: LayoutID(UInt64(offset))) else { continue }

            let minX = snapped(Double(rect.minX) + frame.origin.x)
            let minY = snapped(Double(rect.minY) + frame.origin.y)
            let maxX = snapped(Double(rect.minX) + frame.origin.x + frame.size.width)
            let maxY = snapped(Double(rect.minY) + frame.origin.y + frame.size.height)
            element.applyLayoutFrame(
                CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            )
        }
    }

    /// The size the spec takes under the given space — for `sizeThatFits` and
    /// `intrinsicContentSize`. `.definite` width gives fit-content: not wider than the
    /// space unless the content cannot be narrower.
    ///
    /// Ownership: returns a value. Isolation: MainActor; runs synchronously. Errors: none.
    /// Cancellation: not applicable.
    public func measure(
        width: AvailableSpace,
        height: AvailableSpace = .maxContent,
        direction: LayoutDirection = .leftToRight
    ) -> CGSize {
        var elements: [any LayoutElement] = []
        var containers = 0
        let root = makeNode(direction: direction, elements: &elements, containers: &containers)
        guard let size = try? FlexboxEngine.measure(root, width: width, height: height) else {
            return .zero
        }

        return CGSize(width: size.width, height: size.height)
    }

    /// The layout tree of this spec. Elements get ids in pre-order, which index `elements`;
    /// containers count down from the top of the id range, so the two never meet.
    func makeNode(
        direction: LayoutDirection,
        elements: inout [any LayoutElement],
        containers: inout Int
    ) -> LayoutNode {
        switch content {
        case let .element(element):
            let id = LayoutID(UInt64(elements.count))
            elements.append(element)
            return LayoutNode(
                id: id,
                style: style,
                content: element.layoutContent,
                direction: direction
            )
        case let .container(items):
            let id = LayoutID(UInt64.max - UInt64(containers))
            containers += 1
            var children: [LayoutNode] = []
            for item in items {
                children.append(
                    item.makeNode(
                        direction: direction,
                        elements: &elements,
                        containers: &containers
                    )
                )
            }
            return LayoutNode(id: id, style: style, direction: direction, children: children)
        }
    }
}
