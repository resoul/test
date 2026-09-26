/// Stable cache identity for one measure result — two snapshots with equal identity,
/// revisions, constraint and direction produce the same measurement.
///
/// Ownership: the key is an immutable value owned by the cache caller. Isolation: none. Errors:
/// none. Cancellation: not applicable.
public struct LayoutMeasureCacheKey: Sendable, Hashable {
    /// The measured node's identity.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let treeIdentity: NodeID

    /// The snapshot's structure/geometry revision at capture time.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let contentRevision: UInt64

    /// The snapshot's environment scope revision at capture time.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let environmentRevision: UInt64

    /// The constraint this measurement was performed under.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let constraint: SizeConstraint

    /// The layout direction this measurement was performed under.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let direction: LayoutDirection

    /// Creates a cache key from snapshot revisions and constraints.
    ///
    /// Ownership: the returned key is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        treeIdentity: NodeID,
        contentRevision: UInt64,
        environmentRevision: UInt64,
        constraint: SizeConstraint,
        direction: LayoutDirection
    ) {
        self.treeIdentity = treeIdentity
        self.contentRevision = contentRevision
        self.environmentRevision = environmentRevision
        self.constraint = constraint
        self.direction = direction
    }
}

/// Per-item resolved geometry within a flex line, after grow/shrink resolution.
///
/// Ownership: immutable value owned by the measurement result. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FlexLineItem: Sendable, Hashable {
    /// Identity of the child this geometry belongs to.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let identity: NodeID

    /// Resolved, non-negative size on the container's main axis.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let mainSize: Double

    /// Resolved, non-negative size on the container's cross axis.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let crossSize: Double

    /// Distance from this item's top to its first baseline, or `nil` if it has none.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let baseline: Double?

    /// Creates immutable item geometry, clamping negative sizes to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: invalid
    /// sizes are clamped. Cancellation: not applicable.
    public init(identity: NodeID, mainSize: Double, crossSize: Double, baseline: Double? = nil) {
        self.identity = identity
        self.mainSize = max(0, mainSize)
        self.crossSize = max(0, crossSize)
        self.baseline = baseline
    }
}

/// One resolved flex line: the items that share it and the line's own cross size.
///
/// Ownership: immutable value owned by the measurement result. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FlexLine: Sendable, Hashable {
    /// Items in source order for this line.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let items: [FlexLineItem]

    /// Maximum resolved cross size among this line's items, clamped non-negative.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let crossSize: Double

    /// Creates immutable line geometry, clamping a negative cross size to zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: an
    /// invalid size is clamped. Cancellation: not applicable.
    public init(items: [FlexLineItem], crossSize: Double) {
        self.items = items
        self.crossSize = max(0, crossSize)
    }
}

/// Complete immutable result of a flex measurement pass.
///
/// Ownership: immutable value owned by the caller. Isolation: none — Sendable so it crosses
/// from background solver work. Errors: none. Cancellation: not applicable.
public struct FlexMeasureResult: Sendable, Hashable {
    /// Resolved size of the measured container, including its own padding.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let parentSize: MeasuredSize

    /// Per-line child geometry consumed by the placement pass (`FlexboxPlacement.swift`).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let lines: [FlexLine]

    /// The cache key this result was stored and can be looked up under.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let cacheKey: LayoutMeasureCacheKey

    /// `true` when this node or any node below it carries a `.fraction` size, basis or
    /// min/max. Such a subtree resolves against the space it is given, so its max-content
    /// measurement (main axis `.unspecified`, ADR 0009) is not the same layout as an `.exact`
    /// pass at the same main size and cannot stand in for it — the reuse of ADR 0008 and
    /// `resolveLines` is skipped for it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let dependsOnAvailableSize: Bool

    /// This node's own first baseline at this measurement's constraint — from its `measurer`
    /// when it has one (D49), else the same fixed value `LayoutContentMetrics.firstBaseline`
    /// always reported. A parent aligning this node as a flex item under `alignItems: .baseline`
    /// reads this fresh value, not the static snapshot one, so a measurer whose baseline moves
    /// with wrapping is honored (T03 acceptance: "baseline через измеритель").
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let firstBaseline: Double?

