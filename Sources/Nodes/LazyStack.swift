import LayoutCore
import StateCore

/// A column (or row) of nodes for `items` that lays out only the items near the part of it
/// that shows — on screen and about a screen before and after — however many items there
/// are. It goes inside a `Scroll`, alone or with other nodes around it:
///
///     private let rows = NodeCache<Post.ID, PostRow> { _ in PostRow() }
///     private lazy var posts = LazyStack(estimatedLength: 72) { [rows] post in
///         rows[post.id].showing(post)
///     }
///     private lazy var feed = Scroll(.vertical, content: posts)
///
///     override func update() {
///         posts.items = model.posts.value
///     }
///
/// `content` is asked for the node of an item when the item comes near the window, in the
/// layout pass; with a `NodeCache` the item keeps its node while it stays near, and the node
/// is released once the item is far away. Scrolling lays the tree out again only when the
/// window comes close to the end of what is laid out, not on every move.
///
/// Items not laid out take the length they had when they were last laid out at the stack's
/// present width, or `estimatedLength` before that: the stack keeps the space of the whole
/// list, and the scroll's range grows or shrinks as items get their real lengths. When items
/// before the window change length, or are added or removed, the scroll moves by as much, so
/// what shows stays where it is — except where the window shows the stack's start, which
/// then shows the new items.
///
/// Across its axis the stack is as wide (or tall) as its parent makes it, and each item is
/// stretched to it.
///
/// Ownership: the stack keeps `content` and the items; the nodes `content` returns are owned
/// by whoever made them, and by the stack while they are mounted. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public final class LazyStack<Item: Identifiable>: Node {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let axis: ScrollAxis

    /// The items, in order from the start.
    ///
    /// Ownership: the stack keeps them. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public var items: [Item] {
        didSet {
            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// The length along `axis` taken by an item that was never laid out.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var estimatedLength: Double {
        didSet {
            guard estimatedLength != oldValue else { return }

            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// How many items stand side by side across `axis` — the columns of a vertical stack,
    /// the rows of a horizontal one. With more than one the stack is a grid: items take equal
    /// shares of the width (or height) in order, and a line is as long as its longest item.
    /// Values below 1 count as 1.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var lanes: Int {
        didSet {
            guard lanes != oldValue else { return }

            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// The space between neighboring items, along `axis` and across it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var spacing: Double {
        didSet {
            guard spacing != oldValue else { return }

            startsAreStale = true
            setNeedsLayout()
        }
    }

    /// The indices of `items` whose nodes the last layout placed.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var laidOutItems: Range<Int> = 0..<0

    private let content: @MainActor (Item) -> Node

    /// Lengths along the axis of items laid out at `measuredAcross`.
    private var measured: [Item.ID: Double] = [:]
    private var measuredAcross: Double?
    /// Where each line of `lanes` items starts from the stack's start, with one more entry
    /// past the last: `starts[i + 1] - spacing` is where line `i` ends.
    private var starts: [Double] = [0]
    private var startsAreStale = true
    /// The items and nodes the last `layoutSpec()` placed, in order.
    private var placed: [(id: Item.ID, node: Node)] = []
    /// The part of the stack, from its start, that the nodes placed cover once laid out;
    /// the ends are unbounded where the first or the last item is among them.
    private var covered: (start: Double, end: Double) = (.infinity, -.infinity)
    /// An item that shows as a layout begins, and where it is then in `scroll`: the layout
    /// is followed by a scroll that puts it back there.
    private var anchor: (id: Item.ID, position: Double, scroll: Scroll)?

    /// A stack of the nodes `content` returns for `items`, along `axis`.
    ///
    /// Ownership: keeps `content`, which must not keep the stack. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(
        _ axis: ScrollAxis = .vertical,
        items: [Item] = [],
        lanes: Int = 1,
        estimatedLength: Double,
        spacing: Double = 0,
        content: @escaping @MainActor (Item) -> Node
    ) {
        self.axis = axis
        self.items = items
        self.lanes = lanes
        self.estimatedLength = estimatedLength
        self.spacing = spacing
        self.content = content
        super.init()
    }

    /// Ownership: returns a value borrowing the nodes of the items laid out. Isolation:
    /// MainActor. Errors: none. Cancellation: none.
    public override func layoutSpec() -> LayoutSpec? {
        updateStarts()
        let host = self.host ?? NodeHost.preparing
        // About a screen before and after the window, so that the next frames of a scroll
        // find their items laid out.
        let reach = host.map { along($0.size) } ?? 0
        // Where the scrolls around are is looked at, not depended on: the stack asks for a
        // layout itself when the window nears the end of what is laid out, not on every move.
        // Before the first layout its place is unknown: the start of the list, one screen of
        // it, and the reach after.
        let span = untracked { visibleSpan() } ?? (start: 0, end: reach)
        let lines = self.lines(from: span.start - reach, to: span.end + reach)
        let range =
            lines.isEmpty
            ? 0..<0 : lines.lowerBound * perLine..<min(items.count, lines.upperBound * perLine)

        untracked { rememberAnchor() }
        placed = range.map { index in (items[index].id, content(items[index])) }
        laidOutItems = range
        let total = length
        let before = lines.isEmpty ? total : starts[lines.lowerBound]
        let after = lines.isEmpty ? 0 : total - end(of: lines.upperBound - 1)
        covered =
            lines.isEmpty
            ? (.infinity, -.infinity)
            : (
                lines.lowerBound == 0 ? -.infinity : before,
                lines.upperBound == lineCount ? .infinity : total - after
            )

        let nodes = placed.map(\.node)
        let stack: LayoutSpec
        if perLine == 1 {
            stack = FlexContainer(axis == .vertical ? .column : .row) {
                for node in nodes {
                    node.flex(shrink: 0)
                }
            }
            .gap(spacing)
        } else {
            stack = FlexContainer(axis == .vertical ? .column : .row) {
                for start in stride(from: 0, to: nodes.count, by: perLine) {
                    line(Array(nodes[start..<min(start + perLine, nodes.count)]))
                }
            }
            .gap(spacing)
        }
        switch axis {
        case .vertical:
            return stack.padding(top: before, bottom: after)
        case .horizontal:
            return stack.padding(leading: before, trailing: after)
        }
    }

    /// One line of a grid: its items side by side in equal shares, and empty shares after
    /// the last items of a line that is not full, so they are as wide as the others.
    private func line(_ nodes: [Node]) -> LayoutSpec {
        let share = { (spec: LayoutSpec) -> LayoutSpec in
            switch self.axis {
            case .vertical:
                spec.flex(grow: 1, shrink: 1, basis: .points(0)).limits(minWidth: .points(0))
            case .horizontal:
                spec.flex(grow: 1, shrink: 1, basis: .points(0)).limits(minHeight: .points(0))
            }
        }
        let empty = perLine - nodes.count
        return FlexContainer(axis == .vertical ? .row : .column) {
            for node in nodes {
                share(node.asLayoutSpec)
            }
            for _ in 0..<empty {
                share(FlexContainer {})
            }
        }
        .gap(spacing)
        .flex(shrink: 0)
    }

    // MARK: - Lengths

    /// Items side by side in a line.
    private var perLine: Int { max(1, lanes) }

    private var lineCount: Int { (items.count + perLine - 1) / perLine }

    /// The length of all lines with the spaces between them.
    private var length: Double {
        items.isEmpty ? 0 : starts[lineCount] - spacing
    }

    private func end(of line: Int) -> Double {
        starts[line + 1] - spacing
    }

    private func updateStarts() {
        guard startsAreStale || starts.count != lineCount + 1 else { return }

        startsAreStale = false
        var starts: [Double] = []
        starts.reserveCapacity(lineCount + 1)
        var position = 0.0
        for first in stride(from: 0, to: items.count, by: perLine) {
            starts.append(position)
            var longest = 0.0
            for item in items[first..<min(first + perLine, items.count)] {
                longest = max(longest, measured[item.id] ?? estimatedLength)
            }
            position += longest + spacing
        }
        starts.append(position)
        self.starts = starts
    }

    /// The lines that take any of the part of the stack from `lower` to `upper`.
    private func lines(from lower: Double, to upper: Double) -> Range<Int> {
        let count = lineCount
        guard count > 0, upper > lower else { return 0..<0 }

        // The first line ending after `lower`, and the first starting at or after `upper`.
        let first = partition(count) { end(of: $0) > lower }
        let last = partition(count) { starts[$0] >= upper }
        return first < last ? first..<last : 0..<0
    }

    /// The first index below `count` for which `isPast` holds, or `count`; `isPast` must hold
    /// for every index after one it holds for.
    private func partition(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if isPast(middle) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    // MARK: - Where it shows

    private var isReversed: Bool {
        axis == .horizontal && (host ?? NodeHost.preparing)?.direction == .rightToLeft
    }

    private func along(_ point: LayoutPoint) -> Double {
        axis == .vertical ? point.y : point.x
    }

    private func along(_ size: LayoutSize) -> Double {
        axis == .vertical ? size.height : size.width
    }

    private func across(_ size: LayoutSize) -> Double {
        axis == .vertical ? size.width : size.height
    }

    /// The part of the stack that shows, from its start along `axis` — within every node
    /// around it that clips its content, and within the host's bounds; `start` is past `end`
    /// when none of it shows. `nil` before the stack is laid out.
    private func visibleSpan() -> (start: Double, end: Double)? {
        guard isMounted, let host else { return nil }

        var start = -Double.infinity
        var end = Double.infinity
        // Where the stack's box starts in the box of `node`.
        var position = 0.0
        var node: Node = self
        while let supernode = node.supernode {
            position += along(node.shownOrigin) - along(supernode.contentOrigin)
            if supernode.appearance.clipsContent {
                start = max(start, -position)
                end = min(end, along(supernode.frame.size) - position)
            }
            node = supernode
        }
        position += along(node.frame.origin)
        start = max(start, -position)
        end = min(end, along(host.size) - position)
        guard isReversed else { return (start, end) }

        // A row laid out from the right starts at its right edge.
        return (frame.size.width - end, frame.size.width - start)
    }

    /// Where `node`, placed by the stack, starts from the stack's start.
    private func start(of node: Node) -> Double {
        guard isReversed else { return along(node.frame.origin) }

        return frame.size.width - node.frame.origin.x - node.frame.size.width
    }

    /// Whether the stack's subnodes are the nodes its last `layoutSpec()` placed: that
    /// layout has been applied.
    private var placedAreMounted: Bool {
        placed.count == subnodes.count
            && zip(placed, subnodes).allSatisfy { $0.node === $1 && $1.supernode === self }
    }

    // MARK: - Keeping what shows in place

    /// The nearest scroll around the stack along its axis.
    private var scroll: Scroll? {
        var node = supernode
        while let current = node {
            if let scroll = current as? Scroll, scroll.axis == axis { return scroll }

            node = current.supernode
        }
        return nil
    }

    private func rememberAnchor() {
        anchor = nil
        // Showing the start, the window shows what is added there.
        guard let span = visibleSpan(), span.start > 0, span.start < span.end,
            let scroll, placedAreMounted
        else { return }

        for (id, node) in placed {
            let start = start(of: node)
            guard start + along(node.frame.size) > span.start, start < span.end else { continue }

            if let rect = scroll.frame(of: node) {
                anchor = (id, along(rect.origin), scroll)
            }
            return
        }
    }

    /// The layout that placed `placed` was applied: learns the items' lengths, puts what
    /// showed back in place, and asks for another layout if the window is near the end of
    /// what is laid out.
    func layoutApplied() {
        guard placedAreMounted else { return }

        let across = across(frame.size)
        if measuredAcross != across {
            // Lengths at another width no longer hold.
            measured = [:]
            measuredAcross = across
            startsAreStale = true
        }
        for (id, node) in placed {
            let length = along(node.frame.size)
            if measured[id] != length {
                measured[id] = length
                startsAreStale = true
            }
        }
        if let first = placed.first?.node, let last = placed.last?.node {
            covered = (
                laidOutItems.lowerBound == 0 ? -.infinity : start(of: first),
                laidOutItems.upperBound == items.count
                    ? .infinity : start(of: last) + along(last.frame.size)
            )
        }

        if let anchor, let node = placed.first(where: { $0.id == anchor.id })?.node,
            let rect = anchor.scroll.frame(of: node)
        {
            let moved = along(rect.origin) - anchor.position
            if moved != 0 {
                anchor.scroll.shiftOffset(
                    by: axis == .vertical
                        ? LayoutPoint(x: 0, y: moved) : LayoutPoint(x: moved, y: 0)
                )
            }
        }
        anchor = nil
        viewportMoved()
    }

    /// Something around the stack moved: asks for a layout if the window, with half a screen
    /// either side, reaches past what is laid out.
    func viewportMoved() {
        guard let host, let span = visibleSpan() else { return }

        updateStarts()
        let reach = along(host.size) / 2
        let needed = (start: max(0, span.start - reach), end: min(length, span.end + reach))
        guard needed.start < needed.end else { return }

        if needed.start < covered.start || needed.end > covered.end {
            setNeedsLayout()
        }
    }
}

/// A node whose layout depends on where it shows, told by the host after each layout it is
/// in and whenever a scroll moves.
@MainActor
protocol ViewportDependent: AnyObject {
    func layoutApplied()
    func viewportMoved()
}

extension LazyStack: ViewportDependent {}
