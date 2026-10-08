import CoreGraphics
import QuartzCore
import TrellisCore

/// One platform-neutral CALayer renderer for a committed Trellis node tree.
///
/// The renderer owns exactly the layers in its private `LayerRegistry`; it never removes an
/// unregistered host sublayer. Geometry is converted from root-absolute layout frames to each
/// parent layer's local coordinates, so reparenting preserves a node's layer identity.
///
/// Ownership: retains only Trellis-created layers, not the logical tree or host layer.
/// Isolation: MainActor. Errors: nodes without committed frames are ignored and logged.
/// Cancellation: `unmount()` detaches every owned layer; later calls may materialize new layers.
@MainActor
public final class LayerRenderer {
    private let registry = LayerRegistry()

    /// M04's small explicit animator: diffs each committed node's D61 property table and either
    /// retargets an in-flight `CABasicAnimation` or snaps, per `AnimationIntent` resolved from
    /// the tree `Node.animate` recorded this commit. Owned here, not by `NodeHostBridge`, so a
    /// direct `applyCommitted`/`applyAppearance` call in a test exercises the same reconciliation
    /// path production commits do.
    private let animator = LayerAnimator()

    /// The internal raster layer for each `TextNode`, keyed by the node's own `NodeID` (T07,
    /// D65). Deliberately not part of `LayerRegistry`: that registry is the sole NodeID-to-layer
    /// lookup hit-testing, focus, and accessibility use, and a raster layer has no identity of
    /// its own there — it is plumbing nested one level inside its node's own (outer) layer, never
    /// a sibling a hit-test or `orderOwnedChildren` needs to reason about.
    private var rasterLayers: [NodeID: CALayer] = [:]

    /// One `NativeScrollBacking` per committed `ScrollNode` (R07), the same lifecycle as
    /// `rasterLayers`: materialized on first committed `.scroll` node, purged in both
    /// `removeStaleLayers` and `unmount()`, never registered in `LayerRegistry` under its own
    /// key — `registry` holds `backing.containerLayer` for the node's own identity instead
    /// (`materializeScrollBacking(for:request:)`).
    private var scrollBackings: [NodeID: any NativeScrollBacking] = [:]

    /// The content `CALayer` installed on each `scrollBackings` entry — a `ScrollNode`'s
    /// children are parented here, not to `registry`'s own layer for the node (which is the
    /// backing's `containerLayer`, the native scroll view itself).
    private var scrollContentLayers: [NodeID: CALayer] = [:]

    /// The union of each `ScrollNode`'s children's committed frames, in content space —
    /// recomputed every commit, read by `NodeHostBridge` to publish `ScrollState.contentSize`.
    private var scrollContentSizes: [NodeID: MeasuredSize] = [:]

    /// Creates a `NativeScrollBacking` for a newly committed `.scroll` `ScrollNode` — `nil`
    /// until a host adapter supplies one (`NodeHostBridge.attach(...)`'s `scrollBackingFactory`
    /// parameter, D51's precedent). The delegate is already bound by the caller, so this
    /// renderer only stores a plain `(NodeID) -> any NativeScrollBacking` closure.
    ///
    /// Ownership: retained until replaced or `unmount()`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    var scrollBackingFactory: (@MainActor (NodeID) -> any NativeScrollBacking)?

    /// Node identities a composite transition session (M11–M13) is temporarily hiding
    /// (`setTransitionHidden(_:hidden:)`) — consulted by `applyPresentation(of:to:)` on every
    /// subsequent commit, geometry or paint-only. Fixes a real bug found running S29 in the
    /// iOS Simulator (M13, `docs/defects.md`): the transition engine used to write
    /// `CALayer.opacity` directly, bypassing `Node.style.visual.opacity`; the very next
    /// ordinary commit (paint-only, e.g. an unrelated accessibility metadata republish) then
    /// called `applyPresentation`, which unconditionally recomputed `layer.opacity` from the
    /// unchanged model value and silently un-hid the source card the transition had just
    /// hidden. This set makes the hide an authoritative part of what `applyPresentation`
    /// computes, not a one-shot side write something else can immediately overwrite.
    private var transitionHiddenNodeIDs: Set<NodeID> = []

    /// M11 (D71 §3, `docs/validation/m10-transition-contract.md` §3): title-endpoint raster
    /// layers for the active `TransitionSession`, keyed by role and side rather than `NodeID` —
    /// a third table of `rasterLayers`'s general shape, kept separate because its lifetime is
    /// one transition session's, not one tree node's, and because a session's roles are not
    /// `NodeID`s of their own. Never mixed with `rasterLayers`, for the same reason that table
    /// is never mixed with `LayerRegistry`: no second identity space for hit-test/AX to trip on.
    private var transitionRasterLayers: [TransitionRasterKey: CALayer] = [:]

    /// The temporary session overlay this renderer currently owns, if a `TransitionSession` is
    /// active — `LayerRenderer`-owned exactly like `rasterLayers`' layers, mounted directly on
    /// the host layer rather than inside `LayerRegistry`.
    private var transitionOverlayLayer: CALayer?