    /// Creates a complete measurement result.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        parentSize: MeasuredSize,
        lines: [FlexLine],
        cacheKey: LayoutMeasureCacheKey,
        dependsOnAvailableSize: Bool = false,
        firstBaseline: Double? = nil
    ) {
        self.parentSize = parentSize
        self.lines = lines
        self.cacheKey = cacheKey
        self.dependsOnAvailableSize = dependsOnAvailableSize
        self.firstBaseline = firstBaseline
    }

    /// Compatibility spelling for callers that only need the aggregate size.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var size: MeasuredSize { parentSize }
}

/// Request-local cache of measurement results, keyed by `(node, revisions, constraint,
/// direction)`.
///
/// Every container measures each child at least twice per pass — once with the main axis
/// `.unspecified` to find its max-content basis (ADR 0009), once under the resolved `.exact`
/// main size for its cross size — and the placement pass measures each level again. Without
/// a hit on the repeated `(child, constraint)` pairs that work multiplies by depth: the
/// 64-entry linear LRU inherited from Weave thrashed on any tree wider than a few dozen
/// nodes and turned nesting into 2^depth measurements (ADR 0007, defects #13). The cache
/// lives for one request and dies with it, so it is a hash map with a bound far above any
/// real tree — `capacity` only guards a pathological input, evicting the oldest quarter in
/// insertion order once it is reached (one entry at a time was O(capacity) per store and
/// turned a run past the bound quadratic, defect #27).
///
/// Ownership: the owning request holds the cache. Isolation: none; a value type moved into
/// the solver task. Errors: none. Cancellation: discarded with the request.
public struct FlexMeasureCache: Sendable {
    /// Hard upper bound on entries — insertion-order eviction beyond it. Not a tuning knob,
    /// and it must stay far above what the quadratic re-measure of the placement pass
    /// (defect #14) produces: a depth-200 chain of 1000 nodes misses ~100k times, and a
    /// bound of 2^16 turned that into thrash and a run that never finished.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let capacity = 1 << 20

    private var entries: [LayoutMeasureCacheKey: FlexMeasureResult] = [:]
    private var insertionOrder: [LayoutMeasureCacheKey] = []
    private var lookupCount = 0
    private var hitCount = 0

    /// Counters of one request's measurement work, for the C31 harness and the defect #24
    /// state-count scan: how many `(node, constraint)` states the pass visited versus how
    /// many it could answer from the cache. Not a rendering contract.
    ///
    /// Ownership: immutable value owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public struct Statistics: Sendable, Hashable {
        /// Number of `lookup` calls — one per `measure` entry.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let lookups: Int

        /// Lookups that returned a stored result.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let hits: Int

        /// Distinct `(node, revisions, constraint, direction)` states stored — the number of
        /// measurements actually performed, minus any evicted beyond `capacity`.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let entries: Int

        /// Largest number of stored states for any single node — the per-node fan-out that
        /// a constraint-dependent basis multiplies by depth (defect #24).
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let maxEntriesPerNode: Int
    }

    /// Current counters; `maxEntriesPerNode` is computed on demand by one pass over the
    /// stored keys.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var statistics: Statistics {
        var perNode: [NodeID: Int] = [:]
        for key in entries.keys { perNode[key.treeIdentity, default: 0] += 1 }

        return Statistics(
            lookups: lookupCount,
            hits: hitCount,
            entries: entries.count,
            maxEntriesPerNode: perNode.values.max() ?? 0
        )
    }

    /// Creates an empty cache.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Stores or replaces the result for `key`.
    ///
    /// Ownership: the result is copied into the cache. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public mutating func store(key: LayoutMeasureCacheKey, result: FlexMeasureResult) {
        if entries.updateValue(result, forKey: key) == nil {
            insertionOrder.append(key)
            if insertionOrder.count > Self.capacity {
                let batch = Self.capacity / 4
                for evicted in insertionOrder.prefix(batch) { entries.removeValue(forKey: evicted) }
                insertionOrder.removeFirst(batch)
            }
        }
    }

    /// Returns the cached result for `key`, if any.
    ///
    /// Ownership: returns a copy. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public mutating func lookup(key: LayoutMeasureCacheKey) -> FlexMeasureResult? {
        lookupCount += 1
        let result = entries[key]
        if result != nil { hitCount += 1 }
        return result
    }
}

