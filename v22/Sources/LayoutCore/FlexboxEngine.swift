/// CSS Flexbox layout of an immutable `LayoutNode` tree (CSS Flexible Box Layout Module
/// Level 1, §9). A pure function of its input: no shared state, no platform objects, no
/// output besides the returned value — safe to run on any task.
///
/// Ownership: stateless. Isolation: none. Errors: `LayoutCancelled`, and
/// `LayoutStackExhausted` over `LayoutContext.stackBudget`. Cancellation: through
/// `LayoutContext`; a pass that throws returns nothing.
public enum FlexboxEngine {
    /// Lays out `root` as if a host gave it exactly `size`, and returns every node's frame in
    /// the root's coordinate space (the root itself is at the origin).
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: throws `LayoutCancelled` when
    /// `context` reports cancellation, `LayoutStackExhausted` when the tree is too deep for
    /// `context.stackBudget`. Cancellation: checked at every container and every 256 items;
    /// nothing partial is returned.
    public static func layout(
        _ root: LayoutNode,
        size: LayoutSize,
        context: LayoutContext = LayoutContext()
    ) throws -> LayoutResult {
        var solver = try Solver(root: root, context: context)
        solver.frames[0] = LayoutRect(origin: .zero, size: size)
        _ = try solver.compute(
            0,
            known: OptionalSize(width: size.width, height: size.height),
            parent: OptionalSize(width: size.width, height: size.height),
            available: AvailableSize(width: .definite(size.width), height: .definite(size.height)),
            mode: .layout(.zero)
        )
        let frames = solver.nodes.indices.compactMap { index in
            solver.frames[index].map { (id: solver.nodes[index].id, frame: $0) }
        }
        var trace = solver.trace
        if let request = context.trace {
            for (id, frame) in frames where request.includes(.place, id) {
                trace.append(.placed(id, frame: frame))
            }
        }
        return LayoutResult(
            frames: frames,
            variantsWithoutWidth: Set(
                solver.variantsWithoutWidth.indices.map { solver.nodes[$0].id }
            ),
            trace: trace,
            statistics: solver.statistics
        )
    }

    /// The size `root` takes under the given available space when nothing else fixes it —
    /// what a host asks for `sizeThatFits`/`intrinsicContentSize`.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: as `layout`. Cancellation:
    /// as `layout`.
    public static func measure(
        _ root: LayoutNode,
        width: AvailableSpace,
        height: AvailableSpace,
        context: LayoutContext = LayoutContext()
    ) throws -> LayoutSize {
        var solver = try Solver(root: root, context: context)
        return try solver.compute(
            0,
            known: OptionalSize(),
            parent: OptionalSize(),
            available: AvailableSize(width: width, height: height),
            mode: .size
        )
    }
}

struct OptionalSize: Hashable {
    var width: Double?
    var height: Double?

    init(width: Double? = nil, height: Double? = nil) {
        self.width = width
        self.height = height
    }

    init(main: Double?, cross: Double?, isRow: Bool) {
        self.init(width: isRow ? main : cross, height: isRow ? cross : main)
    }
}

struct AvailableSize: Hashable {
    var width: AvailableSpace
    var height: AvailableSpace

    init(width: AvailableSpace, height: AvailableSpace) {
        self.width = width
        self.height = height
    }

    init(main: AvailableSpace, cross: AvailableSpace, isRow: Bool) {
        self.init(width: isRow ? main : cross, height: isRow ? cross : main)
    }
}

enum RunMode {
    /// Only the node's own size is needed.
    case size
    /// Final pass: the node's size is known; place its children with the node at `origin`.
    case layout(LayoutPoint)
}

/// Which known sizes count as definite (CSS Flexbox §9.8) — percentages of children resolve
/// only against a definite size. A height can be known without being definite: an item that
/// is not stretched gets its height from its content, and a percentage height inside it
/// behaves as `auto`, exactly as in a browser. A known width is always definite.
struct DefiniteAxes: Hashable {
    var width: Bool
    var height: Bool

    static let both = DefiniteAxes(width: true, height: true)

    init(width: Bool, height: Bool) {
        self.width = width
        self.height = height
    }

