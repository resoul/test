import LayoutCore

/// What one layout pass of a host found: problems in the layouts and, when asked for, what
/// the engine did for chosen nodes. The host hands it to `NodeHost.onLayoutReport`; the
/// adapter decides where it goes.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct LayoutReport: Sendable {
    /// One thing the engine did, for the node it stands for: the node itself, or for a
    /// container of a node's `layoutSpec()`, that node.
    ///
    /// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct Trace: Sendable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let node: NodeID?
        /// Whether the event is about a container of `node`'s layout rather than the node.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let isContainer: Bool
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public let event: LayoutTraceEvent
    }

    /// Whether the pass fit the stack of the thread it was solved on.
    ///
    /// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Stack: Sendable, Hashable {
        /// Solved where it was meant to be.
        case enough
        /// Too deep for the main thread's stack; solved on the host's own thread instead,
        /// one frame later.
        case moved
        /// Too deep for any thread it could be solved on; the pass is rejected.
        case exhausted
    }

    /// `NodeHost.number` of the host.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let host: Int
    /// The pass: it grows with every layout the host starts.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let generation: UInt64
    /// Elements the layouts mention, each place counted.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let elements: Int
    /// Time the engine took.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let duration: Duration
    /// Nodes laid out in more than one place. A node has one frame, so such a pass is
    /// rejected: the tree keeps the frames and subnodes of the pass before.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let duplicates: [NodeID]
    /// Whether the pass was rejected — for elements laid out twice, nodes or not, or for a
    /// tree too deep for the stack.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isRejected: Bool
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let stack: Stack
    /// Nodes whose `Breakpoint` or `from:` values had no width to choose by, at least while
    /// being measured, and took the narrow side: their parent sized itself to its content.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let variantsWithoutWidth: [NodeID]
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let trace: [Trace]

    /// Whether the pass found something to fix in the layouts — including a tree deeper than
    /// the main thread's stack allows, even when it could still be solved elsewhere.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var hasProblems: Bool { isRejected || stack != .enough || !variantsWithoutWidth.isEmpty }

    /// One line for the pass, then one per traced event. Every line names the host and the
    /// pass, and every field is always there (`none` when empty), so lines of several hosts
    /// and passes stay readable when they interleave.
    ///
    ///     [layout] pass host=1 gen=4 elements=12 ms=0.412 rejected=no stack=enough duplicates=none widthless=#7
    ///     [layout] measure host=1 gen=4 #7 width=max-content height=max-content size=120x40 cached=no
    ///
    /// Ownership: returns values. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var lines: [String] {
        var lines = [
            "[layout] pass host=\(host) gen=\(generation) elements=\(elements) "
                + "ms=\(LayoutReportFormat.milliseconds(duration)) "
                + "rejected=\(isRejected ? "yes" : "no") "
                + "stack=\(stack) duplicates=\(LayoutReportFormat.list(duplicates.map(\.description))) "
                + "widthless=\(LayoutReportFormat.list(variantsWithoutWidth.map(\.description)))"
        ]
        for entry in trace {
            let node = entry.node.map { "\($0)\(entry.isContainer ? "/container" : "")" } ?? "none"
            lines.append(
                LayoutReportFormat.line(
                    entry.event,
                    host: "\(host)",
                    generation: generation,
                    subject: node
                )
            )
        }
        return lines
    }
}