/// Pure bottom-up flex measurement over immutable snapshots (D11: the flexbox `LayoutEngine`).
///
/// Ownership: inputs and results are value types. Isolation: none; no live `Node` or platform
/// object is accessed — safe to call from background solver work. Errors: `throws` per D09: a
/// cancelled pass throws `LayoutCancellationError.cancelled` instead of returning a partial or
/// empty result. Cancellation: checked at each container entry, each flex-line boundary and
/// every 256 items inside a line (D09/§3.13; the in-line checkpoint is what C31 measured a
/// need for — a 5000-item line took 21 ms to cancel without it).
public enum FlexboxEngine {
    /// Measures a snapshot recursively from children to parent, using a fresh cache.
    ///
    /// Ownership: the returned result is owned by the caller. Isolation: none. Errors: throws
    /// `LayoutCancellationError.cancelled` if `context` reports cancellation. Cancellation: see
    /// the type-level documentation.
    public static func measureContainer(
        input: LayoutInputSnapshot,
        constraint: SizeConstraint = SizeConstraint(),
        context: LayoutContext = .noCancellation
    ) throws -> FlexMeasureResult {
        var cache = FlexMeasureCache()
        return try measureContainer(
            input: input,
            constraint: constraint,
            context: context,
            cache: &cache
        )
    }

    /// Measures using a caller-owned request-local cache.
    ///
    /// Ownership: the result is owned by the caller; the cache remains owned by the caller.
    /// Isolation: none. Errors: throws `LayoutCancellationError.cancelled` if `context` reports
    /// cancellation. Cancellation: the caller discards `cache` when work is cancelled.
    public static func measureContainer(
        input: LayoutInputSnapshot,
        constraint: SizeConstraint = SizeConstraint(),
        context: LayoutContext = .noCancellation,
        cache: inout FlexMeasureCache
    ) throws -> FlexMeasureResult {
        try measure(input, constraint: constraint, context: context, cache: &cache)
    }