    init(main: Bool, cross: Bool, isRow: Bool) {
        self.init(width: isRow ? main : cross, height: isRow ? cross : main)
    }
}

/// A physical axis.
enum Axis: Hashable {
    case horizontal
    case vertical
}

struct FlatNode {
    let id: LayoutID
    let style: FlexStyle
    let variants: [StyleVariant]
    let content: LeafContent?
    let direction: LayoutDirection
    var children: [Int]
    /// The node or one of its width variants has an aspect ratio.
    let hasAspectRatio: Bool
    /// `order` of the base style, or `nil` when the base style takes the node out of flow.
    let flowOrder: Int?

    /// `order` of an in-flow node with `style`; `nil` for an absolute or `display: none` one.
    static func flowOrder(_ style: FlexStyle) -> Int? {
        style.position != .absolute && style.display != .none ? style.order : nil
    }
    /// The containing block changes this node's own result: it has a percentage size or width
    /// variants. Otherwise the containing block is left out of its cache keys, so the same
    /// request from different ancestors' passes is computed once.
    let dependsOnParent: Bool
    /// The node's layout depends on its own width before its content decides it: a child's
    /// width is a percentage of it (or has width variants), or it is a row that wraps.
    var sizesWidthFirst = false
}

struct BaselineKey: Hashable {
    let node: Int
    let size: OptionalSize
    let parent: OptionalSize
}

struct MeasureKey: Hashable {
    let node: Int
    let known: OptionalSize
    let parent: OptionalSize
    let available: AvailableSize
    let contentOnly: Axis?
    let definite: DefiniteAxes

    /// The key is hashed on every size request, so its fields are mixed into one word and the
    /// hasher is fed once, instead of once per field and optional tag. Equality stays exact.
    func hash(into hasher: inout Hasher) {
        var mix = HashMix(UInt64(node))
        mix.add(known.width)
        mix.add(known.height)
        mix.add(parent.width)
        mix.add(parent.height)
        mix.add(available.width)
        mix.add(available.height)
        let axis: UInt64 =
            switch contentOnly {
            case nil: 0
            case .horizontal: 1
            case .vertical: 2
            }
        mix.add(axis << 2 | (definite.width ? 2 : 0) | (definite.height ? 1 : 0))
        hasher.combine(mix.value)
    }
}

/// A fast mix of 64-bit words for hashing keys.
struct HashMix {
    private(set) var value: UInt64

    init(_ seed: UInt64) {
        value = seed
    }

    mutating func add(_ word: UInt64) {
        value = (value ^ word) &* 0x9E37_79B9_7F4A_7C15
        value ^= value >> 29
    }

    /// Equal doubles give equal words: `-0` mixes as `0`. `nil` has its own word.
    mutating func add(_ number: Double?) {
        guard let number else {
            add(0x7FF4_0000_0000_0001)
            return
        }

        add(number == 0 ? 0 : number.bitPattern)
    }

    mutating func add(_ space: AvailableSpace) {
        switch space {
        case let .definite(value): add(value)
        case .minContent: add(0x7FF4_0000_0000_0002)
        case .maxContent: add(0x7FF4_0000_0000_0003)
        }
    }
}

/// Node indices one pass collects. It belongs to that pass alone and never leaves the thread
/// the pass runs on.
final class NodeSet {
    var indices: Set<Int> = []
}

/// How much work one pass did: the measure of the engine's efficiency that does not depend on
/// the machine.
struct SolveStatistics: Equatable {
    /// Size and layout requests for any node.
    var requests = 0
    /// Size requests answered from the cache.
    var cacheHits = 0
    /// Leaf sizes computed.
    var leafSizes = 0
    /// Flex algorithm runs of a container, for its size or its layout.
    var containerRuns = 0
}

