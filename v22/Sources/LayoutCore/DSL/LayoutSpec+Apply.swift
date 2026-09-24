import Foundation

/// Where one element of a spec ended up.
///
/// Ownership: borrows the elements. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
public struct LayoutPlacement {
    /// The element placed.
    ///
    /// Ownership: borrowed. Isolation: MainActor. Errors: none. Cancellation: none.
    public let element: any LayoutElement

    /// Its frame, in the coordinate space of `container`, or of the spec's rectangle when
    /// `container` is `nil`; `nil` when the element was not laid out (`hidden`, the other
    /// side of a `Breakpoint`, or inside such an item).
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: none.
    public let frame: LayoutRect?

    /// The element whose `embeddedLayout` placed this one, or `nil` for the spec itself.
    ///
    /// Ownership: borrowed. Isolation: MainActor. Errors: none. Cancellation: none.
    public let container: (any LayoutElement)?
}

/// A spec turned into the engine's input, with what is needed to hand the result back to
/// its elements. Built on the main actor; `input` is a value that can be solved anywhere —
/// on a background thread unless `requiresMainThread`.
///
/// Ownership: borrows the spec's elements. Isolation: MainActor; `input` is `Sendable`.
/// Errors: none. Cancellation: not applicable.
@MainActor
public struct PreparedLayout {
    /// The tree to give `FlexboxEngine.layout`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let input: LayoutNode

    /// Some content measures by asking a view, so the tree must be solved on the main
    /// thread.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let requiresMainThread: Bool

    let elements: [LayoutTree.Entry]

    /// Gives every element its frame from `result`, the engine's layout of `input` in
    /// `rect.size`: in the coordinate space of `rect`, or of the element whose
    /// `embeddedLayout` placed it. Frames are snapped to the pixel grid of `scale` (edges are
    /// rounded, so neighbours never overlap or leave hairline gaps). Elements of `hidden`,
    /// `invisible` and `Breakpoint` specs are shown or hidden to match. Returns where every
    /// element went, in the order the spec mentions them.
    ///
    /// Ownership: borrows the elements for the call. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func apply(
        _ result: LayoutResult,
        in rect: LayoutRect,
        scale: Double = 1
    ) -> [LayoutPlacement] {
        let snap = scale > 0 ? scale : 1
        func snapped(_ value: Double) -> Double { (value * snap).rounded() / snap }

        // Frames snapped in the coordinates of `rect`, then made relative to their container
        // — whose own frame, earlier in pre-order, is snapped too.
        var absolute: [LayoutRect?] = []
        absolute.reserveCapacity(elements.count)
        var placements: [LayoutPlacement] = []
        placements.reserveCapacity(elements.count)
        var visible: [ObjectIdentifier: Bool] = [:]
        for (offset, entry) in elements.enumerated() {
            var placed: LayoutRect?
            if let frame = result.frame(for: LayoutID(UInt64(offset))) {
                let minX = snapped(rect.origin.x + frame.origin.x)
                let minY = snapped(rect.origin.y + frame.origin.y)
                let maxX = snapped(rect.origin.x + frame.origin.x + frame.size.width)
                let maxY = snapped(rect.origin.y + frame.origin.y + frame.size.height)
                placed = LayoutRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            absolute.append(placed)

            var frame = placed
            if let container = entry.container, let origin = absolute[container]?.origin,
                let own = placed
            {
                frame = LayoutRect(
                    x: own.origin.x - origin.x,
                    y: own.origin.y - origin.y,
                    width: own.size.width,
                    height: own.size.height
                )
            }
            if let frame {
                entry.element.applyLayoutFrame(frame)
            }
            placements.append(
                LayoutPlacement(
                    element: entry.element,
                    frame: frame,
                    container: entry.container.map { elements[$0].element }
                )
            )

            if entry.managesVisibility {
                // An element can stand in several places (both branches of a breakpoint):
                // it is visible if any of them shows it.
                let key = ObjectIdentifier(entry.element)
                visible[key] = (visible[key] ?? false) || (placed != nil && !entry.isInvisible)
            }
        }

        for entry in elements where entry.managesVisibility {
            let key = ObjectIdentifier(entry.element)
            if let isVisible = visible.removeValue(forKey: key) {
                entry.element.applyLayoutVisibility(isVisible)
            }
        }
        return placements
    }
}