    static func measure(
        _ input: LayoutInputSnapshot,
        constraint: SizeConstraint,
        context: LayoutContext,
        cache: inout FlexMeasureCache
    ) throws -> FlexMeasureResult {
        let key = LayoutMeasureCacheKey(
            treeIdentity: input.identity,
            contentRevision: input.contentRevision,
            environmentRevision: input.environmentRevision,
            constraint: constraint,
            direction: input.direction
        )
        if let cached = cache.lookup(key: key) {
            Log.on(
                .measure,
                CacheOutcome.hit.rawValue,
                node: input.identity,
                "size=\(cached.parentSize.width)x\(cached.parentSize.height)"
            )
            return cached
        }
        let direction = input.style.flexDirection
        let padding = input.style.padding.resolved(for: input.direction)
        let horizontalPadding = padding.left + padding.right
        let verticalPadding = padding.top + padding.bottom
        let parentWidth = constraint.width.knownValue
        let parentHeight = constraint.height.knownValue
        let (availableMain, availableCross) = availableSpace(input: input, constraint: constraint)
        // Children are measured for their max-content basis: the main axis is left
        // `.unspecified` (CSS Flexbox §9.2.3: `flex-basis: auto` with an auto main size is
        // `content`, sized as max-content), the cross axis is bounded by the space this
        // container has. A basis measured under `.atMost(available)` instead depended on the
        // number offered, so every level that then grew or shrank produced a second, different
        // number for its child — 2^depth distinct states (defect #24, ADR 0009).
        let childConstraint = SizeConstraint(
            width: direction.isHorizontal
                ? .unspecified
                : (availableCross.map { .atMost($0) } ?? .unspecified),
            height: direction.isHorizontal
                ? (availableCross.map { .atMost($0) } ?? .unspecified)
                : .unspecified
        )
        let childMeasurements = try input.children.enumerated().map { index, child in
            (
                index,
                try measure(child, constraint: childConstraint, context: context, cache: &cache)
            )
        }
        let dependsOnAvailableSize =
            input.style.hasFractionSize
            || childMeasurements.contains { $0.1.dependsOnAvailableSize }
        // A leaf with a measurer (D49) is measured against this call's own `constraint`,
        // narrowed by this node's own padding — the same content-area space `availableSpace`
        // already offers children, not the constraint the enclosing snapshot happened to
        // capture. Nodes without a measurer keep the exact fixed value they always had.
        //
        // Defect #46: a leaf's *own* explicit `style.width`/`style.height` must override the
        // incoming constraint's main axis here, not just feed into `styleMain` below. The
        // incoming constraint's main axis is `.unspecified` during this basis pass regardless
        // of whether this leaf already has a definite size of its own (ADR 0009 — basis is
        // measured unconstrained so a shrinking parent doesn't multiply states) — harmless for
        // an ordinary node, whose `LayoutContentMetrics` never depends on the constraint at
        // all, but wrong for a content-dependent leaf like `TextNode`, whose wrap (and so its
        // cross-axis size) genuinely depends on the width it measures against. Worse, once a
        // leaf's basis already equals its own explicit size (no grow/shrink needed to resolve
        // it), `FlexboxPlacement.reusableMeasure` never re-measures at a corrected constraint
        // either — that second pass only fires when grow/shrink changes the resolved main size
        // away from its basis. Net effect before this fix: an explicit-width `TextNode` in a
        // row (or explicit-height one in a column) measured its wrap against an effectively
        // unbounded width and never wrapped, no matter how narrow its own explicit size was.
        let measuredContent: LayoutContentMetrics
        if input.children.isEmpty, let measurer = input.content.measurer {
            let ownWidth = input.style.width.resolved(parent: parentWidth)
            let ownHeight = input.style.height.resolved(parent: parentHeight)
            let contentConstraint = SizeConstraint(
                width: ownWidth.map { .exact(max(0, $0 - horizontalPadding)) }
                    ?? narrowed(constraint.width, by: horizontalPadding),
                height: ownHeight.map { .exact(max(0, $0 - verticalPadding)) }
                    ?? narrowed(constraint.height, by: verticalPadding)
            )
            measuredContent = try measurer.measure(contentConstraint, context: context)
        } else {
            measuredContent = input.content
        }
        let intrinsic = measuredContent.intrinsic
        let bases = childMeasurements.compactMap { index, nested -> BasisItem? in
            let child = input.children[index]
            guard child.style.positionType == .relative else { return nil }
            let margin = child.style.margin.resolved(for: input.direction)
            let styleMain =
                direction.isHorizontal
                ? child.style.width.resolved(parent: availableMain)
                : child.style.height.resolved(parent: availableMain)
            let main =
                child.style.flexBasis.resolved(parent: availableMain)
                ?? styleMain
                ?? (direction.isHorizontal ? nested.parentSize.width : nested.parentSize.height)
            return BasisItem(
                index: index,
                margin: margin,
                basis: main,
                baseline: nested.firstBaseline,
                natural: nested
            )
        }
        let lines = try resolveLines(
            input: input,
            items: bases,
            availableMain: availableMain,
            availableCross: availableCross,
            context: context,
            cache: &cache
        )
        let lineMain =
            lines.map { line in
                line.items.reduce(0) { $0 + $1.mainSize } + input.style.gap
                    * Double(max(0, line.items.count - 1))
            }.max() ?? 0
        let lineCross =
            lines.reduce(0) { $0 + $1.crossSize } + input.style.crossGap
            * Double(max(0, lines.count - 1))
        let measuredWidth =
            input.style.width.resolved(parent: parentWidth)
            ?? (direction.isHorizontal ? lineMain : lineCross) + horizontalPadding
        let measuredHeight =
            input.style.height.resolved(parent: parentHeight)
            ?? (direction.isHorizontal ? lineCross : lineMain) + verticalPadding
        let withIntrinsic = MeasuredSize(
            width: input.children.isEmpty
                ? max(measuredWidth, intrinsic.width + horizontalPadding) : measuredWidth,
            height: input.children.isEmpty
                ? max(measuredHeight, intrinsic.height + verticalPadding) : measuredHeight
        )
        // Fractions (size and min/max) resolve against the parent's known size; only an
        // unknown axis falls back to the content size, and the two `.fraction` branches below
        // then keep the content size for it. Resolving against the content size when the
        // parent was known made a cross-axis `width: 50%` a quarter (defect #28).
        let resolutionParent = MeasuredSize(
            width: parentWidth ?? withIntrinsic.width,
            height: parentHeight ?? withIntrinsic.height
        )
        var size =
            input.style.measured(parentSize: resolutionParent, constraint: constraint).width == 0
                && input.style.width == .auto && input.style.height == .auto
            ? withIntrinsic
            : input.style.measured(parentSize: resolutionParent, constraint: constraint)
        if parentWidth == nil, case .fraction = input.style.width {
            size = MeasuredSize(width: withIntrinsic.width, height: size.height)
        }
        if parentHeight == nil, case .fraction = input.style.height {
            size = MeasuredSize(width: size.width, height: withIntrinsic.height)
        }
        if input.style.width == .auto {
            let width = intrinsicSize(
                fallback: max(withIntrinsic.width, size.width),
                constraint: constraint.width,
                explicit: constraint.width.exactValue
            )
            size = MeasuredSize(width: width, height: size.height)
        }
        if input.style.height == .auto {
            let height = intrinsicSize(
                fallback: max(withIntrinsic.height, size.height),
                constraint: constraint.height,
                explicit: constraint.height.exactValue
            )
            size = MeasuredSize(width: size.width, height: height)
        }
        // Defect #86 (ADR 0026): along its scrollable (main) axis a `.scroll` container is a
        // viewport — its content extent never enlarges it past what the parent offers.
        if input.style.visual.overflow == .scroll {
            if direction.isHorizontal, input.style.width == .auto,
                case let .atMost(limit) = constraint.width
            {
                size = MeasuredSize(width: min(size.width, limit), height: size.height)
            } else if !direction.isHorizontal, input.style.height == .auto,
                case let .atMost(limit) = constraint.height
            {
                size = MeasuredSize(width: size.width, height: min(size.height, limit))
            }
        }
        let result = FlexMeasureResult(
            parentSize: size,
            lines: lines,
            cacheKey: key,
            dependsOnAvailableSize: dependsOnAvailableSize,
            firstBaseline: measuredContent.firstBaseline
        )
        cache.store(key: key, result: result)
        Log.on(
            .measure,
            CacheOutcome.miss.rawValue,
            node: input.identity,
            "size=\(size.width)x\(size.height)"
        )
        return result
    }