/// One pass over one tree. Nodes are flattened in pre-order so that every node has a stable
/// index for the measurement cache. The cache lives exactly as long as the pass and has no
/// size limit: a container measures each child several times with the same constraints, and
/// evicting those entries makes nested layouts exponential in depth.
struct Solver {
    var nodes: [FlatNode] = []
    var frames: [LayoutRect?] = []
    var cache: [MeasureKey: LayoutSize] = [:]
    var baselines: [BaselineKey: Double?] = [:]
    /// Set just before a container is laid out only to learn its baseline; the container
    /// clears it on entry and reports the baseline in `lastBaseline`.
    var wantsBaseline = false
    var lastBaseline: Double?
    var statistics = SolveStatistics()
    /// Nodes whose width variants were chosen without a definite parent width. Choosing a
    /// style is a read that most steps do without mutating the solver, so the record is kept
    /// in an object of the pass instead of in the solver's own fields.
    let variantsWithoutWidth = NodeSet()
    var trace: [LayoutTraceEvent] = []
    let context: LayoutContext
    /// Where the pass started on the stack, and how far below it it may go.
    let stackOrigin: UInt
    let stackBudget: UInt?

    init(root: LayoutNode, context: LayoutContext) throws {
        self.context = context
        stackOrigin = Solver.stackAddress()
        stackBudget = context.stackBudget.map { UInt(max(0, $0)) }
        try flatten(root)
        frames = Array(repeating: nil, count: nodes.count)
        cache.reserveCapacity(nodes.count * 2)
    }

    /// Flattens the tree in pre-order. It recurses once per level like the solver, so it
    /// checks the stack budget too: a tree too deep for the thread fails here before it
    /// crashes it.
    @discardableResult
    private mutating func flatten(_ node: LayoutNode) throws -> Int {
        try checkStack()
        let index = nodes.count
        nodes.append(
            FlatNode(
                id: node.id,
                style: node.style,
                variants: node.variants,
                content: node.content,
                direction: node.direction,
                children: [],
                hasAspectRatio: node.style.aspectRatio != nil
                    || node.variants.contains { $0.style.aspectRatio != nil },
                flowOrder: FlatNode.flowOrder(node.style),
                dependsOnParent: !node.variants.isEmpty || node.style.hasPercentageSize
            )
        )
        var children: [Int] = []
        children.reserveCapacity(node.children.count)
        for child in node.children {
            children.append(try flatten(child))
        }
        nodes[index].children = children
        nodes[index].sizesWidthFirst =
            node.style.wrapsRow || node.variants.contains { $0.style.wrapsRow }
            || node.children.contains { !$0.variants.isEmpty || $0.style.hasPercentageWidth }
        return index
    }

    /// Throws when the pass has gone deeper into the stack than its budget allows. The
    /// distance is taken either way, so it does not matter which way the stack grows.
    func checkStack() throws {
        guard let stackBudget else { return }

        let here = Solver.stackAddress()
        let used = here > stackOrigin ? here - stackOrigin : stackOrigin - here
        if used > stackBudget { throw LayoutStackExhausted() }
    }

    /// An address in the caller's frame.
    @inline(never)
    static func stackAddress() -> UInt {
        var marker: UInt8 = 0
        return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
    }

    /// The first baseline of node `index` laid out at `size`, from its top edge, or `nil`
    /// when it has none (the caller then uses its bottom edge). A leaf's baseline is its
    /// content's; a container's is its first item's (CSS Flexbox §8.5).
    mutating func baseline(_ index: Int, size: LayoutSize, parent: OptionalSize) throws -> Double? {
        let key = BaselineKey(
            node: index,
            size: OptionalSize(width: size.width, height: size.height),
            parent: nodes[index].dependsOnParent ? parent : OptionalSize()
        )
        if let cached = baselines[key] { return cached }

        let result: Double?
        if nodes[index].children.isEmpty {
            let own = ownSize(
                index,
                known: OptionalSize(width: size.width, height: size.height),
                parent: parent
            )
            result = nodes[index].content.map {
                own.padding.top + $0.baseline(width: max(0, size.width - own.paddingWidth))
            }
        } else {
            wantsBaseline = true
            _ = try flexLayout(
                index,
                known: OptionalSize(width: size.width, height: size.height),
                parent: parent,
                available: AvailableSize(
                    width: .definite(size.width),
                    height: .definite(size.height)
                ),
                mode: .size
            )
            result = lastBaseline
            lastBaseline = nil
        }
        baselines[key] = result
        return result
    }

