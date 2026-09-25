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
    public var input: LayoutNode { tree.root }

    /// Owns `input`, so that a deep tree is released level by level with the prepared layout.
    let tree: LayoutTreeOwner

    /// Some content measures by asking a view, so the tree must be solved on the main
    /// thread.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let requiresMainThread: Bool

    let elements: [LayoutTree.Entry]
    let owners: [LayoutID: Int]

    /// The element `id` stands for in `input`: the element itself, or for a container of an
    /// element's layout, that element. `nil` for a container of the spec itself.
    ///
    /// Ownership: returns a borrowed element. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func element(for id: LayoutID) -> (any LayoutElement)? {
        let index = id.raw < UInt64(elements.count) ? Int(id.raw) : owners[id]
        return index.map { elements[$0].element }
    }

    /// The ids `element` has in `input` — more than one when the spec mentions it in several
    /// places.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func ids(of element: any LayoutElement) -> [LayoutID] {
        let key = ObjectIdentifier(element)
        return elements.indices.filter { ObjectIdentifier(elements[$0].element) == key }
            .map { LayoutID(UInt64($0)) }
    }

    /// The ids of the elements `isIncluded` accepts, with the containers of their embedded
    /// layouts.
    ///
    /// Ownership: returns values; `isIncluded` is not kept. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    public func ids(where isIncluded: (any LayoutElement) -> Bool) -> Set<LayoutID> {
        var included: Set<Int> = []
        var ids: Set<LayoutID> = []
        for (offset, entry) in elements.enumerated() where isIncluded(entry.element) {
            included.insert(offset)
            ids.insert(LayoutID(UInt64(offset)))
        }
        for (id, owner) in owners where included.contains(owner) {
            ids.insert(id)
        }
        return ids
    }

    /// Every element the spec mentions, in order, once per place.
    ///
    /// Ownership: returns borrowed elements. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var mentionedElements: [any LayoutElement] { elements.map(\.element) }

    /// The number of places the spec mentions elements in.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var elementCount: Int { elements.count }

    /// Whether `id` is an element's rather than a container's.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func isElement(_ id: LayoutID) -> Bool { id.raw < UInt64(elements.count) }

    /// Elements that `result` gives a frame in more than one place, in the order the spec
    /// first mentions them. Mentioning an element several times is fine as long as one place
    /// at most is laid out — both branches of a `Breakpoint` — but an element has one frame,
    /// so two laid-out places are a mistake in the spec.
    ///
    /// Ownership: returns borrowed elements. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func elementsPlacedMoreThanOnce(in result: LayoutResult) -> [any LayoutElement] {
        var placed: Set<ObjectIdentifier> = []
        var reported: Set<ObjectIdentifier> = []
        var duplicates: [any LayoutElement] = []
        for (offset, entry) in elements.enumerated()
        where result.frame(for: LayoutID(UInt64(offset))) != nil {
            let key = ObjectIdentifier(entry.element)
            if !placed.insert(key).inserted, reported.insert(key).inserted {
                duplicates.append(entry.element)
            }
        }
        return duplicates
    }

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
            entry.element.applyLayoutSticky(
                sticky(of: entry, placed: placed, result: result, rect: rect, absolute: absolute)
            )
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

    /// Where a sticky element keeps itself: its insets, and its flex container's frame in
    /// the coordinates of the element's frame — those of the element owning it.
    private func sticky(
        of entry: LayoutTree.Entry,
        placed: LayoutRect?,
        result: LayoutResult,
        rect: LayoutRect,
        absolute: [LayoutRect?]
    ) -> StickyPosition? {
        guard let insets = entry.sticky, placed != nil else { return nil }

        let origin = entry.container.flatMap { absolute[$0]?.origin } ?? .zero
        // Without a container (the spec's own root) nothing bounds it: far beyond any scroll.
        var bounds = LayoutRect(x: -1e12, y: -1e12, width: 2e12, height: 2e12)
        if let parent = entry.flexParent, let frame = result.frame(for: parent) {
            bounds = LayoutRect(
                x: rect.origin.x + frame.origin.x - origin.x,
                y: rect.origin.y + frame.origin.y - origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
        }
        return StickyPosition(
            top: insets.top,
            left: insets.left,
            bottom: insets.bottom,
            right: insets.right,
            bounds: bounds
        )
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
            tree: LayoutTreeOwner(input),
            requiresMainThread: tree.requiresMainThread,
            elements: tree.elements,
            owners: tree.owners
        )
    }

    /// Lays the spec out in `rect` at once: `prepare`, solve, `PreparedLayout.apply`. The pass
    /// is rejected — the elements keep their frames — when the spec is too deep for the
    /// calling thread's stack, rather than crashing it, and when an element is laid out in
    /// two places: it has one frame, and applying either would hide the mistake.
    /// `reporting`, when given, receives what the pass found.
    ///
    /// Ownership: borrows the elements for the call. Isolation: MainActor; runs synchronously.
    /// Errors: none. Cancellation: not applicable.
    @discardableResult
    public func apply(
        in rect: LayoutRect,
        direction: LayoutDirection = .leftToRight,
        scale: Double = 1,
        spacing: SpacingScale = .standard,
        reporting: LayoutSpecReporting? = nil
    ) -> [LayoutPlacement] {
        let prepared = prepare(direction: direction, spacing: spacing)
        var trace: LayoutTraceRequest?
        if let reporting, !reporting.traceAreas.isEmpty {
            let traced = reporting.tracedElements
            trace = LayoutTraceRequest(
                areas: reporting.traceAreas,
                ids: traced.map { traced in
                    prepared.ids { element in traced.contains { $0 === element } }
                }
            )
        }
        let context = LayoutContext(
            trace: trace,
            stackBudget: LayoutContext.currentThreadStackBudget
        )
        let clock = ContinuousClock()
        let start = clock.now
        let result = try? FlexboxEngine.layout(prepared.input, size: rect.size, context: context)
        let duration = clock.now - start
        let duplicates = result.map { prepared.elementsPlacedMoreThanOnce(in: $0) } ?? []
        if let reporting {
            reporting.handler(
                LayoutSpecReport(
                    host: reporting.host,
                    prepared: prepared,
                    result: result,
                    duration: duration,
                    duplicates: duplicates
                )
            )
        }
        guard let result, duplicates.isEmpty else { return [] }

        return prepared.apply(result, in: rect, scale: scale)
    }

    /// The size the spec takes under the given space — for `sizeThatFits` and
    /// `intrinsicContentSize`. `.definite` width gives fit-content: not wider than the
    /// space unless the content cannot be narrower. A spec too deep for the calling thread's
    /// stack measures as zero rather than crashing it.
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
        let context = LayoutContext(stackBudget: LayoutContext.currentThreadStackBudget)
        let size = try? FlexboxEngine.measure(root, width: width, height: height, context: context)
        LayoutNode.dismantle(consume root)
        return size ?? .zero
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
        /// Physical distances from a scroll's edges, for a `sticky` element.
        let sticky: Physical<Double?>?
        /// The flex container the element is an item of — the element owning it, or a
        /// container of a layout — whose frame bounds a sticky element.
        let flexParent: LayoutID?
    }

    let direction: LayoutDirection
    let spacing: SpacingScale
    var elements: [Entry] = []
    /// Some leaf's content can only be measured on the main thread.
    private(set) var requiresMainThread = false
    private var containers: UInt64 = 0
    /// Containers of an element's embedded layout, to that element's index.
    private(set) var owners: [LayoutID: Int] = [:]
    /// Elements whose embedded layout is being expanded: one that mentions itself, directly
    /// or through its subelements, is placed as a leaf there instead of recursing forever.
    private var expanding: Set<ObjectIdentifier> = []

    init(direction: LayoutDirection, spacing: SpacingScale) {
        self.direction = direction
        self.spacing = spacing
    }

    /// How the items of one list are placed: what they inherit from the spec around them.
    private struct Place {
        var managesVisibility: Bool
        var isInvisible: Bool
        /// Breakpoint branches grow to fill their parent (the implicit root).
        var fill: Bool
        /// Index of the element whose embedded layout the items belong to.
        var container: Int?
        /// The flex container the items are items of.
        var flexParent: LayoutID? = nil
    }

    /// A list of items being turned into nodes, and what the finished list becomes.
    private struct Frame {
        enum Kind {
            /// The nodes go straight into the parent's list: the root's list, or both
            /// branches of a breakpoint.
            case splice
            case container(LayoutID, FlexStyle, [StyleVariant])
            /// An element's embedded layout; `key` stops the element being expanded inside
            /// itself while its items are built.
            case embedded(LayoutID, ObjectIdentifier, FlexStyle, [StyleVariant])
        }

        let kind: Kind
        let items: [LayoutSpec]
        let place: Place
        var next = 0
        var children: [LayoutNode] = []
    }

    /// A single root node. Alternatives at the root sit in an implicit column that gives
    /// them the whole width and lets them fill the height.
    mutating func root(for spec: LayoutSpec) -> LayoutNode {
        let place = Place(managesVisibility: false, isInvisible: false, fill: false, container: nil)
        if case .alternatives = spec.content {
            var style = FlexStyle()
            style.direction = .column
            let id = LayoutID(UInt64.max - containers)
            containers += 1
            var filling = place
            filling.fill = true
            let children = nodes(for: spec, place: filling)
            return LayoutNode(id: id, style: style, direction: direction, children: children)
        }

        return nodes(for: spec, place: place)[0]
    }

    /// The nodes a spec stands for: one, or the nodes of both branches of a breakpoint, each
    /// shown only on its side of the threshold.
    ///
    /// A loop over an explicit stack rather than recursion: this runs on the main thread,
    /// whose stack is small on a phone, and a tree of nested layouts can be deeper than it
    /// allows. Everything happens in the order a recursive walk would do it — elements are
    /// numbered and asked for their layouts and content in pre-order.
    private mutating func nodes(for spec: LayoutSpec, place: Place) -> [LayoutNode] {
        var frames = [Frame(kind: .splice, items: [spec], place: place)]
        while let top = frames.indices.last {
            guard frames[top].next < frames[top].items.count else {
                let built = finish(frames.removeLast())
                guard let parent = frames.indices.last else { return built }

                frames[parent].children += built
                continue
            }

            let item = frames[top].items[frames[top].next]
            frames[top].next += 1
            switch visit(item, place: frames[top].place) {
            case let .node(node): frames[top].children.append(node)
            case .none: break
            case let .open(frame): frames.append(frame)
            }
        }
        return []
    }

    private enum Step {
        case node(LayoutNode)
        case none
        case open(Frame)
    }

    /// Turns one spec into its node when it has no items of its own, or opens the list of its
    /// items.
    private mutating func visit(_ spec: LayoutSpec, place: Place) -> Step {
        let managesVisibility = place.managesVisibility || spec.managesVisibility
        let isInvisible = place.isInvisible || spec.isInvisible

        switch spec.content {
        case let .element(element):
            let index = elements.count
            let id = LayoutID(UInt64(index))
            elements.append(
                Entry(
                    element: element,
                    container: place.container,
                    managesVisibility: managesVisibility,
                    isInvisible: isInvisible,
                    sticky: spec.stickyInsets?.physical(direction),
                    flexParent: place.flexParent
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
                guard case let .container(items) = own.content else { return .none }

                expanding.insert(key)
                return .open(
                    Frame(
                        kind: .embedded(id, key, ownStyle, ownVariants),
                        items: items,
                        place: Place(
                            managesVisibility: false,
                            isInvisible: false,
                            fill: false,
                            container: index,
                            flexParent: id
                        )
                    )
                )
            }

            let (style, variants) = spec.resolvedStyle(spacing)
            let content = element.layoutContent
            if case let .measured(measurer) = content, measurer.requiresMainThread {
                requiresMainThread = true
            }
            return .node(
                LayoutNode(
                    id: id,
                    style: style,
                    content: content,
                    direction: direction,
                    variants: variants
                )
            )

        case let .container(items):
            let (style, variants) = spec.resolvedStyle(spacing)
            let id = LayoutID(UInt64.max - containers)
            containers += 1
            if let container = place.container {
                owners[id] = container
            }
            return .open(
                Frame(
                    kind: .container(id, style, variants),
                    items: items,
                    place: Place(
                        managesVisibility: managesVisibility,
                        isInvisible: isInvisible,
                        fill: false,
                        container: place.container,
                        flexParent: id
                    )
                )
            )

        case let .alternatives(threshold, wide, narrow):
            // Each branch item is shown on its side of the threshold only. The display changes
            // come first, so an item's own `hidden` still hides it on its side.
            var branches: [LayoutSpec] = []
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
                    if place.fill {
                        branch.patches.append(
                            LayoutSpec.StylePatch(from: nil) { style, _ in
                                if style.height == .auto && style.basis == .auto && style.grow == 0
                                {
                                    style.grow = 1
                                }
                            }
                        )
                    }
                    branches.append(branch)
                }
            }
            return .open(
                Frame(
                    kind: .splice,
                    items: branches,
                    place: Place(
                        managesVisibility: true,
                        isInvisible: isInvisible,
                        fill: false,
                        container: place.container,
                        flexParent: place.flexParent
                    )
                )
            )
        }
    }

    /// The nodes a finished list becomes.
    private mutating func finish(_ frame: Frame) -> [LayoutNode] {
        switch frame.kind {
        case .splice:
            return frame.children
        case let .container(id, style, variants):
            return [
                LayoutNode(
                    id: id,
                    style: style,
                    direction: direction,
                    children: frame.children,
                    variants: variants
                )
            ]
        case let .embedded(id, key, style, variants):
            expanding.remove(key)
            return [
                LayoutNode(
                    id: id,
                    style: style,
                    direction: direction,
                    children: frame.children,
                    variants: variants
                )
            ]
        }
    }
}