    /// The inner main/cross space this container lays its children out in, from its own
    /// definite size when it has one and from `constraint` otherwise. A node with an explicit
    /// `width`/`height` (or an `.exact` constraint) is that size whatever the parent offered,
    /// so its children grow, shrink and wrap within it — taking the parent's `.atMost` instead
    /// gave `Column(height: 50) { Leaf.grow(1) }` a 200 pt leaf (defect #26).
    static func availableSpace(
        input: LayoutInputSnapshot,
        constraint: SizeConstraint
    ) -> (main: Double?, cross: Double?) {
        let padding = input.style.padding.resolved(for: input.direction)
        let horizontalPadding = padding.left + padding.right
        let verticalPadding = padding.top + padding.bottom
        let parentWidth = constraint.width.knownValue
        let parentHeight = constraint.height.knownValue
        let width =
            definiteSize(
                axis: constraint.width,
                size: input.style.width,
                minimum: input.style.minWidth,
                maximum: input.style.maxWidth,
                parent: parentWidth
            ) ?? parentWidth
        let height =
            definiteSize(
                axis: constraint.height,
                size: input.style.height,
                minimum: input.style.minHeight,
                maximum: input.style.maxHeight,
                parent: parentHeight
            ) ?? parentHeight
        let innerWidth = width.map { max(0, $0 - horizontalPadding) }
        let innerHeight = height.map { max(0, $0 - verticalPadding) }
        return input.style.flexDirection.isHorizontal
            ? (innerWidth, innerHeight)
            : (innerHeight, innerWidth)
    }

    /// The size this axis is known to end up at before its content is measured: the `.exact`
    /// constraint, else the explicit style size clamped by min/max and an `.atMost` bound —
    /// the same order `LayoutStyle.measured` applies. `nil` for `auto` and for a fraction
    /// whose parent size is unknown.
    private static func definiteSize(
        axis: SizeConstraintAxis,
        size: SizeValue,
        minimum: SizeValue,
        maximum: SizeValue,
        parent: Double?
    ) -> Double? {
        if case let .exact(value) = axis { return value }
        guard var value = size.resolved(parent: parent) else { return nil }

        if let lower = minimum.resolved(parent: parent) { value = max(value, lower) }
        if let upper = maximum.resolved(parent: parent) { value = min(value, upper) }
        if case let .atMost(limit) = axis { value = min(value, limit) }

        return value
    }

    private static func intrinsicSize(
        fallback: Double,
        constraint: SizeConstraintAxis,
        explicit: Double?
    ) -> Double {
        if let explicit { return explicit }
        switch constraint {
        case .unspecified, .atMost: return fallback
        case let .exact(value): return value
        }
    }