    /// The style of node `index` for the width its parent gives it (`parentWidth`, the base
    /// of its percentages): its last variant whose minimum width that reaches, else its base
    /// style. Without a definite width the base style applies.
    @inline(never)
    func style(_ index: Int, parentWidth: Double?) -> FlexStyle {
        guard !nodes[index].variants.isEmpty else { return nodes[index].style }

        guard let width = parentWidth else {
            variantsWithoutWidth.indices.insert(index)
            return nodes[index].style
        }

        var chosen = nodes[index].style
        for variant in nodes[index].variants where variant.minWidth <= width + 1e-9 {
            chosen = variant.style
        }
        return chosen
    }

    /// The border-box size of node `index`. `known` sizes are final and used as-is; `parent`
    /// is the containing block for percentages; `available` constrains everything else.
    /// With `contentOnly` the node's own size and min/max along that axis are ignored: the
    /// result is the size of its content along it, which is what a min-content or max-content
    /// *size* means in CSS (as opposed to a contribution, which respects the node's own size
    /// properties). The other axis keeps its own sizes, since they can shape the content.
    @inline(never)
    mutating func compute(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        mode: RunMode,
        contentOnly: Axis? = nil,
        definite: DefiniteAxes = .both
    ) throws -> LayoutSize {
        statistics.requests += 1
        if case .size = mode {
            let key = MeasureKey(
                node: index,
                known: known,
                parent: nodes[index].dependsOnParent ? parent : OptionalSize(),
                available: available,
                contentOnly: contentOnly,
                definite: definite
            )
            if let cached = cache[key] {
                statistics.cacheHits += 1
                if context.trace != nil {
                    traceMeasure(index, known, available, cached, cached: true)
                }
                return cached
            }

            let size = try computeUncached(
                index,
                known,
                parent,
                available,
                mode,
                contentOnly,
                definite
            )
            cache[key] = size
            if context.trace != nil {
                traceMeasure(index, known, available, size, cached: false)
            }
            return size
        }

        return try computeUncached(index, known, parent, available, mode, contentOnly, definite)
    }

    @inline(never)
    private mutating func computeUncached(
        _ index: Int,
        _ known: OptionalSize,
        _ parent: OptionalSize,
        _ available: AvailableSize,
        _ mode: RunMode,
        _ contentOnly: Axis?,
        _ definite: DefiniteAxes
    ) throws -> LayoutSize {
        if let width = known.width, let height = known.height, case .size = mode {
            return LayoutSize(width: width, height: height)
        }

        if nodes[index].children.isEmpty {
            statistics.leafSizes += 1
            return leafSize(
                index,
                known: known,
                parent: parent,
                available: available,
                contentOnly: contentOnly
            )
        }

        statistics.containerRuns += 1
        return try flexLayout(
            index,
            known: known,
            parent: parent,
            available: available,
            mode: mode,
            contentOnly: contentOnly,
            definite: definite
        )
    }

    private mutating func traceMeasure(
        _ index: Int,
        _ known: OptionalSize,
        _ available: AvailableSize,
        _ size: LayoutSize,
        cached: Bool
    ) {
        let id = nodes[index].id
        guard let request = context.trace, request.includes(.measure, id) else { return }

        trace.append(
            .measured(
                id,
                width: known.width.map { .definite($0) } ?? available.width,
                height: known.height.map { .definite($0) } ?? available.height,
                size: size,
                cached: cached
            )
        )
    }

