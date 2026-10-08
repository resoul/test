/// MainActor-owned logical UI node with no platform allocation at construction.
///
/// This carries only identity, style/appearance, a computed frame slot, tree structure, the
/// three empty event hooks (H03) and — since A03 — focus/accessibility metadata as plain
/// values; Flux, state, scroll, native backing, and `compose()` are not ported
/// (docs/weave-analysis.md, `Node.swift` row). `open` is
/// required even though nothing overrides it yet: `arrangeSubnodes()` (C22) is declared in
/// this class body, and a subclass in another module must be able to override it (D02).
///
/// Ownership: the node owns its child array; it holds its parent weakly (D02) so a subtree
/// never keeps an ancestor alive. Isolation: MainActor. Errors: invalid tree operations
/// (self/ancestor cycles, disposed endpoints, out-of-range indices) are rejected and logged
/// rather than thrown — a caller building a tree imperatively should not have to wrap every
/// call in `try`. Cancellation: `dispose()` is the only lifecycle-owned cancellation point in
/// this card; it is terminal and idempotent.
@MainActor
open class Node {
    /// Stable runtime identity for the lifetime of this node (D02); survives reparenting and
    /// detach/attach, and is never reused.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let id: NodeID

    /// Mutable layout style owned by this node (C07). Direct field mutation is the intended
    /// API — `node.style.width = 100` — as is batched assignment through `style { ... }`
    /// (C09). Assigning an equal, already-normalized value is a no-op: it neither bumps a
    /// revision nor requests a flush.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var style: LayoutStyle {
        didSet {
            guard style != oldValue else {
                Log.on(.style, "no-op", node: id, "kind=style")
                return
            }
            Log.on(.style, "changed", node: id, "kind=style")
            markGeometryDirty(structural: false)
            recomputeArrangementEffectiveStyle()
        }
    }

    /// Mutable paint-only presentation properties owned by this node (C07). Assigning an
    /// equal value is a no-op (C09), matching `style`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var appearance: VisualStyle {
        didSet {
            guard appearance != oldValue else {
                Log.on(.style, "no-op", node: id, "kind=appearance")
                return
            }
            Log.on(.style, "changed", node: id, "kind=appearance")
            markAppearanceDirty()
        }
    }

    /// This node's focus participation (A03, D37/D38). Assigning an equal value is a no-op;
    /// a change marks semantics dirty — the host republishes its semantic snapshot from the
    /// committed frames without a layout pass (D41). Read at commit time into the snapshot;
    /// never read live by the focus engine.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var focus = FocusProperties() {
        didSet {
            guard focus != oldValue else {
                Log.on(.semantics, "no-op", node: id, "kind=focus")
                return
            }
            Log.on(.semantics, "changed", node: id, "kind=focus")
            markSemanticsDirty()
        }
    }

    /// This node's declarative semantics for assistive technology (A03, D41/D42). Assigning
    /// an equal value is a no-op; a change marks semantics dirty, like `focus`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var accessibility = AccessibilityProperties() {
        didSet {
            guard accessibility != oldValue else {
                Log.on(.semantics, "no-op", node: id, "kind=accessibility")
                return
            }
            Log.on(.semantics, "changed", node: id, "kind=accessibility")
            markSemanticsDirty()
        }
    }

    /// Handles an accessibility action assistive technology requested on this node (A07,
    /// D43) — the closure form of `performAccessibilityAction(_:)`, for nodes that are not
    /// subclassed. Return `true` only when the action was actually handled; `false` tells the
    /// platform to report failure. Never called for a node the published tree does not show,
    /// for a stale identity, or for `.activate` on a disabled control.
    ///
    /// Ownership: the node retains the closure; capture `self` weakly. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public var onAccessibilityAction: (@MainActor (AccessibilityAction) -> Bool)?

    /// Number of times this node's own focus/accessibility metadata changed (A03). Like
    /// `appearanceRevision`, never advanced on an ancestor because of a descendant.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var semanticsRevision: UInt64 = 0

    /// The frame from the most recently applied layout result, or `nil` before any pass has
    /// run. Nothing writes this yet — that arrives with the coordinator (C14) once
    /// `LayoutResult` has an identity-indexed lookup (C11).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var calculatedFrame: LayoutFrame?

    /// Whether `dispose()` has already run on this node.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isDisposed = false

    /// Number of times this node's own child list has changed (add/remove/reorder).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var structureRevision: UInt64 = 0

    /// Number of times this node's geometry became dirty — its own style, or transitively a
    /// descendant's structure or style. Ancestors of a changed node advance this too, since
    /// their own measured size may depend on it (F01/§3.11): geometry dirtiness is not local.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var geometryRevision: UInt64 = 0

    /// Number of times this node's own paint-only appearance changed. Unlike
    /// `geometryRevision`, this never advances on an ancestor purely because a descendant's
    /// appearance changed — a paint-only change does not affect ancestor layout.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var appearanceRevision: UInt64 = 0

    /// Fires at most once per pending window, at the current root of this tree, once dirty
    /// state transitions from clean to pending (C09). `origin` is the node whose mutation
    /// first requested the pending flush; `reasons` is the accumulated union of everything
    /// that became dirty since `consumePendingInvalidation()` last drained it — further
    /// mutations before that drain do not fire this again, matching the coalesced-burst
    /// contract, but their reasons are folded into the same accumulator.
    ///
    /// Ownership: the callback is owned by whatever host/scheduler attaches it. Isolation:
    /// MainActor. Errors: none. Cancellation: the owner clears it to stop receiving pings.
    public var onInvalidate: (@MainActor (_ origin: Node, _ reasons: DirtyReasons) -> Void)?

    private var pendingReasons: DirtyReasons = []
    /// Weak on purpose (defect #31): the origin is often this node itself — a structure or
    /// style change at the root — and a strong reference would be a self-retain that keeps an
    /// unmounted or detached tree alive until a host drains the window, which may never
    /// happen. An origin that goes away before the drain is reported as the root itself.
    private weak var pendingOrigin: Node?
    private var pendingDepth: Int = 0
    private var pendingAnimationIntents: [AnimationIntent] = []
    private var activeAnimationScopes: [ActiveAnimationScope] = []
    private var animationIntentEpoch: UInt64?
    private var nextAnimationIntentSequence: UInt64 = 0

    private struct ActiveAnimationScope {
        let scopeNodeID: NodeID
        let sequence: UInt64
        let epoch: UInt64
        let animation: Animation
        var observedMutation = false
    }

    /// The logical parent, if this node is currently attached to one.
    ///
    /// Ownership: returns a value; the reference itself is weak (D02). Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public var supernode: Node? { parent }

    /// A stable snapshot of the current child list, in traversal order.
    ///
    /// Ownership: returns a copy of the array. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var subnodes: [Node] { children }

    /// Effective environment values inherited down this node's scope chain (C10).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var environment: EnvironmentValues { scope.snapshot.values }

    /// This node's environment snapshot, values plus the revision that produced them.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var environmentSnapshot: EnvironmentSnapshot { scope.snapshot }

    /// This node's own environment scope, for passing to another node's `inheritEnvironment(from:)`
    /// or to `Node.init(environment:)` — sharing environment without becoming that node's
    /// `Node`-tree child.
    ///
    /// Ownership: returns the scope this node owns; the caller does not take ownership.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var environmentScope: EnvironmentScope { scope }

    /// Whether this node folds its environment's safe-area insets into its own padding at
    /// snapshot time (C10). The tree root does this regardless of this flag; setting it lets
    /// any other node opt in — a scroll container's content edge, for instance. Assigning the
    /// same value is a no-op.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var safeAreaBoundary = false {
        didSet {
            guard safeAreaBoundary != oldValue else { return }
            markGeometryDirty(structural: false)
        }
    }

    /// Which logical edges are excluded from the safe-area fold-in described by
    /// `safeAreaBoundary`. Assigning the same value is a no-op.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var safeAreaIgnoredEdges: SafeAreaEdges = .none {
        didSet {
            guard safeAreaIgnoredEdges != oldValue else { return }
            markGeometryDirty(structural: false)
        }
    }

    /// Whether this node's own child list is currently owned by a resolved `Arrangement`
    /// (C23), rather than by direct `addSubnode`/`insertSubnode`/`moveSubnode`/
    /// `removeFromSupernode` calls. While `true`, those four methods reject a call that did
    /// not originate from the resolver itself (D05) — set only by the resolver, never by a
    /// public API, since manual mutation of a managed list is diagnosed, not silently allowed.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package var childrenAreArrangementManaged = false

    /// Whether this node's `arrangeSubnodes()` should be resolved at the next snapshot
    /// preparation (C32, D13). `true` from creation — the first flush after attach resolves
    /// every node in the tree once, which is how owners are discovered without any manual
    /// call — and again after `markArrangementDirty()`; cleared by any resolve, automatic or
    /// via `resolveArrangement()`, including a rejected proposal (the diagnostic was logged;
    /// the author fixes the description and marks dirty again).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package var needsArrangementResolve = true

    /// `true` for an implicit wrapper node the resolver created for a nested `Row`/`Column`/
    /// `Overlay` (D06). A wrapper's children are managed by its *owner's* resolve, never by
    /// its own — so it is never resolved itself, automatically or manually: resolving a
    /// wrapper would read its `nil` `arrangeSubnodes()` as "return my children to manual
    /// mode" and tear down the owner's subtree.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package var isArrangementWrapper = false

    /// The resolver's cache of implicit wrapper nodes for this node's own `Arrangement`
    /// subtree, keyed by `(structuralPath, containerKind)` (D06; `ownerID` is implicit — this
    /// cache lives on the owner). Empty for a node that has never resolved a container-shaped
    /// `Arrangement`.
    ///
    /// Ownership: this node owns every wrapper it caches. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    package var arrangementWrapperCache: [ArrangementWrapperKey: Node] = [:]

    /// The resolver-computed effective style used for this node's snapshot in place of `style`
    /// (D04), or `nil` when this node is not currently part of any resolved `Arrangement`.
    /// Always `LayoutStyle.arrangementEffective(base: style, container:placement:)` — derived
    /// from the current base and the two pieces of `Arrangement` data below, never mutated in
    /// place — so removing a modifier, changing a container's kind, or editing `style` while
    /// managed never leaves a stale field behind.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package private(set) var arrangementEffectiveStyle: LayoutStyle?

    /// What the *parent* owner's `Arrangement` decided about this node as one of its items
    /// (C23), or `nil` when no owner currently places it. Set only by the resolver of that
    /// parent; cleared when this node leaves that owner's managed subtree. Independent of
    /// `arrangementContainerStyle`, so a node can be both an item of its parent and an owner
    /// of its own `Arrangement` without either resolve erasing the other's decision.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package private(set) var arrangementPlacement: ArrangementPlacement?

    /// What this node's *own* root `Row`/`Column`/`Overlay` decided about itself (C21: the
    /// root container is self), or `nil` when its `arrangeSubnodes()` is `nil` or a root
    /// `Leaf`. Set only by this node's own resolve.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package private(set) var arrangementContainerStyle: ArrangementContainerStyle?

    /// `true` for the duration of the resolver's own tree mutations (C23) — the one exception
    /// the managed-list guards on `addSubnode`/`insertSubnode`/`moveSubnode`/
    /// `removeFromSupernode` make for calls that did not come from user code.
    ///
    /// Ownership: shared process-wide flag, not per-instance. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    package static var isResolving = false

    /// The reasons accumulated in the current pending window, without draining it — lets a
    /// host decide before capturing a layout snapshot whether the window carries only
    /// appearance/semantics work (A03 fast path). Empty when nothing is pending.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    package var pendingInvalidationReasons: DirtyReasons { pendingReasons }

    /// Animation metadata accumulated in the current pending window, without draining it.
    ///
    /// Ownership: returns a copied array containing no `Node` references. Isolation: MainActor.
    /// Errors: none. Cancellation: lifecycle owners clear collection explicitly.
    package var pendingAnimationIntentRecords: [AnimationIntent] { pendingAnimationIntents }

    /// Whether this node is enabled for focus, activation and assistive technology (D41).
    /// `true` for a plain node; `ControlNode` reports its `isEnabled`. Read into the
    /// semantic snapshot at commit time and by the bridge's live guard before an action.
    package var isEnabledForSemantics: Bool { true }

    /// Whether this node has a default activation — a `ControlNode` (D43). Decides the
    /// implicit `.activate` action and the `button` role fallback in the semantic tree.
    var isActivatable: Bool { false }

    private weak var parent: Node?
    private var children: [Node] = []
    private let scope: EnvironmentScope

    /// Creates a node with no lifecycle effect and no platform allocation.
    ///
    /// `environment`, if supplied, becomes this node's inherited scope parent immediately —
    /// useful for constructing a node that should see a host-provided environment (safe area,
    /// theme) from its very first snapshot, without a separate `inheritEnvironment(from:)` call.
    ///
    /// Ownership: the node owns its style, appearance, and environment scope. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public init(
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        id = NodeIDAllocator.allocate()
        self.style = style
        self.appearance = appearance
        scope = EnvironmentScope(parent: environment)
        Log.on(.tree, "created", node: id, "type=\(Self.self)")
    }

    /// Re-chains this node's environment scope under `parent`'s, without changing this node's
    /// position in the `Node` tree itself. `addSubnode`/`removeFromSupernode` already call this
    /// as part of attaching/detaching a child — call it directly only to attach a *root* node
    /// to a host-provided environment.
    ///
    /// Ownership: holds `parent`'s scope weakly (via `EnvironmentScope`). Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func inheritEnvironment(from parent: EnvironmentScope) {
        scope.reparent(to: parent)
        markGeometryDirty(structural: false)
    }

    /// Overrides one environment key on this node's own scope, advancing its scope revision so
    /// the next snapshot reflects it, and marking this node's geometry dirty — direction and
    /// safe-area insets affect layout for every descendant that reads them.
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setEnvironment<Key: EnvironmentKey>(_ key: Key.Type, to value: Key.Value) {
        scope.set(key, to: value)
        markGeometryDirty(structural: false)
    }

    /// Mutates `style` in place and assigns it back exactly once, so a batch of field writes
    /// produces a single equality check and, if anything changed, a single dirty mark —
    /// `node.style { $0.width = 100; $0.gap = 8 }` behaves as one write, not two.
    ///
    /// Ownership: mutates this node's own value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func style(_ mutate: (inout LayoutStyle) -> Void) {
        var updated = style
        mutate(&updated)
        style = updated
    }

    /// Mutates `appearance` in place and assigns it back exactly once, matching `style(_:)`.
    ///
    /// Ownership: mutates this node's own value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func appearance(_ mutate: (inout VisualStyle) -> Void) {
        var updated = appearance
        mutate(&updated)
        appearance = updated
    }

    /// Applies synchronous changes and assigns one animation policy to the resulting visual
    /// change in this node's subtree.
    ///
    /// The call records no intent when the closure is a no-op, changes semantics only, or the
    /// tree is not mounted/active. Mutations still happen in every case. Nested calls receive a
    /// later sequence and therefore override an enclosing scope where the two overlap.
    ///
    /// Ownership: borrows the closure for this call and stores only value metadata and Node IDs.
    /// Isolation: MainActor. Errors: none. Cancellation: a host suspend, detach, or replacement
    /// discards pending intent without rolling back model mutations.
    public func animate(_ animation: Animation, _ changes: () -> Void) {
        var collectorRoot = self
        while let parent = collectorRoot.parent { collectorRoot = parent }

        guard let epoch = collectorRoot.animationIntentEpoch else {
            InvalidationTransaction.perform(changes)
            return
        }

        collectorRoot.nextAnimationIntentSequence &+= 1
        collectorRoot.activeAnimationScopes.append(
            ActiveAnimationScope(
                scopeNodeID: id,
                sequence: collectorRoot.nextAnimationIntentSequence,
                epoch: epoch,
                animation: animation
            )
        )
        InvalidationTransaction.perform {
            defer {
                let scope = collectorRoot.activeAnimationScopes.removeLast()
                if scope.observedMutation {
                    collectorRoot.pendingAnimationIntents.append(
                        AnimationIntent(
                            scopeNodeID: scope.scopeNodeID,
                            sequence: scope.sequence,
                            epoch: scope.epoch,
                            animation: scope.animation
                        )
                    )
                }
            }
            changes()
        }
    }

    /// Reads and clears this node's accumulated pending invalidation, if any.
    ///
    /// This is the drain a host/scheduler calls once it has captured whatever it needs from
    /// the pending state: it resets the ping gate so the next independent mutation pings
    /// again. Calling this when nothing is pending is a no-op that returns `nil`. Pending
    /// state is tracked and pinged at the current root of a tree, so this is meaningful when
    /// called on that root — not on an arbitrary node in the middle of it.
    ///
    /// Ownership: the returned origin is borrowed, not retained beyond the caller's own
    /// reference. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func consumePendingInvalidation() -> (origin: Node, reasons: DirtyReasons)? {
        guard !pendingReasons.isEmpty else { return nil }
        let origin = pendingOrigin ?? self
        let reasons = pendingReasons
        pendingReasons = []
        pendingOrigin = nil
        pendingDepth = 0
        pendingAnimationIntents.removeAll(keepingCapacity: true)
        return (origin, reasons)
    }

    /// Enables collection for one mounted host epoch and drops anything accumulated before it.
    package func beginAnimationIntentCollection(epoch: UInt64) {
        animationIntentEpoch = epoch
        nextAnimationIntentSequence = 0
        activeAnimationScopes.removeAll(keepingCapacity: true)
        pendingAnimationIntents.removeAll(keepingCapacity: true)
    }

    /// Stops collection and releases every pending record for this root.
    package func endAnimationIntentCollection() {
        animationIntentEpoch = nil
        activeAnimationScopes.removeAll(keepingCapacity: true)
        pendingAnimationIntents.removeAll(keepingCapacity: true)
    }

    /// Pauses collection while preserving the owner's monotonic sequence counter.
    package func pauseAnimationIntentCollection() {
        animationIntentEpoch = nil
        activeAnimationScopes.removeAll(keepingCapacity: true)
        pendingAnimationIntents.removeAll(keepingCapacity: true)
    }

    /// Resumes collection in the same mount epoch without reusing a sequence number.
    package func resumeAnimationIntentCollection(epoch: UInt64) {
        animationIntentEpoch = epoch
        activeAnimationScopes.removeAll(keepingCapacity: true)
        pendingAnimationIntents.removeAll(keepingCapacity: true)
    }

    /// Finds the latest scope that contains `nodeID` in the tree as it exists at commit time.
    ///
    /// Missing scopes and targets are ignored. This makes newly resolved wrappers participate,
    /// while removed scopes do not keep working by stale ancestry.
    package func resolvedAnimationIntent(
        for nodeID: NodeID,
        from intents: [AnimationIntent],
        epoch: UInt64
    ) -> AnimationIntent? {
        guard let path = identityPath(to: nodeID) else { return nil }
        let scopes = Set(path)
        return intents.lazy
            .filter { $0.epoch == epoch && scopes.contains($0.scopeNodeID) }
            .max { $0.sequence < $1.sequence }
    }

    /// Appends `node` as this node's last child, reparenting it if it is currently attached
    /// elsewhere and preserving its identity.
    ///
    /// Rejects and logs, without mutating the tree: `node === self` and any case where `node`
    /// is already an ancestor of `self` (both would create a cycle), and any case where
    /// either endpoint is already disposed. Re-adding a node that is already a child of
    /// `self` is a deliberate no-op — it does not move the node to the end — because
    /// re-adding is not the same request as reordering; use `moveSubnode(from:to:)` to reorder.
    ///
    /// Ownership: `self` gains the child relationship; `node` otherwise remains caller-owned.
    /// Isolation: MainActor. Errors: none — invalid requests are diagnosed via `Log.on` and
    /// ignored. Cancellation: not applicable.
    public func addSubnode(_ node: Node) {
        guard !childrenAreArrangementManaged || Node.isResolving else {
            Log.on(.tree, "add-rejected", node: node.id, parent: id, "reason=arrangement-managed")
            return
        }
        guard !isDisposed else {
            Log.on(.tree, "add-rejected", node: node.id, parent: id, "reason=parent-disposed")
            return
        }
        guard !node.isDisposed else {
            Log.on(.tree, "add-rejected", node: node.id, parent: id, "reason=child-disposed")
            return
        }
        guard node !== self else {
            Log.on(.tree, "cycle-rejected", node: node.id, parent: id, "reason=self")
            return
        }
        guard !isDescendant(of: node) else {
            Log.on(.tree, "cycle-rejected", node: node.id, parent: id, "reason=ancestor")
            return
        }
        guard node.parent !== self else {
            Log.on(.tree, "no-op", node: node.id, parent: id, "reason=already-child")
            return
        }
        node.removeFromSupernode()
        children.append(node)
        node.parent = self
        node.scope.reparent(to: scope)
        Log.on(.tree, "added", node: node.id, parent: id, "index=\(children.count - 1)")
        markGeometryDirty(structural: true)
    }

    /// Inserts `node` as this node's child at `index`, reparenting it if needed and
    /// preserving its identity. `index` is validated against the child count before `node`
    /// is detached from any prior parent, so re-inserting a current child accepts the same
    /// range as inserting a new one.
    ///
    /// Rejection cases mirror `addSubnode(_:)`: self/ancestor cycles, either endpoint already
    /// disposed, and an out-of-range `index`.
    ///
    /// Ownership: `self` gains the child relationship; `node` otherwise remains caller-owned.
    /// Isolation: MainActor. Errors: none — invalid requests are diagnosed via `Log.on` and
    /// ignored. Cancellation: not applicable.
    public func insertSubnode(_ node: Node, at index: Int) {
        guard !childrenAreArrangementManaged || Node.isResolving else {
            Log.on(
                .tree,
                "insert-rejected",
                node: node.id,
                parent: id,
                "reason=arrangement-managed"
            )
            return
        }
        guard !isDisposed else {
            Log.on(.tree, "insert-rejected", node: node.id, parent: id, "reason=parent-disposed")
            return
        }
        guard !node.isDisposed else {
            Log.on(.tree, "insert-rejected", node: node.id, parent: id, "reason=child-disposed")
            return
        }
        guard node !== self else {
            Log.on(.tree, "cycle-rejected", node: node.id, parent: id, "reason=self")
            return
        }
        guard !isDescendant(of: node) else {
            Log.on(.tree, "cycle-rejected", node: node.id, parent: id, "reason=ancestor")
            return
        }
        guard index >= 0, index <= children.count else {
            Log.on(
                .tree,
                "insert-rejected",
                node: node.id,
                parent: id,
                "reason=invalid-index index=\(index) count=\(children.count)"
            )
            return
        }
        node.removeFromSupernode()
        children.insert(node, at: min(index, children.count))
        node.parent = self
        node.scope.reparent(to: scope)
        Log.on(.tree, "added", node: node.id, parent: id, "index=\(index)")
        markGeometryDirty(structural: true)
    }

    /// Moves an existing child from `from` to `to` within this node's own child list.
    ///
    /// This is the dedicated reordering operation (as distinct from `addSubnode(_:)`'s
    /// same-parent no-op): it always repositions the child, even when `from == to`.
    ///
    /// Ownership: no ownership changes; the child remains this node's child. Isolation:
    /// MainActor. Errors: none — an out-of-range index is diagnosed via `Log.on` and ignored.
    /// Cancellation: not applicable.
    public func moveSubnode(from: Int, to: Int) {
        guard !childrenAreArrangementManaged || Node.isResolving else {
            Log.on(.tree, "move-rejected", parent: id, "reason=arrangement-managed")
            return
        }
        guard !isDisposed else {
            Log.on(.tree, "move-rejected", parent: id, "reason=parent-disposed")
            return
        }
        guard children.indices.contains(from) else {
            Log.on(
                .tree,
                "move-rejected",
                parent: id,
                "reason=invalid-from from=\(from) count=\(children.count)"
            )
            return
        }
        guard to >= 0, to <= children.count else {
            Log.on(
                .tree,
                "move-rejected",
                parent: id,
                "reason=invalid-to to=\(to) count=\(children.count)"
            )
            return
        }
        let node = children.remove(at: from)
        let clampedTo = min(to, children.count)
        children.insert(node, at: clampedTo)
        Log.on(.tree, "moved", node: node.id, parent: id, "from=\(from) to=\(clampedTo)")
        markGeometryDirty(structural: true)
    }

    /// Detaches this node from its parent without disposing it — the node and its own
    /// subtree remain usable and may be attached elsewhere afterward.
    ///
    /// A no-op when this node has no parent.
    ///
    /// Ownership: the former parent releases the child relationship; this node keeps its
    /// children. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func removeFromSupernode() {
        guard let oldParent = parent else { return }
        guard !oldParent.childrenAreArrangementManaged || Node.isResolving else {
            Log.on(
                .tree,
                "remove-rejected",
                node: id,
                parent: oldParent.id,
                "reason=arrangement-managed"
            )
            return
        }
        oldParent.children.removeAll { $0 === self }
        parent = nil
        scope.reparent(to: nil)
        Log.on(.tree, "removed", node: id, parent: oldParent.id)
        oldParent.markGeometryDirty(structural: true)
    }

    /// Disposes this node and its entire subtree, and detaches from its parent if attached.
    ///
    /// Terminal and idempotent: a second call is a no-op. Disposing an attached node removes
    /// it from its parent's child list — no parent is left holding a disposed child.
    ///
    /// Ownership: releases all child relationships in this subtree. Isolation: MainActor.
    /// Errors: none. Cancellation: there is no owned async work to cancel in this card; a
    /// subclass with owned work overrides this to cancel it before calling `super.dispose()`.
    open func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        InvalidationTransaction.perform {
            for child in children {
                child.dispose()
            }
            removeFromSupernode()
        }
        recognizers.removeAll()
        Log.on(.tree, "disposed", node: id)
    }

    private var recognizers: [any GestureRecognizer] = []

    /// The recognizers registered on this node, in registration order — the order the arena
    /// arbitrates them in (H05, D29). A pointer session collects them at `pointerDown` from
    /// the target up to the root; a recognizer added mid-session joins the next session.
    ///
    /// Ownership: returns a value; the node retains the recognizers until `dispose()` or
    /// removal. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var gestureRecognizers: [any GestureRecognizer] { recognizers }

    /// Registers a recognizer after the existing ones. Adding the same instance twice is a
    /// no-op.
    ///
    /// Ownership: the node retains `recognizer`; its callbacks should capture the node weakly,
    /// since the node holds the recognizer. Isolation: MainActor. Errors: ignored on a
    /// disposed node. Cancellation: `dispose()` drops every recognizer.
    public func addGestureRecognizer(_ recognizer: any GestureRecognizer) {
        guard !isDisposed, !recognizers.contains(where: { $0 === recognizer }) else { return }

        recognizers.append(recognizer)
    }

    /// Removes a recognizer; a live session that already collected it keeps it until the
    /// session ends.
    ///
    /// Ownership: the node releases its reference. Isolation: MainActor. Errors: an unknown
    /// recognizer is ignored. Cancellation: not applicable.
    public func removeGestureRecognizer(_ recognizer: any GestureRecognizer) {
        recognizers.removeAll { $0 === recognizer }
    }

    /// Declaratively describes this node's children for a future resolver, or `nil` for the
    /// existing imperative child list (D03/C21: manual mode, untouched by any `Arrangement`).
    /// The default is `nil` — opting into declarative children requires overriding this.
    ///
    /// Called on MainActor before a snapshot is captured. No constraint parameter is passed:
    /// only the root's constraint is known at this point, not any descendant's — a container's
    /// own measured width is not available yet (D03). The returned tree is temporary; any node
    /// it references remains owned by whoever already owned it, not by the arrangement value.
    ///
    /// Nothing calls this yet — the resolver that reads this value and reconciles it against
    /// the live tree is future work (C23). Declaring it now lets a subclass in another module
    /// compile against the shape settled in C21 before that resolver exists (C22).
    ///
    /// Ownership: returns a temporary description; any `Node` it references is borrowed, not
    /// retained beyond the caller's own reference. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    open func arrangeSubnodes() -> (any Arrangement)? { nil }

    /// Capture-phase hook (H03, D20): called on each ancestor of the target, root first,
    /// before the target's `handleEvent`. Empty by default; override to observe or to
    /// `stopPropagation()`. The event is borrowed for the synchronous callback only.
    ///
    /// Ownership: `event` is borrowed; do not retain it. Isolation: MainActor. Errors: none.
    /// Cancellation: `event.stopPropagation()` ends later callbacks of this dispatch.
    open func handleCapture(_ event: Event) {}

    /// Target-phase hook (H03, D20): called on the node the event is addressed to, between
    /// capture and bubble. Empty by default.
    ///
    /// Ownership: `event` is borrowed; do not retain it. Isolation: MainActor. Errors: none.
    /// Cancellation: `event.stopPropagation()` skips the bubble phase.
    open func handleEvent(_ event: Event) {}

    /// Bubble-phase hook (H03, D20): called on each ancestor of the target, parent first,
    /// root last, after the target's `handleEvent`. Empty by default.
    ///
    /// Ownership: `event` is borrowed; do not retain it. Isolation: MainActor. Errors: none.
    /// Cancellation: `event.stopPropagation()` ends later callbacks of this dispatch.
    open func handleBubble(_ event: Event) {}

    /// Performs an accessibility action on this node (A07, D43). The default forwards to
    /// `onAccessibilityAction` and reports `false` when there is none; `ControlNode` handles
    /// `.activate` itself. Override to handle `.increment`/`.decrement`/custom actions in a
    /// subclass. Return `true` only when handled.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: `false` when not handled.
    /// Cancellation: not applicable.
    open func performAccessibilityAction(_ action: AccessibilityAction) -> Bool {
        onAccessibilityAction?(action) ?? false
    }

    /// Tells the host that this node's `arrangeSubnodes()` would now return something
    /// different (C32, D13) — the `Arrangement` analogue of changing `style`: the next
    /// snapshot preparation re-resolves this node (owner first, then whatever owners it
    /// places) before the layout pass reads the tree. Nothing is resolved synchronously here;
    /// call `resolveArrangement()` directly for an immediate result. The only trigger for a
    /// re-resolve besides the first flush after attach: neither structural edits under this
    /// node nor environment changes (safe area, direction — D03) re-run an `Arrangement`.
    ///
    /// Ownership: no owned state beyond a flag. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func markArrangementDirty() {
        guard !isDisposed, !isArrangementWrapper else { return }
        needsArrangementResolve = true
        Log.on(.arrange, "dirty", node: id)
        var root = self
        var depth = 0
        while let next = root.parent {
            root = next
            depth += 1
        }
        root.notifyPending(reasons: .arrangement, origin: self, depth: depth)
    }

    /// Resolves every node in this subtree whose `needsArrangementResolve` is set, in
    /// pre-order — an owner before the nodes it just placed, so a nested owner (S19's tiles)
    /// already carries its parent's placement when it resolves its own container (D12/D13)
    /// and no live node is resolved more than once per pass (C21). Called by the host's
    /// snapshot preparation (C32); implicit wrappers are skipped. A repeat pass over an
    /// unchanged tree does nothing: every flag is already clear.
    ///
    /// Ownership: mutates only `Arrangement`-managed subtrees, via `resolveArrangement()`.
    /// Isolation: MainActor. Errors: a rejected proposal is diagnosed by the resolve and
    /// clears the flag. Cancellation: not applicable — synchronous.
    package func resolveDirtyArrangements() {
        if needsArrangementResolve, !isArrangementWrapper {
            resolveArrangement()
        }
        for child in children {
            child.resolveDirtyArrangements()
        }
    }

    /// Records the placement a parent owner's resolve gave this node (C23) — called only by
    /// that resolver, never by user code; `nil` when this node leaves that owner's subtree.
    /// Re-derives `arrangementEffectiveStyle`.
    ///
    /// Ownership: takes ownership of `newValue`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    package func setArrangementPlacement(_ newValue: ArrangementPlacement?) {
        guard arrangementPlacement != newValue else { return }
        arrangementPlacement = newValue
        recomputeArrangementEffectiveStyle()
    }

    /// Records what this node's own root container decided about itself (C23) — called only
    /// by this node's own resolve; `nil` for a root `Leaf` or a `nil` `Arrangement`.
    /// Re-derives `arrangementEffectiveStyle`.
    ///
    /// Ownership: takes ownership of `newValue`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    package func setArrangementContainerStyle(_ newValue: ArrangementContainerStyle?) {
        guard arrangementContainerStyle != newValue else { return }
        arrangementContainerStyle = newValue
        recomputeArrangementEffectiveStyle()
    }

    /// Mirrors `style`'s own didSet: an equal derived value is a no-op, so a repeat resolve
    /// that lands on the same effective style does not request another flush.
    private func recomputeArrangementEffectiveStyle() {
        let derived = LayoutStyle.arrangementEffective(
            base: style,
            container: arrangementContainerStyle,
            placement: arrangementPlacement
        )
        guard arrangementEffectiveStyle != derived else { return }
        arrangementEffectiveStyle = derived
        markGeometryDirty(structural: false)
    }

    /// Fixed content-measurement facts for this node, independent of any constraint.
    ///
    /// The default is empty content — there is no live content/text system yet (N01). A
    /// subclass overrides this once it has something real to report.
    ///
    /// Ownership: the returned value is copied into a Sendable snapshot. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    open var layoutContentMetrics: LayoutContentMetrics { LayoutContentMetrics() }

    /// Content-measurement facts for a parent-provided constraint. The default ignores
    /// `constraint` and returns the same fixed value as the unconstrained accessor — content
    /// that actually depends on width (wrapping text, N01) overrides this once it exists.
    ///
    /// Ownership: the result is copied into a Sendable snapshot. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    open func layoutContentMetrics(for constraint: SizeConstraint) -> LayoutContentMetrics {
        layoutContentMetrics
    }

    /// Captures this node's subtree as an immutable input for a layout pass.
    ///
    /// `constraint` is whatever the caller already knows about available space — typically
    /// host bounds, passed in by a future coordinator (C14). This node's own resolved
    /// width/height narrows the constraint passed to *its* children, instead of forwarding
    /// `constraint` unchanged past every level (a Weave bug, §3.3/F03) — but a narrowed
    /// constraint is still not a promise of final size: grow/shrink/wrap and sibling
    /// distribution remain the solver's job (C12).
    ///
    /// Ownership: the returned snapshot owns copied values; no live `Node` or platform object
    /// is reachable from it. Isolation: MainActor. Errors: none. Cancellation: the caller owns
    /// any worker that consumes the result.
    public func makeLayoutInputSnapshot(constraint: SizeConstraint = SizeConstraint())
        -> LayoutInputSnapshot
    {
        makeLayoutInputSnapshot(constraint: constraint, isRoot: true)
    }

    /// Validates and applies a complete layout result to this subtree atomically.
    ///
    /// No frame changes if the result is malformed, belongs to another root, omits a live node,
    /// or contains an identity outside this subtree. Once accepted, every frame assignment is
    /// synchronous on the main actor; renderers may safely update native geometry afterwards.
    ///
    /// Ownership: borrows `result` and mutates this subtree's calculated-frame slots. Isolation:
    /// MainActor. Errors: invalid results return `false` without partial mutation. Cancellation:
    /// not applicable.
    @discardableResult
    public func applyLayoutResult(_ result: LayoutResult) -> Bool {
        guard result.isWellFormed, result.treeIdentity == id else { return false }

        var nodes: [Node] = []
        collectSubtreeNodes(into: &nodes)
        let expected = Set(nodes.map(\.id))
        let actual = Set(result.placements.map(\.identity))
        guard expected == actual else { return false }

        for node in nodes {
            guard let placement = result.placement(for: node.id) else { return false }

            node.calculatedFrame = placement.frame
        }
        return true
    }

    private func makeLayoutInputSnapshot(constraint: SizeConstraint, isRoot: Bool)
        -> LayoutInputSnapshot
    {
        let environment = scope.snapshot
        let baseStyle = arrangementEffectiveStyle ?? style
        let narrowedConstraint = SizeConstraint(
            width: baseStyle.width.resolved(parent: constraint.width.knownValue).map {
                .exact($0)
            } ?? constraint.width,
            height: baseStyle.height.resolved(parent: constraint.height.knownValue).map {
                .exact($0)
            } ?? constraint.height
        )

        var snapshotStyle = baseStyle
        if isRoot || safeAreaBoundary {
            let safeArea = environment.values.safeAreaInsets
            let ignored = safeAreaIgnoredEdges
            snapshotStyle.padding = DirectionalEdgeInsets(
                top: baseStyle.padding.top + (ignored.contains(.top) ? 0 : safeArea.top),
                leading: baseStyle.padding.leading
                    + (ignored.contains(.leading) ? 0 : safeArea.leading),
                bottom: baseStyle.padding.bottom
                    + (ignored.contains(.bottom) ? 0 : safeArea.bottom),
                trailing: baseStyle.padding.trailing
                    + (ignored.contains(.trailing) ? 0 : safeArea.trailing)
            )
        }

        return LayoutInputSnapshot(
            identity: id,
            style: snapshotStyle,
            content: layoutContentMetrics(for: narrowedConstraint),
            children: children.map {
                $0.makeLayoutInputSnapshot(constraint: narrowedConstraint, isRoot: false)
            },
            direction: environment.values.layoutDirection,
            environmentRevision: environment.revision,
            contentRevision: max(structureRevision, geometryRevision)
        )
    }

    private func collectSubtreeNodes(into nodes: inout [Node]) {
        nodes.append(self)
        for child in children {
            child.collectSubtreeNodes(into: &nodes)
        }
    }

    private func identityPath(to target: NodeID) -> [NodeID]? {
        if id == target { return [id] }
        for child in children {
            if let childPath = child.identityPath(to: target) { return [id] + childPath }
        }
        return nil
    }

    private func isDescendant(of candidate: Node) -> Bool {
        var current = parent
        while let node = current {
            if node === candidate { return true }
            current = node.parent
        }
        return false
    }

    /// Marks this node's geometry dirty, bumping this node's own `geometryRevision` and every
    /// ancestor's up to the current root (F01/§3.11: a descendant's size can change an
    /// ancestor's measured size, so geometry dirtiness always climbs). `structural` also bumps
    /// this node's own `structureRevision` — used by the child-list mutators and a plain style
    /// write, `structural: false`.
    ///
    /// Not `private`: `TextNode` (T04), in a different file of this module, uses this same
    /// path when a geometry-affecting field (text, non-color style, `maxLines`, `truncation`)
    /// changes — the identical shape as a plain style write, `structural: false`.
    ///
    /// Ownership: no owned state beyond revision counters. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func markGeometryDirty(structural: Bool) {
        geometryRevision &+= 1
        if structural {
            structureRevision &+= 1
        }
        let reasons: DirtyReasons = structural ? [.structure, .geometry] : .geometry
        var root = self
        var depth = 0
        while let next = root.parent {
            next.geometryRevision &+= 1
            root = next
            depth += 1
        }
        root.notifyPending(reasons: reasons, origin: self, depth: depth)
    }

    /// Marks this node's own appearance dirty. Unlike geometry, this never bumps an ancestor's
    /// revision — a paint-only change does not affect ancestor layout — but the ping still
    /// travels to the current root, since only a host attached there can act on it.
    ///
    /// Not `private`: `ControlNode` (H06), in a different file of this module, uses this same
    /// paint-only path for `isPressed` — pressed-state is presentation, not layout, and does
    /// not warrant its own parallel invalidation channel.
    ///
    /// Ownership: no owned state beyond a revision counter. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func markAppearanceDirty() {
        appearanceRevision &+= 1
        var root = self
        var depth = 0
        while let next = root.parent {
            root = next
            depth += 1
        }
        root.notifyPending(reasons: .appearance, origin: self, depth: depth)
    }

    /// Marks this node's own focus/accessibility metadata dirty (A03, D41) — the third
    /// invalidation channel next to geometry and appearance: no ancestor revision moves, no
    /// layout pass follows; the ping still reaches the root so the host can republish.
    ///
    /// Not `private`: `ControlNode.isEnabled` uses this same path.
    ///
    /// Ownership: no owned state beyond a revision counter. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func markSemanticsDirty() {
        semanticsRevision &+= 1
        var root = self
        var depth = 0
        while let next = root.parent {
            root = next
            depth += 1
        }
        root.notifyPending(reasons: .semantics, origin: self, depth: depth)
    }

    /// Marks this node's own paint-only display state dirty (ADR 0014, T04) — a fourth
    /// invalidation channel next to geometry, appearance and semantics: no ancestor revision
    /// moves, no layout pass follows, only a display/raster pass (T06) reacts. Unlike
    /// `appearance`/`semantics`, this node's own revision counter for the change (`TextNode.
    /// displayRevision`) is not stored here — only text-like nodes have one so far — so this
    /// method only pings; the caller bumps its own counter first.
    ///
    /// Not `private`: `TextNode`'s color-only style writes use this path.
    ///
    /// Ownership: no owned state. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func markDisplayDirty() {
        var root = self
        var depth = 0
        while let next = root.parent {
            root = next
            depth += 1
        }
        root.notifyPending(reasons: .display, origin: self, depth: depth)
    }

    /// Accumulates `reasons` at this node (expected to be the current root) and pings once
    /// per clean-to-dirty transition — the coalescing gate: further calls before
    /// `consumePendingInvalidation()` drains this only fold their reasons in, they do not
    /// ping again.
    ///
    /// Ownership: references `origin` weakly for the lifetime of the pending window (#31).
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    private func notifyPending(reasons: DirtyReasons, origin: Node, depth: Int) {
        recordAnimationMutation(reasons: reasons, origin: origin)
        let wasClean = pendingReasons.isEmpty
        if wasClean {
            pendingOrigin = origin
            pendingDepth = depth
        }
        pendingReasons.insert(reasons)
        guard wasClean else { return }

        if InvalidationTransaction.isActive {
            InvalidationTransaction.deferCallback(for: self)
            return
        }
        firePing(origin: origin, depth: depth)
    }

    /// Marks every currently open scope that contains the mutation origin. This deliberately
    /// runs before the clean-to-dirty guard in `notifyPending`: a second mutation in an already
    /// pending window must still make a nested/new scope relevant (D62).
    private func recordAnimationMutation(reasons: DirtyReasons, origin: Node) {
        guard reasons.isAnimationRelevant, !activeAnimationScopes.isEmpty,
            let path = identityPath(to: origin.id)
        else { return }

        let ancestors = Set(path)
        for index in activeAnimationScopes.indices
        where ancestors.contains(activeAnimationScopes[index].scopeNodeID) {
            activeAnimationScopes[index].observedMutation = true
        }
    }

    /// Delivers the ping for the current pending window, or logs that it was dropped because
    /// no host has attached `onInvalidate` — the common cause of "nothing happens" while
    /// building a tree with no host mounted yet.
    ///
    /// Ownership: no owned state. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    private func firePing(origin: Node, depth: Int) {
        guard let onInvalidate else {
            Log.on(
                .invalidate,
                "dropped",
                node: origin.id,
                "root=\(id) depth=\(depth) reasons=\(pendingReasons)"
            )
            return
        }
        Log.on(
            .invalidate,
            "requested",
            node: origin.id,
            "root=\(id) depth=\(depth) reasons=\(pendingReasons)"
        )
        onInvalidate(origin, pendingReasons)
    }

    /// Fires the ping for this node's still-pending window, if any — called once by
    /// `InvalidationTransaction` when the outermost transaction touching this root ends.
    ///
    /// Ownership: no owned state. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func fireDeferredInvalidationIfNeeded() {
        guard !pendingReasons.isEmpty else { return }
        firePing(origin: pendingOrigin ?? self, depth: pendingDepth)
    }
}
