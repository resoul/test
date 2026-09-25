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
    /// Whether the pass was rejected — also for elements laid out twice that are not nodes.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isRejected: Bool
    /// Nodes whose `Breakpoint` or `from:` values had no width to choose by, at least while
    /// being measured, and took the narrow side: their parent sized itself to its content.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let variantsWithoutWidth: [NodeID]
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let trace: [Trace]

    /// Whether the pass found something to fix in the layouts.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var hasProblems: Bool { isRejected || !variantsWithoutWidth.isEmpty }

    /// One line for the pass, then one per traced event. Every line names the host and the
    /// pass, and every field is always there (`none` when empty), so lines of several hosts
    /// and passes stay readable when they interleave.
    ///
    ///     [layout] pass host=1 gen=4 elements=12 ms=0.412 rejected=no duplicates=none widthless=#7
    ///     [layout] measure host=1 gen=4 #7 width=max-content height=max-content size=120x40 cached=no
    ///
    /// Ownership: returns values. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var lines: [String] {
        let milliseconds =
            Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        var lines = [
            "[layout] pass host=\(host) gen=\(generation) elements=\(elements) "
                + "ms=\(Self.format(milliseconds)) rejected=\(isRejected ? "yes" : "no") "
                + "duplicates=\(Self.list(duplicates)) widthless=\(Self.list(variantsWithoutWidth))"
        ]
        for entry in trace {
            let node = entry.node.map { "\($0)\(entry.isContainer ? "/container" : "")" } ?? "none"
            switch entry.event {
            case let .measured(_, width, height, size, cached):
                lines.append(
                    "[layout] measure host=\(host) gen=\(generation) \(node) "
                        + "width=\(Self.space(width)) height=\(Self.space(height)) "
                        + "size=\(Self.format(size.width))x\(Self.format(size.height)) "
                        + "cached=\(cached ? "yes" : "no")"
                )
            case let .placed(_, frame):
                lines.append(
                    "[layout] place host=\(host) gen=\(generation) \(node) "
                        + "x=\(Self.format(frame.origin.x)) y=\(Self.format(frame.origin.y)) "
                        + "size=\(Self.format(frame.size.width))x\(Self.format(frame.size.height))"
                )
            }
        }
        return lines
    }

    private static func list(_ nodes: [NodeID]) -> String {
        nodes.isEmpty ? "none" : nodes.map(\.description).joined(separator: ",")
    }

    private static func space(_ space: AvailableSpace) -> String {
        switch space {
        case let .definite(value): format(value)
        case .minContent: "min-content"
        case .maxContent: "max-content"
        }
    }

    /// Up to three decimals, without trailing zeros.
    private static func format(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