    /// A leaf is its content plus padding, unless a size is known or specified. With an
    /// aspect ratio, a missing side follows from the other one — but never smaller than the
    /// content when that side's minimum is `auto` (CSS Sizing 4 §5.2.1) — for a height, when
    /// the height is `auto` too: a percentage height that behaves as `auto` does not count in
    /// Chromium — so content does not
    /// overflow a box that only got its size from the ratio. A content size (`contentOnly`)
    /// ignores the leaf's own width/height, but still follows the ratio from a known side.
    @inline(never)
    private func leafSize(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        contentOnly: Axis?
    ) -> LayoutSize {
        let style = self.style(index, parentWidth: parent.width)
        let own = ownSize(
            index,
            style: style,
            known: known,
            parent: parent,
            contentOnly: contentOnly,
            ratio: .none
        )
        // Measured content (text) gets its width first — the known width, or the constraint
        // on the width — and its height from that width.
        let content = (nodes[index].content ?? .size(.zero)).size(
            knownWidth: own.width.map { max(0, $0 - own.paddingWidth) },
            available: available.width.shrunk(by: own.paddingWidth)
        )
        let contentWidth = content.width + own.paddingWidth
        let contentHeight = content.height + own.paddingHeight
        var width = own.width
        var height = own.height

        if let ratio = style.aspectRatio, ratio > 0 {
            if width == nil && height == nil {
                // Min/max heights limit the width too, through the ratio (CSS Sizing 4 §5.2); so
                // does the vertical padding, below which the height cannot go.
                let minHeight = style.minHeight.resolve(parent.height) ?? 0
                let maxHeight = style.maxHeight.resolve(parent.height) ?? .infinity
                width = clamp(
                    max(
                        max(minHeight, own.paddingHeight) * ratio,
                        min(maxHeight * ratio, contentWidth)
                    ),
                    own.minWidth,
                    own.maxWidth,
                    own.paddingWidth
                )
            }

            if let base = width, height == nil {
                height = ratioDependent(
                    base / ratio,
                    content: contentHeight,
                    minimum: own.minHeight,
                    maximum: own.maxHeight,
                    floor: own.paddingHeight,
                    automaticMinimum: style.minHeight == .auto
                        && (style.height == .auto || contentOnly == .vertical)
                )
            } else if let base = height, width == nil {
                // The automatic minimum of a width is the content's min-content width.
                let minContentWidth =
                    (nodes[index].content?.minContentWidth ?? 0) + own.paddingWidth
                width = ratioDependent(
                    base * ratio,
                    content: minContentWidth,
                    minimum: own.minWidth,
                    maximum: own.maxWidth,
                    floor: own.paddingWidth,
                    automaticMinimum: style.minWidth == .auto
                )
            }
        }

        let finalWidth = width ?? clamp(contentWidth, own.minWidth, own.maxWidth, own.paddingWidth)
        if height == nil, case .measured = nodes[index].content,
            abs(finalWidth - contentWidth) > 1e-9
        {
            // The width was clamped or given: measured content wraps to the final width.
            let wrapped = (nodes[index].content ?? .size(.zero)).size(
                knownWidth: max(0, finalWidth - own.paddingWidth),
                available: .definite(max(0, finalWidth - own.paddingWidth))
            )
            height = clamp(
                wrapped.height + own.paddingHeight,
                own.minHeight,
                own.maxHeight,
                own.paddingHeight
            )
        }

        return LayoutSize(
            width: finalWidth,
            height: height ?? clamp(contentHeight, own.minHeight, own.maxHeight, own.paddingHeight)
        )
    }

    /// A size that follows from the aspect ratio, raised to the content size when the axis has
    /// an automatic minimum (capped by the maximum), then clamped as usual.
    @inline(never)
    func ratioDependent(
        _ value: Double,
        content: Double,
        minimum: Double,
        maximum: Double,
        floor: Double,
        automaticMinimum: Bool
    ) -> Double {
        let automatic = automaticMinimum ? min(content, maximum) : 0
        return clamp(max(value, automatic), minimum, maximum, floor)
    }

    /// A node's own sizes from `known` or its style (percentages against `parent`), with the
    /// aspect ratio transferred when exactly one side is definite. Min/max are border-box;
    /// an `auto` minimum is zero here — the flex item automatic minimum is the parent's job.
    @inline(never)
    func ownSize(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        contentOnly: Axis? = nil,
        ratio: RatioTransfer = .size,
        definite: DefiniteAxes = .both
    ) -> OwnSize {
        ownSize(
            index,
            style: style(index, parentWidth: parent.width),
            known: known,
            parent: parent,
            contentOnly: contentOnly,
            ratio: ratio,
            definite: definite
        )
    }