    /// Creates and mounts this mount's transition overlay layer directly on `hostLayer`, on top
    /// of every ordinary Trellis layer (added last, so paints last within `hostLayer`'s own
    /// sublayer order). One overlay at a time — a second call before `endTransitionOverlay()`
    /// replaces the previous overlay's registration without detaching it, which
    /// `TransitionEngine` never does (it always ends the previous session first, D72's "не
    /// создаёт вторую копию").
    ///
    /// Ownership: the renderer retains the returned layer until `endTransitionOverlay()`.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func beginTransitionOverlay(on hostLayer: CALayer) -> CALayer {
        let overlay = CALayer()
        overlay.masksToBounds = false
        hostLayer.addSublayer(overlay)
        transitionOverlayLayer = overlay
        Log.on(.layer, "transition-overlay-begin")
        return overlay
    }

    /// Materializes (or returns) the title-endpoint raster layer for one role/side of the
    /// active transition session, as a sublayer of `parent` — the session-scoped counterpart of
    /// `materializeRasterLayer(for:host:)`, same fixed-origin-anchor/clip shape, no participation
    /// in `LayerRegistry`/hit-test/AX (D73: a title-endpoint raster is not a second copy of the
    /// text for assistive technology, because it never is one — the real `TextNode` is what AX
    /// reads, this is paint-only).
    ///
    /// Ownership: the renderer retains the returned layer until `endTransitionOverlay()`.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func materializeTransitionRasterLayer(
        role: Role,
        side: TransitionEndpointSide,
        parent: CALayer
    ) -> CALayer {
        let key = TransitionRasterKey(role: role, side: side)
        if let existing = transitionRasterLayers[key] { return existing }

        let raster = CALayer()
        raster.anchorPoint = CGPoint(x: 0, y: 0)
        raster.contentsGravity = .topLeft
        raster.masksToBounds = true
        parent.addSublayer(raster)
        transitionRasterLayers[key] = raster
        return raster
    }

    /// Releases every layer the active transition session owns — the overlay itself (which
    /// removes every sublayer, including title rasters, from the layer tree in one call) and
    /// this renderer's own bookkeeping for them. Called by `TransitionEngine` on every path a
    /// session can end: close settled, detach, suspend, competing-present-rejected cleanup is
    /// never needed (a rejected `presentTransition` never created a session). A no-op if no
    /// overlay is currently owned.
    ///
    /// Ownership: releases the overlay layer and every transition raster layer. Isolation:
    /// MainActor. Errors: none. Cancellation: this call is itself the teardown.
    func endTransitionOverlay() {
        guard let overlay = transitionOverlayLayer else { return }

        overlay.removeFromSuperlayer()
        transitionOverlayLayer = nil
        transitionRasterLayers.removeAll()
        Log.on(.layer, "transition-overlay-end")
    }

    /// Number of transition-session raster layers currently materialized — a leak-detection
    /// test hook (M11 checklist: "release of temporary layers... no leak on close/detach/
    /// suspend").
    var transitionRasterLayerCount: Int { transitionRasterLayers.count }

    /// Test hook: the raster layer for one specific role/side, if materialized — lets a test
    /// sample its `presentation()` value directly (M14: a role's own sub-interval timing),
    /// rather than only counting how many exist.
    func transitionRasterLayer(role: Role, side: TransitionEndpointSide) -> CALayer? {
        transitionRasterLayers[TransitionRasterKey(role: role, side: side)]
    }

    /// Whether this renderer currently owns a transition overlay layer — a test hook mirroring
    /// `transitionRasterLayerCount`.
    var hasTransitionOverlay: Bool { transitionOverlayLayer != nil }

    /// C30 experiment: when `true`, an implicit `Arrangement` wrapper that paints nothing
    /// (default `appearance`) and carries no group effect (default `style.visual`: no
    /// clipping, opacity, transform or z-index) gets no `CALayer`; its children are parented
    /// to the nearest ancestor that has one, in the same pre-order they would appear in. A
    /// wrapper with any of those properties keeps a layer — the effects need one and are
    /// never dropped silently. Off by default; the decision on making it the model is
    /// recorded in docs/validation/c30-layout-only-wrappers.md.
    ///
    /// Ownership: the renderer stores the flag; takes effect at the next commit (a wrapper's
    /// layer is removed or re-created and its children reparented then). Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var skipsLayoutOnlyWrappers = false

    /// Called once, at commit time, for every identity this renderer just stopped rendering —
    /// removed from the tree since the last commit, or superseded by a full `unmount()` is
    /// *not* reported here (that path removes everything at once by design; a fresh mount's own
    /// `DisplayScheduler` starts empty regardless).
    ///
    /// T10/D58: `TextNode` has no reference back to the host's `DisplayScheduler`, so its
    /// `dispose()` cannot cancel its own raster job the way D58 originally described. This hook
    /// gives `NodeHostBridge` the one place `LayerRenderer` already computes "no longer active"
    /// (`removeStaleLayers`, the same tree-wide diff `scanForDisplayWork` mirrors) to purge the
    /// scheduler's queue and committed table for that `NodeID` instead.
    ///
    /// Ownership: retained until replaced. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var onNodeRemoved: (@MainActor (NodeID) -> Void)?

    /// Creates an empty native-layer renderer.
    ///
    /// Ownership: the caller owns the renderer. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Returns the Trellis-owned layer for one node, if materialized.
    ///
    /// Ownership: the renderer retains the returned layer. Isolation: MainActor. Errors: an
    /// unknown node returns `nil`. Cancellation: not applicable.
    public func layer(for identity: NodeID) -> CALayer? { registry.layer(for: identity) }

    /// The `NativeScrollBacking` materialized for one committed `ScrollNode`, if any (R07) — a
    /// test/inspection hook and `NodeHostBridge`'s own read path for `ScrollCommandIssuing` and
    /// `ScrollState` publishing.
    ///
    /// Ownership: the renderer retains the returned backing. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func scrollBacking(for identity: NodeID) -> (any NativeScrollBacking)? {
        scrollBackings[identity]
    }

    /// The current native content offset for every committed `ScrollNode` with a materialized
    /// backing — read fresh from each backing's own `contentOffset` (native is the source of
    /// truth, §8), not cached, so it is always what hit-testing should see (`NodeHostBridge`
    /// feeds this into `HitTestSnapshot.withScrollOffsets(_:)`).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func currentScrollOffsets() -> [NodeID: LayoutPoint] {
        scrollBackings.mapValues(\.contentOffset)
    }

    /// The content-space union of a `ScrollNode`'s children's committed frames, as computed at
    /// the most recent commit — `NodeHostBridge` reads this to publish `ScrollState.contentSize`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func scrollContentSize(for identity: NodeID) -> MeasuredSize? {
        scrollContentSizes[identity]
    }

    /// Every committed `ScrollNode` identity with a materialized backing — `NodeHostBridge`
    /// republishes `ScrollState` for each of these on every geometry commit.
    func scrollBackingIdentities() -> [NodeID] {
        Array(scrollBackings.keys)
    }

    /// The internal raster layer for a `TextNode`, if one has been materialized (T07) — `nil`
    /// for a non-text node and before that node's first commit. A test/inspection hook: nothing
    /// in the render path other than this class reads it.
    ///
    /// Ownership: the renderer retains the returned layer. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func rasterLayer(for identity: NodeID) -> CALayer? { rasterLayers[identity] }

    /// Number of layers this renderer currently owns.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var layerCount: Int { registry.count }

    /// Total layers this renderer has ever created (C26): with `layerCount` it says how many
    /// commits reused their layers instead of allocating — a steady tree must not grow it.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var createdLayerTotal = 0

    /// Applies already-committed frames and appearance beneath `hostLayer` in one disabled-action
    /// transaction. Equivalent to `applyCommitted(root:on:hostLayer:envelope:)` with an empty,
    /// epoch-0 envelope: every D61 property that changed snaps, exactly as before M04 added the
    /// explicit animator (no `Node.animate` scope can resolve without real intents).
    ///
    /// Ownership: borrows `root`, `hostLayer`, and `request`; retains only created layers.
    /// Isolation: MainActor. Errors: an incomplete committed tree is left unchanged. Cancellation:
    /// not applicable because a coordinator calls this only after a validated commit.
    public func applyCommitted(root: Node, on hostLayer: CALayer, request: HostRenderRequest) {
        applyCommittedCore(root: root, on: hostLayer, request: request, mountEpoch: 0, intents: [])
    }

    /// Applies already-committed frames and appearance beneath `hostLayer`, additionally
    /// reconciling D61's explicit per-property animation table against `envelope.intents` (M04):
    /// a node whose layer already existed at the same parent gets a diff/retarget through
    /// `LayerAnimator`; a layer materialized or reparented this commit always snaps (D62), and
    /// `envelope.epoch` is the mount epoch both `Node.animate`'s recorded scopes and this
    /// renderer's own animation keys use, so a stale intent from a previous mount never matches.
    ///
    /// Ownership: borrows `root`, `hostLayer`, and `envelope`; retains only created layers.
    /// Isolation: MainActor. Errors: as `applyCommitted(root:on:request:)`. Cancellation: not
    /// applicable — a coordinator calls this only after a validated commit.
    package func applyCommitted(
        root: Node,
        on hostLayer: CALayer,
        envelope: AnimationCommitEnvelope
    ) {
        applyCommittedCore(
            root: root,
            on: hostLayer,
            request: envelope.request,
            mountEpoch: envelope.epoch,
            intents: envelope.intents
        )
    }

    private func applyCommittedCore(
        root: Node,
        on hostLayer: CALayer,
        request: HostRenderRequest,
        mountEpoch: UInt64,
        intents: [AnimationIntent]
    ) {
        guard root.calculatedFrame != nil else {
            Log.on(
                .layer,
                "missing-frame",
                host: request.hostID,
                generation: request.generation,
                node: root.id
            )
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var active: Set<NodeID> = []
        update(
            node: root,
            parentLayer: hostLayer,
            parentFrame: nil,
            parentScrollBacking: nil,
            request: request,
            animationRoot: root,
            mountEpoch: mountEpoch,
            intents: intents,
            active: &active
        )
        removeStaleLayers(except: active, request: request, mountEpoch: mountEpoch)
    }

    /// Reapplies paint-only fields to one materialized node without changing its geometry.
    ///
    /// Ownership: borrows `node`; the renderer retains its layer. Isolation: MainActor. Errors:
    /// an unmaterialized node is ignored. Cancellation: not applicable.
    public func applyAppearance(of node: Node) {
        guard let layer = registry.layer(for: node.id) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPresentation(of: node, to: layer)
        CATransaction.commit()
        Log.on(.layer, "visual", node: node.id, "paint-only=true")
    }

    /// Re-applies presentation to every committed layer under `root` without touching
    /// geometry — the paint-only path (C09/C29): the pending window only names the first
    /// origin, so a burst of appearance edits is applied tree-wide rather than tracked per
    /// node. Nodes without a layer (never committed) are skipped.
    ///
    /// Ownership: mutates only owned layers. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func applyAppearance(root: Node) {
        applyAppearanceCore(root: root, mountEpoch: 0, intents: [], host: nil, generation: nil)
    }

    /// Re-applies presentation to every committed layer under `root`, additionally reconciling
    /// D61's explicit animation table against `envelope.intents` (M04) — the paint-only
    /// counterpart of `applyCommitted(root:on:hostLayer:envelope:)`: this path never changes
    /// geometry, so only `opacity`/`backgroundColor`/`cornerRadius`/`transform` can actually
    /// diff, but the same per-property reconcile is used unconditionally rather than a second,
    /// narrower table.
    ///
    /// Ownership: mutates only owned layers. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    package func applyAppearance(root: Node, envelope: AnimationCommitEnvelope) {
        applyAppearanceCore(
            root: root,
            mountEpoch: envelope.epoch,
            intents: envelope.intents,
            host: envelope.request.hostID,
            generation: envelope.request.generation
        )
    }

    private func applyAppearanceCore(
        root: Node,
        mountEpoch: UInt64,
        intents: [AnimationIntent],
        host: UInt64?,
        generation: UInt64?
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyAppearanceRecursively(
            root,
            animationRoot: root,
            mountEpoch: mountEpoch,
            intents: intents,
            host: host,
            generation: generation
        )
        CATransaction.commit()
        Log.on(.layer, "visual", node: root.id, "paint-only=true scope=tree")
    }

    private func applyAppearanceRecursively(
        _ node: Node,
        animationRoot: Node,
        mountEpoch: UInt64,
        intents: [AnimationIntent],
        host: UInt64?,
        generation: UInt64?
    ) {
        if let layer = registry.layer(for: node.id) {
            let before = animator.captureBeforeState(layer: layer)
            applyPresentation(of: node, to: layer)
            let intent = resolvedIntent(
                for: node,
                animationRoot: animationRoot,
                intents: intents,
                epoch: mountEpoch
            )
            animator.reconcile(
                nodeID: node.id,
                layer: layer,
                before: before,
                mountEpoch: mountEpoch,
                intent: intent,
                host: host,
                generation: generation
            )
        }
        for child in node.subnodes {
            applyAppearanceRecursively(
                child,
                animationRoot: animationRoot,
                mountEpoch: mountEpoch,
                intents: intents,
                host: host,
                generation: generation
            )
        }
    }

    /// Commits a rasterized bitmap to a `TextNode`'s internal raster layer (T07, D53's
    /// `DisplayScheduler.onArtifactCommitted` calls this). A no-op if the node has never been
    /// committed (its raster layer does not exist) or was removed since the raster job started
    /// — there is nothing stale to clean up because a removed node's layer, outer or raster, is
    /// simply gone.
    ///
    /// The bitmap is drawn at its own device-pixel size, anchored to the layer's origin
    /// (`contentsGravity = .topLeft`) and clipped to the layer's current bounds
    /// (`masksToBounds = true`) rather than stretched to fill them — a resize changes the raster
    /// layer's `bounds` immediately at commit time (see `update(node:...)`), so by the time a new
    /// artifact arrives here the old bitmap has already been sitting clipped, not stretched, at
    /// the new box (D65).
    ///
    /// Ownership: retains `artifact.image` for as long as the layer keeps it as `contents`.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable — a cancelled or
    /// superseded raster job never reaches this method (`DisplayScheduler`).
    public func applyDisplayArtifact(_ artifact: DisplayArtifact, for nodeID: NodeID) {
        guard let raster = rasterLayers[nodeID] else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        raster.contents = artifact.image
        raster.contentsScale = CGFloat(artifact.scale)
        CATransaction.commit()
        Log.on(
            .layer,
            "display",
            node: nodeID,
            "px=\(artifact.pixelWidth)x\(artifact.pixelHeight) scale=\(artifact.scale)"
        )
    }

    /// Removes a stale bitmap from a `TextNode`'s raster layer immediately, before its
    /// replacement is ready (T07, D65). The caller uses this only when the *content* to draw
    /// changed (text/style/theme/locale) — never for a pure resize/rescale, where the old
    /// bitmap stays visible (clipped, not stretched) until a fresh one lands; showing the
    /// previous text as if it were still current is the one thing D65 rules out, and a
    /// temporary empty layer is the accepted alternative. A no-op for a node with no raster
    /// layer yet.
    ///
    /// Ownership: no state retained past the call. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func clearDisplayContent(for nodeID: NodeID) {
        guard let raster = rasterLayers[nodeID], raster.contents != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        raster.contents = nil
        CATransaction.commit()
        Log.on(.layer, "display-cleared", node: nodeID)
    }

    /// Detaches every layer owned by this renderer and preserves all external host sublayers.
    ///
    /// Ownership: releases the registry's layers. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal for current materialized layers; the renderer can be reused.
    public func unmount() {
        // Native view layers must be detached by their view owner, never independently of
        // the UIView/NSView hierarchy (R08, defect #80).
        let nativeLayers = Set(scrollBackings.values.map { ObjectIdentifier($0.containerLayer) })
        for (identity, backing) in scrollBackings {
            backing.removeContentLayer()
            backing.dispose()
            Log.on(.layer, "scroll-backing-removed", node: identity, "reason=unmount")
        }
        for layer in registry.removeAll() where !nativeLayers.contains(ObjectIdentifier(layer)) {
            layer.removeFromSuperlayer()
        }
        rasterLayers.removeAll()
        scrollBackings.removeAll()
        scrollContentLayers.removeAll()
        scrollContentSizes.removeAll()
        transitionHiddenNodeIDs.removeAll()
        animator.unmount()
        endTransitionOverlay()
        Log.on(.layer, "unmount")
    }

    /// Temporarily overrides `node`'s real layer opacity to `0` for the duration of an active
    /// composite transition (M11's source/destination hide), or clears the override and
    /// restores the layer to `node`'s own model opacity. See `transitionHiddenNodeIDs`'s doc
    /// comment for the bug this replaced (a direct, one-shot `layer.opacity` write that any
    /// later ordinary commit silently undid).
    ///
    /// Ownership: mutates only `node`'s already-materialized layer, if any. Isolation:
    /// MainActor. Errors: none — a node with no layer yet is a no-op. Cancellation: not
    /// applicable.
    func setTransitionHidden(_ node: Node, hidden: Bool) {
        if hidden {
            transitionHiddenNodeIDs.insert(node.id)
        } else {
            transitionHiddenNodeIDs.remove(node.id)
        }
        guard let layer = registry.layer(for: node.id) else { return }
        layer.opacity = hidden ? 0 : Float(node.style.visual.opacity)
    }

    /// D67: ends every explicit animation this renderer's `animator` currently has active in
    /// `mountEpoch` right where it is headed, without waiting for a new commit — the bridge
    /// calls this from `suspend()` ("активное движение заканчивается snap'ом к committed
    /// target") and when Reduce Motion turns on while something is mid-transition ("немедленно
    /// завершает собственные активные переходы на target, без нового solve"). A no-op when
    /// nothing is animating.
    ///
    /// Ownership: touches only layers already owned by `registry`. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    func finishActiveAnimations(mountEpoch: UInt64) {
        animator.finishAllActive(mountEpoch: mountEpoch) { [registry] nodeID in
            registry.layer(for: nodeID)
        }
    }

    /// Whether any explicit D61 animation is currently in flight in `mountEpoch` — M07's scene
    /// readiness (D69) treats this as one of three independent readiness axes (layout/display/
    /// animation), never inferred from CALayer directly since a removed animation object is not
    /// guaranteed gone from `CALayer` the instant `removeAnimation(forKey:)` returns.
    func hasActiveAnimations(mountEpoch: UInt64) -> Bool {
        animator.activeCount(mountEpoch: mountEpoch) > 0
    }

    /// D67: Reduce Motion resolves every intent to `.none` at commit time — read live off
    /// `node`'s own environment (inherited, so a subtree can override the host's default)
    /// rather than baked into the `AnimationIntent` itself. `animator.reconcile` treats a `nil`
    /// intent and a positive-duration-less one identically (both snap), so resolving to `nil`
    /// here reaches the exact same code path as a real `.none` intent would — no accessible
    /// way to construct a new `AnimationIntent` outside `TrellisCore` anyway (its memberwise
    /// initializer is `internal`, not `package`).
    private func resolvedIntent(
        for node: Node,
        animationRoot: Node,
        intents: [AnimationIntent],
        epoch: UInt64
    ) -> AnimationIntent? {
        guard !node.environment.reduceMotion else { return nil }
        return animationRoot.resolvedAnimationIntent(for: node.id, from: intents, epoch: epoch)
    }

    private func update(
        node: Node,
        parentLayer: CALayer,
        parentFrame: LayoutFrame?,
        parentScrollBacking: (any NativeScrollBacking)?,
        request: HostRenderRequest,
        animationRoot: Node,
        mountEpoch: UInt64,
        intents: [AnimationIntent],
        active: inout Set<NodeID>
    ) {
        guard let frame = node.calculatedFrame else {
            Log.on(
                .layer,
                "missing-frame",
                host: request.hostID,
                generation: request.generation,
                node: node.id
            )
            return
        }

        if skipsLayoutOnlyWrappers, Self.isLayoutOnlyWrapper(node) {
            // No layer of its own: the children hang off `parentLayer`, positioned against
            // the painting ancestor's frame — root-absolute frames make that a subtraction.
            for child in node.subnodes {
                update(
                    node: child,
                    parentLayer: parentLayer,
                    parentFrame: parentFrame,
                    parentScrollBacking: parentScrollBacking,
                    request: request,
                    animationRoot: animationRoot,
                    mountEpoch: mountEpoch,
                    intents: intents,
                    active: &active
                )
            }
            return
        }

        active.insert(node.id)

        if let scrollNode = node as? ScrollNode, node.style.visual.overflow == .scroll,
            let factory = scrollBackingFactory
        {
            updateScrollBackedNode(
                scrollNode,
                factory: factory,
                frame: frame,
                parentScrollBacking: parentScrollBacking,
                request: request,
                animationRoot: animationRoot,
                mountEpoch: mountEpoch,
                intents: intents,
                active: &active
            )
            return
        }

        let isNewLayer = registry.layer(for: node.id) == nil
        let layer = materializeLayer(for: node, request: request)
        // D62: a layer materialized this commit has nothing to retarget from, and a reparent
        // invalidates the coordinate-space assumption a retarget would rely on — both snap via
        // `animator.snapAll` below instead of `animator.reconcile`. Read before any geometry or
        // appearance write below changes `layer.superlayer` or its D61 property values.
        let snapsThisCommit = isNewLayer || layer.superlayer !== parentLayer
        let before = snapsThisCommit ? nil : animator.captureBeforeState(layer: layer)
        let parentOrigin = parentFrame?.origin ?? LayoutPoint(x: 0, y: 0)
        let localOrigin = LayoutPoint(
            x: frame.origin.x - parentOrigin.x,
            y: frame.origin.y - parentOrigin.y
        )
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let position = CGPoint(
            x: localOrigin.x + frame.width * Double(layer.anchorPoint.x),
            y: localOrigin.y + frame.height * Double(layer.anchorPoint.y)
        )
        layer.bounds = bounds
        layer.position = position
        layer.contentsScale = CGFloat(request.scale)
        applyPresentation(of: node, to: layer)
        if node is TextNode {
            let raster = materializeRasterLayer(for: node.id, host: layer)
            raster.bounds = bounds
            raster.position = CGPoint.zero
            raster.contentsScale = CGFloat(request.scale)
        }
        Log.on(
            .layer,
            "geometry",
            host: request.hostID,
            generation: request.generation,
            node: node.id,
            "frame=\(frame.origin.x),\(frame.origin.y),\(frame.width)x\(frame.height) scale=\(request.scale)"
        )

        if layer.superlayer !== parentLayer {
            parentLayer.addSublayer(layer)
            Log.on(
                .layer,
                "reparent",
                host: request.hostID,
                generation: request.generation,
                node: node.id
            )
        }

        // M04/D61: reconcile after every property write above has landed on `layer`'s model
        // values — `before` (captured pre-write, or `nil` for a new/reparented layer) and the
        // just-written values are what `animator` diffs; an unresolved scope, `.none`, or an
        // undefined rotation retarget all degrade to a snap inside `reconcile` itself.
        if snapsThisCommit {
            animator.snapAll(
                nodeID: node.id,
                layer: layer,
                mountEpoch: mountEpoch,
                host: request.hostID,
                generation: request.generation
            )
        } else if let before {
            let intent = resolvedIntent(
                for: node,
                animationRoot: animationRoot,
                intents: intents,
                epoch: mountEpoch
            )
            animator.reconcile(
                nodeID: node.id,
                layer: layer,
                before: before,
                mountEpoch: mountEpoch,
                intent: intent,
                host: request.hostID,
                generation: request.generation
            )
        }

        for child in node.subnodes {
            update(
                node: child,
                parentLayer: layer,
                parentFrame: frame,
                parentScrollBacking: parentScrollBacking,
                request: request,
                animationRoot: animationRoot,
                mountEpoch: mountEpoch,
                intents: intents,
                active: &active
            )
        }
        orderOwnedChildren(of: node, in: layer)
    }

    /// The `.scroll`-`ScrollNode` branch of `update(node:...)` (R07): materializes (or reuses)
    /// this node's `NativeScrollBacking`, positions its `containerLayer` at `frame` in
    /// host-absolute coordinates (see `NativeScrollBacking.containerLayer`'s own doc for why),
    /// sizes the installed content layer from the union of this node's children's committed
    /// frames, and recurses into children with the content layer as their parent instead of a
    /// plain materialized layer.
    private func updateScrollBackedNode(
        _ node: ScrollNode,
        factory: @MainActor (NodeID) -> any NativeScrollBacking,
        frame: LayoutFrame,
        parentScrollBacking: (any NativeScrollBacking)?,
        request: HostRenderRequest,
        animationRoot: Node,
        mountEpoch: UInt64,
        intents: [AnimationIntent],
        active: inout Set<NodeID>
    ) {
        let isNew = scrollBackings[node.id] == nil
        let backing: any NativeScrollBacking
        let contentLayer: CALayer
        if let existingBacking = scrollBackings[node.id],
            let existingContent = scrollContentLayers[node.id]
        {
            backing = existingBacking
            contentLayer = existingContent
        } else {
            backing =
                parentScrollBacking?.makeChildBacking(nodeID: node.id)
                ?? factory(node.id)
            let newContentLayer = CALayer()
            newContentLayer.masksToBounds = false
            newContentLayer.anchorPoint = CGPoint(x: 0, y: 0)
            backing.installContentLayer(newContentLayer)
            scrollBackings[node.id] = backing
            scrollContentLayers[node.id] = newContentLayer
            registry.set(backing.containerLayer, for: node.id)
            createdLayerTotal += 1
            Log.on(
                .layer,
                "create",
                host: request.hostID,
                generation: request.generation,
                node: node.id,
                "scroll-backing=true"
            )
            contentLayer = newContentLayer
        }
        let layer = backing.containerLayer

        // Host-absolute, not relative to `parentLayer`: `containerLayer` is not a sublayer of
        // `parentLayer` (the adapter placed it in a fixed top-level container at creation) —
        // `frame` is already root-absolute (`HitTestSnapshot.Record.frame`'s own contract).
        // Positioning goes through `backing.setFrame(_:)`, not a direct `containerLayer.bounds`/
        // `.position` write: a `UIView`/`NSView`'s own `frame` is independent bookkeeping from
        // its layer's `bounds`/`position`, and UIKit/AppKit's own hit-testing reads the view's
        // `frame`, not the layer's (found while implementing R07's embedding tests — a first
        // version wrote the layer directly, which looked correct on screen but left
        // `UIScrollView.frame` stale at `.zero`, `docs/validation/r07-scroll-node.md`). Also
        // avoids the earlier, related bug this replaced: writing `layer.bounds` directly would
        // have reset `bounds.origin`, which *is* the native content offset on
        // `UIScrollView`/`NSScrollView`, to zero on every commit.
        backing.setFrame(frame, relativeTo: parentScrollBacking?.contentOriginInHost)
        layer.contentsScale = CGFloat(request.scale)
        applyPresentation(of: node, to: layer)

        let contentSize = Self.scrollContentSize(of: node, viewportFrame: frame)
        scrollContentSizes[node.id] = contentSize
        backing.setContentSize(contentSize)
        backing.setInsets(Self.resolvedScrollInsets(for: node))
        backing.apply(configuration: node.configuration)

        contentLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: contentSize.height
        )
        contentLayer.position = .zero
        contentLayer.contentsScale = CGFloat(request.scale)

        // D61 explicit animation is not reconciled for a scroll-backed node's own container
        // geometry (R07's scope boundary, `docs/validation/r07-scroll-node.md`) — only a newly
        // materialized backing snaps, matching every other newly materialized layer's
        // treatment (D62).
        if isNew {
            animator.snapAll(
                nodeID: node.id,
                layer: layer,
                mountEpoch: mountEpoch,
                host: request.hostID,
                generation: request.generation
            )
        }

        Log.on(
            .layer,
            "geometry",
            host: request.hostID,
            generation: request.generation,
            node: node.id,
            "frame=\(frame.origin.x),\(frame.origin.y),\(frame.width)x\(frame.height) scale=\(request.scale) scroll-backing=true"
        )

        for child in node.subnodes {
            update(
                node: child,
                parentLayer: contentLayer,
                parentFrame: frame,
                parentScrollBacking: backing,
                request: request,
                animationRoot: animationRoot,
                mountEpoch: mountEpoch,
                intents: intents,
                active: &active
            )
        }
        orderOwnedChildren(of: node, in: contentLayer)
    }

    /// The content-space union of `node`'s children's committed frames, relative to
    /// `viewportFrame`'s own origin — never smaller than the viewport itself (empty/short
    /// content clamps `ScrollState.offset` to zero via `ScrollState.clamp`).
    private static func scrollContentSize(
        of node: ScrollNode,
        viewportFrame: LayoutFrame
    ) -> MeasuredSize {
        var maxX = viewportFrame.width
        var maxY = viewportFrame.height
        for child in node.subnodes {
            guard let childFrame = child.calculatedFrame else { continue }

            maxX = max(maxX, childFrame.origin.x - viewportFrame.origin.x + childFrame.width)
            maxY = max(maxY, childFrame.origin.y - viewportFrame.origin.y + childFrame.height)
        }
        return MeasuredSize(width: maxX, height: maxY)
    }

    /// `ScrollConfiguration.contentInsets` plus safe area, summed exactly once
    /// (`scroll-configuration.md` §2.2) — `insetsSafeArea == false` opts out of the safe-area
    /// addition entirely, not just of Trellis's own contribution.
    private static func resolvedScrollInsets(for node: ScrollNode) -> DirectionalEdgeInsets {
        let configured = node.configuration.contentInsets
        guard node.configuration.insetsSafeArea else { return configured }

        let safeArea = node.environment.safeAreaInsets
        return DirectionalEdgeInsets(
            top: configured.top + safeArea.top,
            leading: configured.leading + safeArea.leading,
            bottom: configured.bottom + safeArea.bottom,
            trailing: configured.trailing + safeArea.trailing
        )
    }

    /// Creates (or returns) `nodeID`'s internal raster layer as a sublayer of its own outer
    /// `host` layer (T07, D65). Unlike the outer layer, it never participates in
    /// `orderOwnedChildren`/hit-testing/AX — it is not a logical child, so there is nothing to
    /// reorder it against; a `TextNode` is a leaf, and even if it were not, this layer stays
    /// out of `paintedDescendantLayers` entirely because it is never registered there.
    ///
    /// `anchorPoint` is pinned to the layer's own origin `(0, 0)` rather than the CALayer
    /// default `(0.5, 0.5)`, so `position = .zero` always means "top-left of the content area",
    /// independent of the layer's current `bounds` size — the fixed anchor D65 calls for.
    /// `contentsGravity = .topLeft` and `masksToBounds = true` together mean an existing bitmap
    /// is clipped, never stretched, when `bounds` changes before a new one arrives.
    private func materializeRasterLayer(for nodeID: NodeID, host: CALayer) -> CALayer {
        if let existing = rasterLayers[nodeID] { return existing }

        let raster = CALayer()
        raster.anchorPoint = CGPoint(x: 0, y: 0)
        raster.contentsGravity = .topLeft
        raster.masksToBounds = true
        host.addSublayer(raster)
        rasterLayers[nodeID] = raster
        return raster
    }

    private func materializeLayer(for node: Node, request: HostRenderRequest) -> CALayer {
        if let existing = registry.layer(for: node.id) { return existing }

        let layer = CALayer()
        layer.masksToBounds = false
        registry.set(layer, for: node.id)
        createdLayerTotal += 1
        Log.on(
            .layer,
            "create",
            host: request.hostID,
            generation: request.generation,
            node: node.id
        )
        return layer
    }

    private func applyPresentation(of node: Node, to layer: CALayer) {
        applyVisualStyle(node.appearance, to: layer, theme: node.environment.theme)
        switch node.style.visual.overflow {
        case .visible:
            layer.masksToBounds = false
        case .hidden, .scroll:
            layer.masksToBounds = true
        }
        layer.opacity =
            transitionHiddenNodeIDs.contains(node.id) ? 0 : Float(node.style.visual.opacity)
        layer.zPosition = CGFloat(node.style.visual.zIndex)
        // Pivot contract (D17, defect #30): the layer keeps CALayer's default `anchorPoint`
        // `(0.5, 0.5)`, so the transform is applied around the frame center — the same pivot
        // `LayoutTransform.applying(_:in:)` uses. `position` above already follows `anchorPoint`.
        layer.setAffineTransform(cgAffineTransform(node.style.visual.transform))
    }

    /// Whether `node` is a wrapper the C30 experiment renders without a layer.
    private static func isLayoutOnlyWrapper(_ node: Node) -> Bool {
        node.isArrangementWrapper && node.appearance == VisualStyle()
            && node.style.visual == LayoutVisualProperties()
    }

    /// The layers `node`'s layer should hold, in order: its children's, descending through
    /// any layer-less wrapper (C30) so grandchildren keep their pre-order position.
    private func paintedDescendantLayers(of node: Node) -> [CALayer] {
        var layers: [CALayer] = []
        for child in node.subnodes {
            if let layer = registry.layer(for: child.id) {
                layers.append(layer)
            } else if skipsLayoutOnlyWrappers, Self.isLayoutOnlyWrapper(child) {
                layers.append(contentsOf: paintedDescendantLayers(of: child))
            }
        }
        return layers
    }

    private func orderOwnedChildren(of node: Node, in parentLayer: CALayer) {
        let desired = paintedDescendantLayers(of: node)
        guard desired.count > 1, let sublayers = parentLayer.sublayers else { return }

        let desiredSet = Set(desired.map(ObjectIdentifier.init))
        let ownedIndices = sublayers.indices.filter {
            desiredSet.contains(ObjectIdentifier(sublayers[$0]))
        }
        guard ownedIndices.count == desired.count else { return }

        let current = ownedIndices.map { sublayers[$0] }
        guard !zip(current, desired).allSatisfy({ $0 === $1 }) else { return }
        for (index, layer) in desired.enumerated() {
            parentLayer.insertSublayer(layer, at: UInt32(ownedIndices[index]))
        }
    }

    private func removeStaleLayers(
        except active: Set<NodeID>,
        request: HostRenderRequest,
        mountEpoch: UInt64
    ) {
        for identity in registry.identities.subtracting(active) {
            guard let layer = registry.remove(identity) else { continue }
            rasterLayers.removeValue(forKey: identity)
            if let backing = scrollBackings.removeValue(forKey: identity) {
                backing.removeContentLayer()
                backing.dispose()
                Log.on(.layer, "scroll-backing-removed", node: identity, "reason=stale")
            } else {
                layer.removeFromSuperlayer()
            }
            scrollContentLayers.removeValue(forKey: identity)
            scrollContentSizes.removeValue(forKey: identity)
            transitionHiddenNodeIDs.remove(identity)
            animator.forgetNode(identity, mountEpoch: mountEpoch)
            Log.on(
                .layer,
                "remove-stale",
                host: request.hostID,
                generation: request.generation,
                node: identity
            )
            onNodeRemoved?(identity)
        }
    }
}

private func cgAffineTransform(_ transform: LayoutTransform) -> CGAffineTransform {
    let cosine = cos(transform.rotationRadians)
    let sine = sin(transform.rotationRadians)
    return CGAffineTransform(
        a: transform.scaleX * cosine,
        b: transform.scaleX * sine,
        c: -transform.scaleY * sine,
        d: transform.scaleY * cosine,
        tx: transform.translationX,
        ty: transform.translationY
    )
}
