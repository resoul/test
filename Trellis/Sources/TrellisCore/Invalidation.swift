/// Why a node's subtree needs re-layout or re-paint, kept as independent, combinable causes.
///
/// `.structure` and `.geometry` almost always travel together — a tree-shape change forces a
/// remeasure — but `.appearance` never implies either: a paint-only change must not schedule a
/// snapshot/solve pass (C12/C13 read this to decide whether to do that work at all).
/// `.arrangement` is the resolver's own reason (C32); `.semantics` (A03) is the third
/// independent channel — metadata for focus and assistive technology, which needs neither a
/// layout pass nor a repaint.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct DirtyReasons: OptionSet, Sendable, Hashable {
    /// The underlying bitmask.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: UInt8

    /// Creates a reason set from a raw bitmask.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// A node's own child list — count, membership, or order — changed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let structure = DirtyReasons(rawValue: 1 << 0)

    /// Reserved for the future Arrangement resolver (C21); nothing produces this yet.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let arrangement = DirtyReasons(rawValue: 1 << 1)

    /// A layout-affecting style value changed, on this node or a descendant.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let geometry = DirtyReasons(rawValue: 1 << 2)

    /// A paint-only appearance value changed; layout is unaffected.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let appearance = DirtyReasons(rawValue: 1 << 3)

    /// Focus or accessibility metadata changed (A03, D41) — `Node.focus`,
    /// `Node.accessibility`, `ControlNode.isEnabled`. Neither layout nor paint is affected:
    /// the host republishes the semantic snapshot from the frames already committed.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let semantics = DirtyReasons(rawValue: 1 << 4)

    /// A paint-only display/raster value changed (ADR 0014, T04) — a color-only `TextNode.
    /// textStyle` write. Distinct from `.appearance`: this is an asynchronous display pass
    /// (`DisplayScheduler`, T06), not `LayerRenderer.applyAppearance`'s synchronous commit-time
    /// work, so it needs its own bit rather than reusing `.appearance`'s.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let display = DirtyReasons(rawValue: 1 << 5)
}

extension DirtyReasons {
    /// Whether this invalidation describes a visual, layout, or arrangement mutation that can
    /// make an animation scope relevant. Semantic metadata alone deliberately does not.
    package var isAnimationRelevant: Bool {
        !intersection([.structure, .arrangement, .geometry, .appearance, .display]).isEmpty
    }
}

extension DirtyReasons: CustomStringConvertible {
    /// Compact, stable ordering for log lines: `"structure,geometry"`, or `"none"` when empty.
    ///
    /// Ownership: returns a new string. Isolation: none. Errors: none. Cancellation: not applicable.
    public var description: String {
        var names: [String] = []
        if contains(.structure) { names.append("structure") }
        if contains(.arrangement) { names.append("arrangement") }
        if contains(.geometry) { names.append("geometry") }
        if contains(.appearance) { names.append("appearance") }
        if contains(.semantics) { names.append("semantics") }
        if contains(.display) { names.append("display") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

/// Suppresses the invalidation ping (`Node.onInvalidate`) for the duration of `perform`,
/// without losing dirty state, so the future Arrangement resolver (C21) can mutate many
/// nodes in one pass without a host observing a half-rebuilt tree mid-resolve.
///
/// Nodes still accumulate `pendingReasons`/`pendingOrigin` normally while a transaction is
/// active; each root touched during the transaction registers itself here instead of pinging
/// immediately, and is pinged at most once when the outermost `perform` call returns —
/// including when `body` throws, via `defer`. Nesting only flushes at depth zero, so a
/// transaction started by code that is itself already inside one composes safely.
///
/// This is internal, not public: no public resolver API exists yet (C21–C23), and this type
/// is not meant to be exposed as extensibility surface on its own (mirrors D10's rule for
/// `LayoutContext`).
///
/// Ownership: no owned state beyond deferred root references, released at flush. Isolation:
/// MainActor. Errors: none — `perform` propagates `body`'s own errors via `rethrows`.
/// Cancellation: not applicable; this is synchronous MainActor bookkeeping, not async work.
@MainActor
enum InvalidationTransaction {
    private static var depth = 0
    private static var pendingRoots: [ObjectIdentifier: Node] = [:]

    /// Whether a transaction is currently active anywhere on the call stack.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    static var isActive: Bool { depth > 0 }

    /// Runs `body` with the invalidation ping suppressed, flushing deferred pings once the
    /// outermost call returns or throws.
    ///
    /// Ownership: no values are retained beyond the call. Isolation: MainActor. Errors:
    /// propagates whatever `body` throws. Cancellation: not applicable.
    static func perform<Result>(_ body: () throws -> Result) rethrows -> Result {
        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                let roots = pendingRoots.values
                pendingRoots.removeAll()
                for root in roots {
                    root.fireDeferredInvalidationIfNeeded()
                }
            }
        }
        return try body()
    }

    /// Registers `root` to receive its deferred ping when the outermost transaction ends.
    ///
    /// Ownership: retains `root` only until the next flush. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    static func deferCallback(for root: Node) {
        pendingRoots[ObjectIdentifier(root)] = root
    }
}