    /// `ownSize` for a node whose style for this parent is already at hand.
    @inline(never)
    func ownSize(
        _ index: Int,
        style: FlexStyle,
        known: OptionalSize,
        parent: OptionalSize,
        contentOnly: Axis? = nil,
        ratio: RatioTransfer = .size,
        definite: DefiniteAxes = .both
    ) -> OwnSize {
        let padding = style.padding.physical(nodes[index].direction)
        let paddingWidth = max(0, padding.left) + max(0, padding.right)
        let paddingHeight = max(0, padding.top) + max(0, padding.bottom)
        // A content size ignores the node's own min/max as well as its own width/height.
        let ignoreWidth = contentOnly == .horizontal
        let ignoreHeight = contentOnly == .vertical
        let minWidth = ignoreWidth ? 0 : style.minWidth.resolve(parent.width) ?? 0
        let minHeight = ignoreHeight ? 0 : style.minHeight.resolve(parent.height) ?? 0
        let maxWidth = ignoreWidth ? .infinity : style.maxWidth.resolve(parent.width) ?? .infinity
        let maxHeight =
            ignoreHeight ? .infinity : style.maxHeight.resolve(parent.height) ?? .infinity
        let styleWidth = ignoreWidth ? nil : style.width.resolve(parent.width)
        let styleHeight = ignoreHeight ? nil : style.height.resolve(parent.height)
        let specifiedWidth = styleWidth.map { clamp($0, minWidth, maxWidth, paddingWidth) }
        let specifiedHeight = styleHeight.map { clamp($0, minHeight, maxHeight, paddingHeight) }
        var width = known.width ?? specifiedWidth
        var height = known.height ?? specifiedHeight
        // A width is definite once it is known: widths are resolved top-down from the
        // containing block. Only a height can be known without being definite.
        var definiteWidth = known.width ?? specifiedWidth
        var definiteHeight = known.height.map { definite.height ? $0 : nil } ?? specifiedHeight
        if ratio != .none, let aspectRatio = style.aspectRatio, aspectRatio > 0 {
            if let base = width, height == nil {
                if ratio == .size {
                    height = clamp(base / aspectRatio, minHeight, maxHeight, paddingHeight)
                }
                definiteHeight = definiteWidth.map {
                    clamp($0 / aspectRatio, minHeight, maxHeight, paddingHeight)
                }
            } else if let base = height, width == nil {
                if ratio == .size {
                    width = clamp(base * aspectRatio, minWidth, maxWidth, paddingWidth)
                }
                // A content width is an intrinsic width: percentages of the width stay cyclic
                // while it is measured. A content height is a layout at a known width, where
                // the height the ratio gives is definite.
                if !ignoreWidth {
                    definiteWidth = definiteHeight.map {
                        clamp($0 * aspectRatio, minWidth, maxWidth, paddingWidth)
                    }
                }
            }
        }

        return OwnSize(
            width: width,
            height: height,
            definiteWidth: definiteWidth,
            definiteHeight: definiteHeight,
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            paddingWidth: paddingWidth,
            paddingHeight: paddingHeight,
            padding: padding
        )
    }
}

/// How `ownSize` carries a known side over to the other one through the aspect ratio.
enum RatioTransfer {
    /// The other side's size, and its definite size when the known side is definite.
    case size
    /// Only the definite size — the base for percentages and stretching: the size itself is
    /// left to the content.
    case definiteSize
    case none
}

struct OwnSize {
    /// Known or specified size.
    var width: Double?
    var height: Double?
    /// The same sizes where they are definite — the base for children's percentages.
    var definiteWidth: Double?
    var definiteHeight: Double?
    var minWidth: Double
    var maxWidth: Double
    var minHeight: Double
    var maxHeight: Double
    var paddingWidth: Double
    var paddingHeight: Double
    var padding: Physical<Double>
}

/// Clamps `value` into `[minimum, maximum]` — the minimum wins when they conflict (CSS
/// Sizing §5.2) — and never below `floor` (a border-box cannot be smaller than its padding).
func clamp(_ value: Double, _ minimum: Double, _ maximum: Double, _ floor: Double = 0) -> Double {
    max(floor, max(minimum, min(maximum, value)))
}