extension LayoutSpec {
    /// Turns the spec into the engine's input — the part of a layout pass that asks the
    /// elements for their layouts and content, so it runs on the main actor. Solve `input`
    /// and hand the result to `PreparedLayout.apply`.
    ///
    /// Ownership: returns a value borrowing the elements. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func prepare(
        direction: LayoutDirection = .leftToRight,
        spacing: SpacingScale = .standard
    ) -> PreparedLayout {
        var tree = LayoutTree(direction: direction, spacing: spacing)
        let input = tree.root(for: self)
        return PreparedLayout(
            input: input,
            requiresMainThread: tree.requiresMainThread,
            elements: tree.elements
        )
    }

    /// Lays the spec out in `rect` at once: `prepare`, solve, `PreparedLayout.apply`.
    ///
    /// Ownership: borrows the elements for the call. Isolation: MainActor; runs synchronously.
    /// Errors: none. Cancellation: not applicable.
    @discardableResult
    public func apply(
        in rect: LayoutRect,
        direction: LayoutDirection = .leftToRight,
        scale: Double = 1,
        spacing: SpacingScale = .standard
    ) -> [LayoutPlacement] {
        let prepared = prepare(direction: direction, spacing: spacing)
        guard let result = try? FlexboxEngine.layout(prepared.input, size: rect.size) else {
            return []
        }

        return prepared.apply(result, in: rect, scale: scale)
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
        /// Index of the element whose embedded layout placed this one.
        let container: Int?
        let managesVisibility: Bool
        let isInvisible: Bool
    }

    let direction: LayoutDirection
    let spacing: SpacingScale
    var elements: [Entry] = []
    /// Some leaf's content can only be measured on the main thread.
    private(set) var requiresMainThread = false
    private var containers: UInt64 = 0
    /// Elements whose embedded layout is being expanded: one that mentions itself, directly
    /// or through its subelements, is placed as a leaf there instead of recursing forever.
    private var expanding: Set<ObjectIdentifier> = []

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
                fill: true,
                container: nil
            )
            return LayoutNode(id: id, style: style, direction: direction, children: children)
        }

        return nodes(
            for: spec,
            managesVisibility: false,
            isInvisible: false,
            fill: false,
            container: nil
        )[0]
    }

    /// The nodes a spec stands for: one, or the nodes of both branches of a breakpoint, each
    /// shown only on its side of the threshold. `fill` makes breakpoint branches grow to fill
    /// their parent (used for the implicit root).
    private mutating func nodes(
        for spec: LayoutSpec,
        managesVisibility inherited: Bool,
        isInvisible inheritedInvisible: Bool,
        fill: Bool,
        container: Int?
    ) -> [LayoutNode] {
        let managesVisibility = inherited || spec.managesVisibility
        let isInvisible = inheritedInvisible || spec.isInvisible
        let (style, variants) = spec.resolvedStyle(spacing)

        switch spec.content {
        case let .element(element):
            let index = elements.count
            let id = LayoutID(UInt64(index))
            elements.append(
                Entry(
                    element: element,
                    container: container,
                    managesVisibility: managesVisibility,
                    isInvisible: isInvisible
                )
            )
            let key = ObjectIdentifier(element)
            if !expanding.contains(key), let embedded = element.embeddedLayout {
                // The element is a flex container: the embedded layout's own style, then the
                // modifiers of the element's place in its parent. A layout that is not a
                // container (a single item, a `Breakpoint`) goes into a column, so it spans
                // the element's width as a block does.
                var own = embedded
                if case .container = own.content {} else { own = LayoutSpec(.column) { embedded } }
                own.patches += spec.patches
                let (ownStyle, ownVariants) = own.resolvedStyle(spacing)
                guard case let .container(items) = own.content else { return [] }

                expanding.insert(key)
                defer { expanding.remove(key) }
                var children: [LayoutNode] = []
                for item in items {
                    children += nodes(
                        for: item,
                        managesVisibility: false,
                        isInvisible: false,
                        fill: false,
                        container: index
                    )
                }
                return [
                    LayoutNode(
                        id: id,
                        style: ownStyle,
                        direction: direction,
                        children: children,
                        variants: ownVariants
                    )
                ]
            }

            let content = element.layoutContent
            if case let .measured(measurer) = content, measurer.requiresMainThread {
                requiresMainThread = true
            }
            return [
                LayoutNode(
                    id: id,
                    style: style,
                    content: content,
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
                    fill: false,
                    container: container
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
                        fill: false,
                        container: container
                    )
                }
            }
            return result
        }
    }
}
