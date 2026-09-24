import Foundation

extension LayoutSpec {
    /// Lays the spec out in `rect` and gives every element its frame, in the coordinate space
    /// of `rect`. Frames are snapped to the pixel grid of `scale` (edges are rounded, so
    /// neighbours never overlap or leave hairline gaps). Spacing steps take their points
    /// from `spacing`. Elements of `hidden`, `invisible` and `Breakpoint` specs are shown or
    /// hidden to match.
    ///
    /// Ownership: borrows the elements for the call. Isolation: MainActor; runs synchronously.
    /// Errors: none. Cancellation: not applicable.
    public func apply(
        in rect: LayoutRect,
        direction: LayoutDirection = .leftToRight,
        scale: Double = 1,
        spacing: SpacingScale = .standard
    ) {
        var tree = LayoutTree(direction: direction, spacing: spacing)
        let root = tree.root(for: self)
        guard let result = try? FlexboxEngine.layout(root, size: rect.size) else { return }

        let snap = scale > 0 ? scale : 1
        func snapped(_ value: Double) -> Double { (value * snap).rounded() / snap }

        var visible: [ObjectIdentifier: Bool] = [:]
        for (offset, entry) in tree.elements.enumerated() {
            let frame = result.frame(for: LayoutID(UInt64(offset)))
            if let frame {
                let minX = snapped(rect.origin.x + frame.origin.x)
                let minY = snapped(rect.origin.y + frame.origin.y)
                let maxX = snapped(rect.origin.x + frame.origin.x + frame.size.width)
                let maxY = snapped(rect.origin.y + frame.origin.y + frame.size.height)
                entry.element.applyLayoutFrame(
                    LayoutRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                )
            }

            if entry.managesVisibility {
                // An element can stand in several places (both branches of a breakpoint):
                // it is visible if any of them shows it.
                let key = ObjectIdentifier(entry.element)
                visible[key] = (visible[key] ?? false) || (frame != nil && !entry.isInvisible)
            }
        }

        for entry in tree.elements where entry.managesVisibility {
            let key = ObjectIdentifier(entry.element)
            if let isVisible = visible.removeValue(forKey: key) {
                entry.element.applyLayoutVisibility(isVisible)
            }
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
        direction: LayoutDirection = .leftToRight,
        spacing: SpacingScale = .standard
    ) -> LayoutSize {
        var tree = LayoutTree(direction: direction, spacing: spacing)
        let root = tree.root(for: self)
        return (try? FlexboxEngine.measure(root, width: width, height: height)) ?? .zero
    }
}

/// Turns a spec into the engine's tree. Elements get ids in pre-order, which index
/// `elements`; containers count down from the top of the id range, so the two never meet.
@MainActor
struct LayoutTree {
    struct Entry {
        let element: any LayoutElement
        let managesVisibility: Bool
        let isInvisible: Bool
    }

    let direction: LayoutDirection
    let spacing: SpacingScale
    var elements: [Entry] = []
    private var containers: UInt64 = 0

    init(direction: LayoutDirection, spacing: SpacingScale) {
        self.direction = direction
        self.spacing = spacing
    }

    /// A single root node. Alternatives at the root sit in an implicit column that gives
    /// them the whole width and lets them fill the height.
    mutating func root(for spec: LayoutSpec) -> LayoutNode {
        if case .alternatives = spec.content {
            var style = FlexStyle()
            style.direction = .column
            let id = LayoutID(UInt64.max - containers)
            containers += 1
            let children = nodes(
                for: spec,
                managesVisibility: false,
                isInvisible: false,
                fill: true
            )
            return LayoutNode(id: id, style: style, direction: direction, children: children)
        }

        return nodes(for: spec, managesVisibility: false, isInvisible: false, fill: false)[0]
    }

    /// The nodes a spec stands for: one, or the nodes of both branches of a breakpoint, each
    /// shown only on its side of the threshold. `fill` makes breakpoint branches grow to fill
    /// their parent (used for the implicit root).
    private mutating func nodes(
        for spec: LayoutSpec,
        managesVisibility inherited: Bool,
        isInvisible inheritedInvisible: Bool,
        fill: Bool
    ) -> [LayoutNode] {
        let managesVisibility = inherited || spec.managesVisibility
        let isInvisible = inheritedInvisible || spec.isInvisible
        let (style, variants) = spec.resolvedStyle(spacing)

        switch spec.content {
        case let .element(element):
            let id = LayoutID(UInt64(elements.count))
            elements.append(
                Entry(
                    element: element,
                    managesVisibility: managesVisibility,
                    isInvisible: isInvisible
                )
            )
            return [
                LayoutNode(
                    id: id,
                    style: style,
                    content: element.layoutContent,
                    direction: direction,
                    variants: variants
                )
            ]

        case let .container(items):
            let id = LayoutID(UInt64.max - containers)
            containers += 1
            var children: [LayoutNode] = []
            for item in items {
                children += nodes(
                    for: item,
                    managesVisibility: managesVisibility,
                    isInvisible: isInvisible,
                    fill: false
                )
            }
            return [
                LayoutNode(
                    id: id,
                    style: style,
                    direction: direction,
                    children: children,
                    variants: variants
                )
            ]

        case let .alternatives(threshold, wide, narrow):
            // Each branch item is shown on its side of the threshold only. The display changes
            // come first, so an item's own `hidden` still hides it on its side.
            var result: [LayoutNode] = []
            for (items, isWide) in [(wide, true), (narrow, false)] {
                for item in items {
                    var branch = item
                    branch.patches.insert(
                        LayoutSpec.StylePatch(from: nil) { style, _ in
                            style.display = isWide ? .none : .flex
                        },
                        at: 0
                    )
                    branch.patches.insert(
                        LayoutSpec.StylePatch(from: threshold) { style, _ in
                            style.display = isWide ? .flex : .none
                        },
                        at: 1
                    )
                    if fill {
                        branch.patches.append(
                            LayoutSpec.StylePatch(from: nil) { style, _ in
                                if style.height == .auto && style.basis == .auto && style.grow == 0
                                {
                                    style.grow = 1
                                }
                            }
                        )
                    }
                    result += nodes(
                        for: branch,
                        managesVisibility: true,
                        isInvisible: isInvisible,
                        fill: false
                    )
                }
            }
            return result
        }
    }
}