    /// Reduces a bound axis by this node's own padding on that axis, the same content-area
    /// space `availableSpace` already offers children — a measurer sees the box its content
    /// actually draws into, not the box including this leaf's own padding. `.unspecified`
    /// stays unspecified; a bound that padding would push below zero clamps to zero rather
    /// than going negative.
    private static func narrowed(_ axis: SizeConstraintAxis, by padding: Double)
        -> SizeConstraintAxis
    {
        switch axis {
        case .unspecified: return .unspecified
        case let .atMost(value): return .atMost(max(0, value - padding))
        case let .exact(value): return .exact(max(0, value - padding))
        }
    }

    /// Resolves wrap line-breaking, then grow/shrink, for one container's relative-flow children.
    ///
    /// Cancellation checkpoint: checked once per resolved line (D09/§3.13), not per item — a
    /// pathologically expensive single line is a known open question deferred to C31, not a gap
    /// this card promises to close.
    static func resolveLines(
        input: LayoutInputSnapshot,
        items: [BasisItem],
        availableMain: Double?,
        availableCross: Double?,
        context: LayoutContext,
        cache: inout FlexMeasureCache
    ) throws -> [FlexLine] {
        guard !items.isEmpty else { return [] }
        let horizontal = input.style.flexDirection.isHorizontal
        // R07 (`docs/adr/0026-scroll-node-viewport.md`): an `overflow == .scroll` container's
        // main axis is the scrollable one (`r06-scroll-api-sketch.md` §2 — "продольная ось —
        // `.unspecified` на измерении контента", the same max-content basis ADR 0009 already
        // uses for auto-sized content). Distribution (grow/shrink and wrap line-breaking, both
        // below) reads `scrollableMain` instead of `availableMain` so a definite viewport size
        // on a `.scroll` container never shrinks its children to fit it — only the cross axis
        // (`availableCross`, untouched here) stays bound by the container's own size, exactly
        // as for any other container. This does not change the container's *own* measured
        // size (`measuredWidth`/`measuredHeight` above, computed from `input.style`), only how
        // its children are distributed within it.
        let scrollableMain = input.style.visual.overflow == .scroll ? nil : availableMain
        var groups: [[BasisItem]] = [[]]
        // Running main-axis total of the open line: recomputing it by reducing the whole
        // line per item made a single wide line O(n²) (defect #15 — 5000 items: 137 ms).
        var currentMain = 0.0
        for item in items {
            let itemMain = item.basis + mainMargin(item.margin, horizontal: horizontal)
            let currentCount = groups[groups.count - 1].count
            if input.style.flexWrap != .noWrap, let scrollableMain, currentCount > 0,
                currentMain + input.style.gap + itemMain > scrollableMain
            {
                groups.append([item])
                currentMain = itemMain
            } else {
                groups[groups.count - 1].append(item)
                currentMain += itemMain + (currentCount > 0 ? input.style.gap : 0)
            }
        }
        var lines: [FlexLine] = []
        for group in groups {
            try context.checkCancellation()
            let baseTotal =
                group.reduce(0) { $0 + $1.basis + mainMargin($1.margin, horizontal: horizontal) }
                + input.style.gap * Double(max(0, group.count - 1))
            let delta = (scrollableMain ?? baseTotal) - baseTotal
            let weights =
                delta >= 0
                ? group.map { input.children[$0.index].style.flexGrow }
                : group.map { input.children[$0.index].style.flexShrink * $0.basis }
            let totalWeight = weights.reduce(0, +)
            var resolvedMains = group.map(\.basis)
            if delta >= 0, totalWeight > 0 {
                for (offset, weight) in weights.enumerated() {
                    resolvedMains[offset] += delta * weight / totalWeight
                }
            } else if delta < 0, availableMain != nil {
                var active = Set(group.indices)
                var remaining = -delta
                while remaining > 0.0001, !active.isEmpty {
                    let weight = active.reduce(0) { $0 + weights[$1] }
                    guard weight > 0 else { break }
                    var consumed = 0.0
                    var frozen: [Int] = []
                    for offset in active {
                        let child = input.children[group[offset].index]
                        let minValue =
                            horizontal
                            ? child.style.minWidth.resolved(parent: availableMain)
                            : child.style.minHeight.resolved(parent: availableMain)
                        let reduction = remaining * weights[offset] / weight
                        let next = max(minValue ?? 0, resolvedMains[offset] - reduction)
                        consumed += resolvedMains[offset] - next
                        resolvedMains[offset] = next
                        if next <= (minValue ?? 0) + 0.0001 { frozen.append(offset) }
                    }
                    frozen.forEach { active.remove($0) }
                    if consumed <= 0.0001 { break }
                    remaining -= consumed
                }
            }
            var lineItems: [FlexLineItem] = []
            for (offset, item) in group.enumerated() {
                // A single line can hold thousands of items; without a checkpoint inside it
                // a cancel waits for the whole line (C31 measured 21 ms on 5000 items).
                if offset % 256 == 255 { try context.checkCancellation() }
                let child = input.children[item.index]
                let minValue =
                    horizontal
                    ? child.style.minWidth.resolved(parent: availableMain)
                    : child.style.minHeight.resolved(parent: availableMain)
                let maxValue =
                    horizontal
                    ? child.style.maxWidth.resolved(parent: availableMain)
                    : child.style.maxHeight.resolved(parent: availableMain)
                let main = min(
                    max(resolvedMains[offset], minValue ?? 0),
                    maxValue ?? .greatestFiniteMagnitude
                )
                // An item that neither grew nor shrank, and whose basis is its natural size,
                // is already measured: `.exact(main)` at its own natural main would give its
                // children the same space they measured under, so the subtree is not walked
                // again (defect #14 — this re-measure per level made nesting O(depth²)).
                // Not when something below resolves a fraction against that space: the
                // max-content pass treated it as unknown (`dependsOnAvailableSize`).
                let naturalMain =
                    horizontal ? item.natural.parentSize.width : item.natural.parentSize.height
                let measured =
                    main == naturalMain && !item.natural.dependsOnAvailableSize
                    ? item.natural
                    : try measure(
                        child,
                        constraint: horizontal
                            ? SizeConstraint(
                                width: .exact(main),
                                height: availableCross.map { .atMost($0) } ?? .unspecified
                            )
                            : SizeConstraint(
                                width: availableCross.map { .atMost($0) } ?? .unspecified,
                                height: .exact(main)
                            ),
                        context: context,
                        cache: &cache
                    )
                let cross = horizontal ? measured.parentSize.height : measured.parentSize.width
                lineItems.append(
                    FlexLineItem(
                        identity: child.identity,
                        mainSize: main,
                        crossSize: cross,
                        baseline: measured.firstBaseline
                    )
                )
            }
            lines.append(
                FlexLine(items: lineItems, crossSize: lineItems.map(\.crossSize).max() ?? 0)
            )
        }
        return lines
    }

