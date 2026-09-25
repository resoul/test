import Foundation

/// Opaque identity of a layout element. The adapter that builds the tree (nodes, `UIView`,
/// `NSView`) chooses the values and maps them back to its own objects.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LayoutID: Sendable, Hashable, CustomStringConvertible {
    let raw: UInt64

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ raw: UInt64) {
        self.raw = raw
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var description: String { "#\(raw)" }
}

/// One element of the immutable input tree. A node without children is a leaf; its
/// `content` is what it shows (a fixed size like an image, or measured content like text),
/// excluding `padding`.
///
/// Ownership: value type; the tree is an immutable snapshot the caller builds and may send to
/// any task. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LayoutNode: Sendable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var id: LayoutID
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var style: FlexStyle
    /// Content of a leaf; ignored for a node with children.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var content: LeafContent?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var direction: LayoutDirection
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var children: [LayoutNode]
    /// Styles that replace `style` when the width the parent gives this node — the width
    /// its percentages resolve against — reaches `minWidth`. The last matching variant wins;
    /// with no definite width the node keeps `style`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var variants: [StyleVariant]

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        id: LayoutID,
        style: FlexStyle = FlexStyle(),
        content: LeafContent? = nil,
        direction: LayoutDirection = .leftToRight,
        children: [LayoutNode] = [],
        variants: [StyleVariant] = []
    ) {
        self.id = id
        self.style = style
        self.content = content
        self.direction = direction
        self.children = children
        self.variants = variants.sorted { $0.minWidth < $1.minWidth }
    }
}

/// A style a node takes from a width on (see `LayoutNode.variants`).
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct StyleVariant: Sendable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var minWidth: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var style: FlexStyle

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(minWidth: Double, style: FlexStyle) {
        self.minWidth = minWidth
        self.style = style
    }
}

/// Frames of every node of one layout pass, in the root's coordinate space.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LayoutResult: Sendable {
    /// Frames in pre-order of the input tree, for the nodes that were laid out: a node with
    /// `display: .none`, and everything inside it, has none.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frames: [(id: LayoutID, frame: LayoutRect)]

    /// Identities that appeared more than once in the input. Their frames are ambiguous: only
    /// the first occurrence is reachable through `frame(for:)`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let duplicateIDs: Set<LayoutID>

    /// Nodes whose width variants had to be chosen without a definite width at least once:
    /// their parent was sizing itself to its content, so the base style was taken instead
    /// of guessing. Their size can then come from one variant and their layout from another.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let variantsWithoutWidth: Set<LayoutID>

    /// What the pass did for the nodes `LayoutContext.trace` asked about, in the order it
    /// did it; empty when nothing was asked.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let trace: [LayoutTraceEvent]

    /// The work the pass did.
    let statistics: SolveStatistics

    private let index: [LayoutID: Int]

    init(
        frames: [(id: LayoutID, frame: LayoutRect)],
        variantsWithoutWidth: Set<LayoutID> = [],
        trace: [LayoutTraceEvent] = [],
        statistics: SolveStatistics = .init()
    ) {
        self.frames = frames
        self.variantsWithoutWidth = variantsWithoutWidth
        self.trace = trace
        self.statistics = statistics
        var index: [LayoutID: Int] = [:]
        var duplicates: Set<LayoutID> = []
        for (offset, entry) in frames.enumerated() {
            if index[entry.id] != nil {
                duplicates.insert(entry.id)
                continue
            }

            index[entry.id] = offset
        }
        self.index = index
        self.duplicateIDs = duplicates
    }

    /// The frame of `id`, or `nil` when the id was not in the input or was not laid out.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func frame(for id: LayoutID) -> LayoutRect? {
        index[id].map { frames[$0].frame }
    }
}

/// Execution context of one layout pass: the cancellation check and what to trace.
///
/// Ownership: value type; the closure is owned by whoever scheduled the pass. Isolation:
/// `isCancelled` is called from the solving task. Errors: none. Cancellation: see
/// `isCancelled`.
public struct LayoutContext: Sendable {
    /// Polled at checkpoints: every container, and every 256 items of a container.
    ///
    /// Ownership: value. Isolation: called on the solving task. Errors: none. Cancellation:
    /// returning `true` makes the pass throw `LayoutCancelled`.
    public var isCancelled: @Sendable () -> Bool

    /// What the pass records in `LayoutResult.trace`; `nil` records nothing and costs
    /// nothing.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var trace: LayoutTraceRequest?

    /// Bytes of stack the pass may use below the point where it starts; `nil` sets no
    /// limit. The solver recurses once per nesting level, so a tree deep enough for the
    /// thread would otherwise crash it; over the budget the pass throws
    /// `LayoutStackExhausted` instead. `currentThreadStackBudget` suits the calling thread.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var stackBudget: Int?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        isCancelled: @escaping @Sendable () -> Bool = { false },
        trace: LayoutTraceRequest? = nil,
        stackBudget: Int? = nil
    ) {
        self.isCancelled = isCancelled
        self.trace = trace
        self.stackBudget = stackBudget
    }

    /// A budget for a pass on the calling thread: its stack size less a reserve for the
    /// frames already on it and those the pass calls into (measuring text, a view's
    /// `sizeThatFits`). `nil` when the thread does not report a size. The size a platform
    /// reports can be smaller than the real one — Apple platforms report 512 KiB for the
    /// main thread, which has 1 MiB or more — so the budget errs on the safe side.
    ///
    /// Ownership: value. Isolation: reads the calling thread. Errors: none. Cancellation:
    /// not applicable.
    public static var currentThreadStackBudget: Int? {
        let size = Thread.current.stackSize
        guard size > 0 else { return nil }

        return max(64 << 10, size - stackReserve)
    }

    /// Stack left for everything but the solver's own recursion.
    static let stackReserve = 128 << 10

    /// A context that cancels when the current `Task` is cancelled.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: follows the task.
    public static var currentTask: LayoutContext {
        LayoutContext(isCancelled: { Task.isCancelled })
    }

    func checkpoint() throws {
        if isCancelled() { throw LayoutCancelled() }
    }
}

/// Thrown when a pass is cancelled. A cancelled pass produces no result — never a partial one.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: this is the signal.
public struct LayoutCancelled: Error, Sendable {}

/// Thrown when a pass would need more stack than `LayoutContext.stackBudget`: the tree is too
/// deep for this thread. The pass produces no result; solving it on a thread with a larger
/// stack gives the layout.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LayoutStackExhausted: Error, Sendable {}
