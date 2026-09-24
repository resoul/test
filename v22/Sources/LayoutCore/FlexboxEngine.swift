/// CSS Flexbox layout of an immutable `LayoutNode` tree (CSS Flexible Box Layout Module
/// Level 1, §9). A pure function of its input: no shared state, no platform objects, no
/// output besides the returned value — safe to run on any task.
///
/// Ownership: stateless. Isolation: none. Errors: `LayoutCancelled` only. Cancellation:
/// through `LayoutContext`; a cancelled pass returns nothing.
public enum FlexboxEngine {
    /// Lays out `root` as if a host gave it exactly `size`, and returns every node's frame in
    /// the root's coordinate space (the root itself is at the origin).
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: throws `LayoutCancelled` when
    /// `context` reports cancellation. Cancellation: checked at every container and every 256
    /// items; nothing partial is returned.
    public static func layout(
        _ root: LayoutNode,
        size: LayoutSize,
        context: LayoutContext = LayoutContext()
    ) throws -> LayoutResult {
        var solver = Solver(root: root, context: context)
        solver.frames[0] = LayoutRect(origin: .zero, size: size)
        _ = try solver.compute(
            0,
            known: OptionalSize(width: size.width, height: size.height),
            parent: OptionalSize(width: size.width, height: size.height),
            available: AvailableSize(width: .definite(size.width), height: .definite(size.height)),
            mode: .layout(.zero)
        )
        return LayoutResult(
            frames: solver.nodes.indices.map { (solver.nodes[$0].id, solver.frames[$0]) }
        )
    }

    /// The size `root` takes under the given available space when nothing else fixes it —
    /// what a host asks for `sizeThatFits`/`intrinsicContentSize`.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: throws `LayoutCancelled`.
    /// Cancellation: as `layout`.
    public static func measure(
        _ root: LayoutNode,
        width: AvailableSpace,
        height: AvailableSpace,
        context: LayoutContext = LayoutContext()
    ) throws -> LayoutSize {
        var solver = Solver(root: root, context: context)
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
    let content: LeafContent?
    let direction: LayoutDirection
    var children: [Int]
}

struct MeasureKey: Hashable {
    let node: Int
    let known: OptionalSize
    let parent: OptionalSize
    let available: AvailableSize
    let contentOnly: Axis?
    let definite: DefiniteAxes
}

/// One pass over one tree. Nodes are flattened in pre-order so that every node has a stable
/// index for the measurement cache. The cache lives exactly as long as the pass and has no
/// size limit: a container measures each child several times with the same constraints, and
/// evicting those entries makes nested layouts exponential in depth.
struct Solver {
    var nodes: [FlatNode] = []
    var frames: [LayoutRect] = []
    var cache: [MeasureKey: LayoutSize] = [:]
    let context: LayoutContext

    init(root: LayoutNode, context: LayoutContext) {
        self.context = context
        flatten(root)
        frames = Array(repeating: LayoutRect(x: 0, y: 0, width: 0, height: 0), count: nodes.count)
    }

    @discardableResult
    private mutating func flatten(_ node: LayoutNode) -> Int {
        let index = nodes.count
        nodes.append(
            FlatNode(
                id: node.id,
                style: node.style,
                content: node.content,
                direction: node.direction,
                children: []
            )
        )
        var children: [Int] = []
        children.reserveCapacity(node.children.count)
        for child in node.children {
            children.append(flatten(child))
        }
        nodes[index].children = children
        return index
    }

    /// The border-box size of node `index`. `known` sizes are final and used as-is; `parent`
    /// is the containing block for percentages; `available` constrains everything else.
    /// With `contentOnly` the node's own size and min/max along that axis are ignored: the
    /// result is the size of its content along it, which is what a min-content or max-content
    /// *size* means in CSS (as opposed to a contribution, which respects the node's own size
    /// properties). The other axis keeps its own sizes, since they can shape the content.
    mutating func compute(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        mode: RunMode,
        contentOnly: Axis? = nil,
        definite: DefiniteAxes = .both
    ) throws -> LayoutSize {
        if case .size = mode {
            let key = MeasureKey(
                node: index,
                known: known,
                parent: parent,
                available: available,
                contentOnly: contentOnly,
                definite: definite
            )
            if let cached = cache[key] { return cached }

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
            return size
        }

        return try computeUncached(index, known, parent, available, mode, contentOnly, definite)
    }

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
            return leafSize(
                index,
                known: known,
                parent: parent,
                available: available,
                contentOnly: contentOnly
            )
        }

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

    /// A leaf is its content plus padding, unless a size is known or specified. With an
    /// aspect ratio, a missing side follows from the other one — but never smaller than the
    /// content when that side's minimum is `auto` (CSS Sizing 4 §5.2.1), so content does not
    /// overflow a box that only got its size from the ratio. A content size (`contentOnly`)
    /// ignores the leaf's own width/height, but still follows the ratio from a known side.
    private func leafSize(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        available: AvailableSize,
        contentOnly: Axis?
    ) -> LayoutSize {
        let node = nodes[index]
        let style = node.style
        let own = ownSize(
            index,
            known: known,
            parent: parent,
            contentOnly: contentOnly,
            transferRatio: false
        )
        // Measured content (text) gets its width first — the known width, or the constraint
        // on the width — and its height from that width.
        let content = (node.content ?? .size(.zero)).size(
            knownWidth: own.width.map { max(0, $0 - own.paddingWidth) },
            available: available.width.shrunk(by: own.paddingWidth)
        )
        let contentWidth = content.width + own.paddingWidth
        let contentHeight = content.height + own.paddingHeight
        var width = own.width
        var height = own.height

        if let ratio = style.aspectRatio, ratio > 0 {
            if width == nil && height == nil {
                // Min/max heights limit the width too, through the ratio (CSS Sizing 4 §5.2).
                let minHeight = style.minHeight.resolve(parent.height) ?? 0
                let maxHeight = style.maxHeight.resolve(parent.height) ?? .infinity
                width = clamp(
                    max(minHeight * ratio, min(maxHeight * ratio, contentWidth)),
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
                )
            } else if let base = height, width == nil {
                width = ratioDependent(
                    base * ratio,
                    content: contentWidth,
                    minimum: own.minWidth,
                    maximum: own.maxWidth,
                    floor: own.paddingWidth,
                    automaticMinimum: style.minWidth == .auto
                )
            }
        }

        let finalWidth = width ?? clamp(contentWidth, own.minWidth, own.maxWidth, own.paddingWidth)
        if height == nil, case .measured = node.content, abs(finalWidth - contentWidth) > 1e-9 {
            // The width was clamped or given: measured content wraps to the final width.
            let wrapped = (node.content ?? .size(.zero)).size(
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
    private func ratioDependent(
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
    func ownSize(
        _ index: Int,
        known: OptionalSize,
        parent: OptionalSize,
        contentOnly: Axis? = nil,
        transferRatio: Bool = true,
        definite: DefiniteAxes = .both
    ) -> OwnSize {
        let node = nodes[index]
        let style = node.style
        let padding = style.padding.physical(node.direction)
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
        if transferRatio, let ratio = style.aspectRatio, ratio > 0 {
            if let base = width, height == nil {
                height = clamp(base / ratio, minHeight, maxHeight, paddingHeight)
                definiteHeight = definiteWidth.map {
                    clamp($0 / ratio, minHeight, maxHeight, paddingHeight)
                }
            } else if let base = height, width == nil {
                width = clamp(base * ratio, minWidth, maxWidth, paddingWidth)
                definiteWidth = definiteHeight.map {
                    clamp($0 * ratio, minWidth, maxWidth, paddingWidth)
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