    private static func mainMargin(_ margin: PhysicalEdgeInsets, horizontal: Bool) -> Double {
        horizontal ? margin.left + margin.right : margin.top + margin.bottom
    }
}

/// A relative-flow child's resolved main-axis basis and margin, before grow/shrink. The item's
/// cross size is deliberately not carried here: `resolveLines` re-measures each item once its
/// final main size is known (a fixed-width row item's auto height, for instance, depends on
/// that final width) rather than reusing an earlier, pre-resolution cross measurement.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
struct BasisItem {
    let index: Int
    let margin: PhysicalEdgeInsets
    let basis: Double
    let baseline: Double?
    /// The child's max-content measurement (main axis `.unspecified`, cross axis the
    /// container's `.atMost`) — the one its basis came from. Reused by `resolveLines` when the
    /// resolved main size equals the natural main size it reports, instead of measuring the
    /// same subtree again under `.exact` (defect #14).
    let natural: FlexMeasureResult
}

extension LayoutStyle {
    /// Whether any size on this style resolves against the parent's size — see
    /// `FlexMeasureResult.dependsOnAvailableSize`.
    fileprivate var hasFractionSize: Bool {
        for value in [width, height, minWidth, maxWidth, minHeight, maxHeight, flexBasis] {
            if case .fraction = value { return true }
        }

        return false
    }
}

extension FlexDirection {
    var isHorizontal: Bool {
        switch self {
        case .row, .rowReverse: return true
        case .column, .columnReverse: return false
        }
    }
}

extension SizeConstraintAxis {
    fileprivate var exactValue: Double? {
        guard case let .exact(value) = self else { return nil }
        return value
    }
}
