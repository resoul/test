import Foundation
import QuartzCore
import TrellisCore

/// Owns one mounted root and connects its layout commits to a host CALayer.
///
/// A root has at most one bridge owner at a time. A second bridge's `attach` is rejected without
/// changing the root, the first host, or either renderer. The weak owner table exists only for
/// that ownership check; `LayerRenderer` remains the sole NodeID-to-layer lookup.
///
/// Ownership: retains the mounted root, coordinator, and renderer; borrows `hostLayer` weakly.
/// Isolation: MainActor. Errors: invalid host inputs and already-mounted roots are rejected.
/// Cancellation: `detach()` disposes layout work, clears callbacks, and detaches owned layers.
@MainActor
public final class NodeHostBridge {
    private final class WeakOwner {
        weak var bridge: NodeHostBridge?

        init(_ bridge: NodeHostBridge) { self.bridge = bridge }
    }

    private static var nextHostID: UInt64 = 0
    private static var rootOwners: [NodeID: WeakOwner] = [:]

    /// Stable identity used to correlate this host's scheduler, commit, and layer logs.
    ///
    /// Ownership: returns a copied scalar. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let hostID: UInt64

    private weak var hostLayer: CALayer?
    // Not `private`: `root`/`renderer` are read from `Scroll/NodeHostBridge+Scroll.swift`
    // (module-internal access, same reasoning as the R07 scroll properties below).
    var root: Node?
    private var coordinator: RenderCoordinator?
    let renderer = LayerRenderer()
    private let debugOverlay = DebugOverlayRenderer()
    // Read by the scroll extension to republish offset-derived semantics against the latest
    // committed generation; it remains module-internal, not part of the bridge API.
    var lastCommittedRequest: HostRenderRequest?
    private var bindings: [ObjectIdentifier: any StateBindingRecord] = [:]
    var isSuspendedForBindings = false

    // MARK: - R07 scroll (ScrollCommandIssuing, NativeScrollBackingDelegate)
    // Not `private`: implemented in `Scroll/NodeHostBridge+Scroll.swift` (same module, module-
    // internal access), kept out of this already-large file for readability.

    /// Last-observed motion phase per committed `ScrollNode` with a materialized backing —
    /// `.idle` until the first `NativeScrollBackingDelegate` callback for that node.
    var scrollPhases: [NodeID: ScrollPhase] = [:]

    /// Publish-count per `ScrollNode`, bumped on every `publishScrollState(for:)` call — becomes
    /// `ScrollState.revision`.
    var scrollStateRevisions: [NodeID: UInt64] = [:]

    /// The pending completion for the most recently issued command per node, if it has not yet
    /// resolved — only this token can resolve `.completed` (§7).
    var pendingScrollCompletions:
        [NodeID: (
            token: ScrollCommandToken, completion: (@MainActor (ScrollCommandOutcome) -> Void)?
        )] =
            [:]

    var nextScrollCommandTokenID: UInt64 = 0

    // MARK: - R12a hosted containers (ContainerHost), `Scroll/NodeHostBridge+Containers.swift`

    /// Containers found in the committed tree, keyed by object identity, held weakly.
    var hostedContainers: [ObjectIdentifier: WeakHostedContainer] = [:]

    /// Offset shifts waiting for the next geometry commit, per scroll node, in request order.
    var pendingOffsetAdjustments: [NodeID: [PendingOffsetAdjustment]] = [:]

    /// Budget shared by every collection window of this host (P6.9); created on first use.
    var containerBudget: MaterializationBudget?

    // MARK: - M11 composite transition (D70-D74)

    /// The single active `TransitionSession` (D71) — backing storage for the public
    /// `transitionSession` property.
    private var transitionSessionStorage: TransitionSession?

    /// M11's session-geometry explicit-animation path (`docs/validation/
    /// m10-transition-contract.md` §3): parallel to `LayerAnimator`, not through it.
    private let transitionAnimator = TransitionAnimator()

    /// Per-role overlay layers for the active session — engine-private bookkeeping, not part
    /// of the public `TransitionSession` value (which carries identities, not `CALayer`s).
    private var transitionRoleVisuals: [Role: TransitionRoleVisual] = [:]

    /// The accessibility `childrenPolicy` the source/destination roots had before the active
    /// session began, restored when it ends (D73's AX exclusion).
    private var transitionSavedAccessibilityPolicies:
        (source: AccessibilityChildrenPolicy, destination: AccessibilityChildrenPolicy)?

    /// A `preparing` request waiting on destination measurement (delayed raster) — retried on
    /// every subsequent commit, never polled per frame.
    private var transitionPendingRequest: TransitionRequest?

    /// The host bounds the currently-armed motion's geometry was last built against (M13) — set
    /// at the end of every `buildTransitionVisuals` call, compared on every real commit
    /// (`reconcileTransitionGeometryIfNeeded`) to detect a host resize that lands mid-transition.
    /// `nil` while no session is active. D72's own table: "session завершается к выбранному
    /// логическому endpoint с новой раскладкой" — a resize retargets the already-decided
    /// direction/settle target under the new layout, it does not reopen or restart the session.
    private var transitionBuiltBounds: LayoutFrame?

    /// The duration `presentTransition(_:)` last requested — reused by `closeTransition()`,
    /// which has no `TransitionRequest` of its own.
    private var transitionDuration: Duration = .milliseconds(320)

    private var transitionNextToken: UInt64 = 1

    /// Which absolute endpoint the currently-armed interactive driver is heading toward while
    /// `.interactiveClosing` is live (M12) — needed because `.expand`'s two ways of entering a
    /// live gesture arm their explicit animations in opposite absolute directions: continuing an
    /// in-flight `.opening` keeps the already-armed source→destination targets (`progress`
    /// 0 = source/closed, 1 = destination/presented), while a fresh dismiss from `.presented`
    /// arms a new destination→source set (`progress` 0 = presented, 1 = closed). D72's own
    /// wording: "direction определяется знаком дельты входа, а не именем состояния" — this is
    /// the engine-private bookkeeping that lets `endTransitionGesture(velocity:)` convert the
    /// session's own `progress`/velocity into one consistent "how close to closed" scale
    /// regardless of which path armed it. `nil` whenever no gesture is live.
    private var transitionGestureOrigin: TransitionGestureOrigin?

    /// The gesture-decision thresholds (D72) the active session was opened with — carried the
    /// same way `transitionDuration` already is, since `beginTransitionGesture()` may need to
    /// arm a fresh manual driver (from `.presented`) with no `TransitionRequest` of its own to
    /// read a preset from.
    private var transitionGesturePreset: TransitionGesturePreset = .default

    /// The envelope `coordinator.onAnimationCommit` published for the commit about to land —
    /// D64's metadata published "immediately before the matching geometry/paint publication",
    /// consumed once by whichever of `onCommitGeometry`/`onPaintOnly` fires next for the same
    /// `HostRenderRequest` (M04). A request mismatch (defensive only — the coordinator always
    /// publishes both for the same commit) falls back to an empty, current-epoch envelope rather
    /// than reusing a stale one.
    private var pendingAnimationEnvelope: AnimationCommitEnvelope?

    /// Takes `pendingAnimationEnvelope` for `request` if it matches, otherwise an empty envelope
    /// at the bridge's current `mountEpoch` — `LayerRenderer` treats an empty-intents envelope
    /// exactly like `applyCommitted(root:on:request:)`/`applyAppearance(root:)` did before M04.
    private func consumeAnimationEnvelope(
        for request: HostRenderRequest
    ) -> AnimationCommitEnvelope {
        if let envelope = pendingAnimationEnvelope, envelope.request == request {
            pendingAnimationEnvelope = nil
            return envelope
        }
        return AnimationCommitEnvelope(request: request, intents: [], epoch: mountEpoch)
    }

    /// One `DisplayScheduler` per mount (T06), recreated in `attach` and disposed in
    /// `detachCurrentRoot` exactly like `coordinator` — so a previous mount's raster jobs can
    /// never commit into the mount that replaced it (D53/D58), the same reasoning that already
    /// applies to `RenderCoordinator`'s own per-mount lifecycle.
    private var displayScheduler: DisplayScheduler?

    /// The committed raster bitmap for `id`, if one exists and nothing has superseded it since
    /// (T06) — `nil` before the first display pass, for a non-`TextNode`, and after `detach()`.
    /// Not yet applied to any `CALayer` (T07's job).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func displayArtifact(for id: NodeID) -> DisplayArtifact? {
        displayScheduler?.artifact(for: id)
    }

    /// Counters of the current mount's display pipeline (T06) — zeros while nothing is attached.
    ///
    /// Ownership: returns a copied value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var displayStatistics: DisplayStatistics {
        displayScheduler?.statistics
            ?? DisplayStatistics(
                scheduled: 0,
                started: 0,
                completed: 0,
                cancelled: 0,
                dropped: 0,
                stale: 0
            )
    }

    /// M07's three independent readiness axes (D69) an export/screenshot tool must see all
    /// satisfied before it captures anything: `layoutReady` — no solve active, no flush queued,
    /// no host-state/tree change waiting for one; `displayReady` — no text raster job active or
    /// queued in this mount's `DisplayScheduler`; `animationReady` — no explicit D61 animation
    /// currently in flight in this mount's epoch. Each is read live off the owning subsystem,
    /// never inferred from elapsed time.
    ///
    /// Ownership: a copied value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct SceneReadiness: Sendable, Hashable {
        /// No layout solve active, no flush queued, and nothing waiting for one.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let layoutReady: Bool
        /// No text raster job active or queued in this mount's `DisplayScheduler`.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let displayReady: Bool
        /// No explicit D61 animation currently in flight in this mount's epoch.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let animationReady: Bool

        /// Creates a readiness value.
        ///
        /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation:
        /// not applicable.
        public init(layoutReady: Bool, displayReady: Bool, animationReady: Bool) {
            self.layoutReady = layoutReady
            self.displayReady = displayReady
            self.animationReady = animationReady
        }

        /// Whether every axis is satisfied — the condition an export/screenshot must wait for.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public var isReady: Bool { layoutReady && displayReady && animationReady }
    }

    /// Thrown by `waitUntilSceneReady(timeout:)` when its deadline passes before every
    /// `SceneReadiness` axis is satisfied (D69: "timeout — ошибка экспорта, не разрешение снять
    /// промежуточный кадр") — a caller that catches this must not proceed to capture a frame, a
    /// mid-transition state was the best this bridge could offer within the deadline.
    ///
    /// Ownership: the value is copied. Isolation: none. Errors: represents a readiness timeout
    /// only. Cancellation: not applicable — a cancelled wait throws `CancellationError` instead.
    public enum SceneReadinessError: Error, Sendable, Hashable {
        case timeout
    }

    /// A synchronous snapshot of `SceneReadiness` against this bridge's current state — no
    /// waiting, no polling. `nil` before the first `attach()` and after `detach()`: nothing is
    /// mounted to be ready or not.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var sceneReadiness: SceneReadiness? {
        guard let coordinator, let displayScheduler else { return nil }
        return SceneReadiness(
            layoutReady: !coordinator.hasPendingLayoutWork,
            displayReady: displayScheduler.activeJobCount == 0
                && displayScheduler.pendingJobCount == 0,
            // M11 (`docs/validation/m10-transition-contract.md` §3's second open item):
            // session geometry animates through `transitionAnimator`, a path parallel to
            // `LayerAnimator`, so its own D61 animation count never reflects a transition in
            // flight — a second, independent readiness source is required or this axis would
            // report ready mid-transition (D69 violated). Deliberately a parallel counter
            // rather than folding session activity into `LayerAnimator.active`: the two
            // collaborators keep separate ownership (D71: overlay layers are `LayerRenderer`-
            // owned, not `LayerAnimator`-tracked), and this composition is the one place their
            // two independent "is anything moving" answers are combined.
            animationReady: !renderer.hasActiveAnimations(mountEpoch: mountEpoch)
                && !isTransitionSessionInFlight
        )
    }

    /// Whether the active transition session (if any) is somewhere other than at rest
    /// (`.presented`, or no session) — the second readiness source `sceneReadiness` composes
    /// in alongside `LayerAnimator`'s own count (see that property's doc comment).
    private var isTransitionSessionInFlight: Bool {
        guard let state = transitionSessionStorage?.state else { return false }

        if case .presented = state { return false }
        return true
    }

    /// Polls `sceneReadiness` (D69) until every axis is satisfied or `timeout` elapses — a
    /// bounded cooperative loop (`Task.yield()`), never a fixed delay guessed to outlast
    /// whatever the scene happens to be doing: export/screenshot tooling needs the exact frame
    /// where layout, display and animation all agree nothing is left in flight, not a lucky
    /// moment sampled mid-transition. Throws `SceneReadinessError.timeout` rather than returning
    /// a possibly-still-mid-transition value — including when nothing is mounted for the whole
    /// wait, since there is then nothing to ever call ready.
    ///
    /// Ownership: touches no external state. Isolation: MainActor. Errors:
    /// `SceneReadinessError.timeout` if the deadline passes first. Cancellation: cooperative — a
    /// cancelled enclosing `Task` stops the poll and rethrows `CancellationError`.
    @discardableResult
    public func waitUntilSceneReady(timeout: Duration = .seconds(2)) async throws -> SceneReadiness
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if let readiness = sceneReadiness, readiness.isReady { return readiness }
            if clock.now >= deadline { throw SceneReadinessError.timeout }
            await Task.yield()
        }
    }

    /// Counts `attach` calls on this bridge (D21): every mount gets a new epoch, so a
    /// `HitTestSnapshot` or a pointer session from a previous mount can be told apart from
    /// the tree mounted now, even when the same root is attached again.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var mountEpoch: UInt64 = 0

    /// The committed tree as hit-testing sees it (H02a, D25): rebuilt at every geometry commit,
    /// right after the renderer positions its layers from the same frames, `subnodes` and
    /// `style.visual` — so it always describes what is on screen, never the live tree's
    /// not-yet-committed edits. `nil` before the first commit and after `detach()`.
    ///
    /// `internal(set)`, not `private(set)`: refreshed from `Scroll/NodeHostBridge+Scroll.swift`
    /// on every native-driven offset tick (`withScrollOffsets(_:)`), between geometry commits.
    ///
    /// Ownership: returns a value; retains no node. Isolation: MainActor. Errors: none.
    /// Cancellation: cleared by `detach()` and by replacing the root.
    public internal(set) var hitTestSnapshot: HitTestSnapshot?

    /// The committed tree as focus and assistive technology see it (A03, D35/D36): rebuilt
    /// from `hitTestSnapshot` and the live metadata at every geometry commit, and again —
    /// metadata-only, same frames — when only `Node.focus`/`Node.accessibility`/
    /// `ControlNode.isEnabled` changed (D41). Always published before any external commit
    /// callback runs. `nil` before the first commit and after `detach()`.
    ///
    /// Ownership: returns a value; retains no node. Isolation: MainActor. Errors: none.
    /// Cancellation: cleared by `detach()` and by replacing the root.
    public private(set) var semanticSnapshot: SemanticSnapshot?

    /// Called after every publish of `semanticSnapshot` — geometry commit or metadata-only —
    /// with the new value; not called when a metadata-only republish finds nothing changed
    /// (D47). Native accessibility adapters hang off this.
    ///
    /// Ownership: retained until replaced; must not retain the bridge strongly. Isolation:
    /// MainActor. Errors: none. Cancellation: survives `detach()`/`attach` like the overlay
    /// setting; the owner clears it by assigning `nil`.
    public var onSemanticsPublished: (@MainActor (SemanticSnapshot) -> Void)?

    /// The semantic tree assistive technology is shown (A06, D42): built from
    /// `semanticSnapshot` and the current focus scope (D40) after every publish and every
    /// scope change; `nil` before the first commit and after `detach()`.
    ///
    /// Ownership: returns a value; retains no node. Isolation: MainActor. Errors: none.
    /// Cancellation: cleared by `detach()` and by replacing the root.
    public private(set) var accessibilityTree: AccessibilityTree?

    /// Called with the new tree whenever `accessibilityTree` changes content — after a
    /// publish or a scope change that produced a different tree; an equal tree is not
    /// reported (D47). Native accessibility adapters hang off this.
    ///
    /// Ownership: retained until replaced; must not retain the bridge strongly. Isolation:
    /// MainActor. Errors: none. Cancellation: survives `detach()`; the owner clears it.
    public var onAccessibilityTreeChanged: (@MainActor (AccessibilityTree) -> Void)?

    /// Semantic publishes on this bridge across mounts (A03 acceptance): every geometry commit
    /// is one, every effective metadata-only republish is one.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var semanticPublishCount = 0

    /// The subset of `semanticPublishCount` that came from the metadata-only path — no
    /// layout snapshot, no solve.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var metadataOnlyPublishCount = 0

    /// Layout input snapshots the current mount's coordinator captured — a test hook for
    /// "zero new snapshots" assertions.
    var layoutSnapshotCount: Int { coordinator?.layoutSnapshotCount ?? 0 }

    private var semanticRevision: UInt64 = 0
    private let focusEngine = FocusEngine()

    private let pointerSessions = PointerSessions()

    /// The node with keyboard/remote focus on this host, or `nil` (A04, D39). Written only by
    /// the engine's completed transitions; `nil` before the first commit and after `detach()`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var focusedID: NodeID? { focusEngine.focusedID }

    /// The modal focus/accessibility scope, or `nil` (A05, D40).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var focusScopeID: NodeID? { focusEngine.scopeID }

    /// Diagnostic record of the last directional/sequential search.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var lastFocusTrace: FocusTrace? { focusEngine.lastTrace }

    /// Called once per completed focus transition on this host, after the `focusIn` event
    /// (D39). Survives `attach`/`detach`; the owner clears it.
    ///
    /// Ownership: retained until replaced; must not retain the bridge strongly. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public var onFocusChange: (@MainActor (FocusChange) -> Void)? {
        get { focusEngine.onFocusChange }
        set { focusEngine.onFocusChange = newValue }
    }

    /// Requests focus on `id`, or clears it with `nil` (A04, D37/D39) — against the last
    /// published snapshot and the live mounted tree. Refused without a root, while suspended,
    /// before the first commit, and while `skipsLayoutOnlyWrappers` is on.
    ///
    /// Ownership: nothing is retained past the call. Isolation: MainActor. Errors: reported
    /// as `FocusMoveResult`. Cancellation: `detach()` clears focus without events.
    @discardableResult
    public func focus(_ id: NodeID?, reason: FocusChangeReason = .request) -> FocusMoveResult {
        guard let root, !isSuspendedForBindings else { return .unavailable }

        return focusEngine.focus(id, root: root, reason: reason)
    }

    /// Moves focus in `direction` (A04, D38). `.unchanged` means the host should let the
    /// platform handle the key — the boundary of this tree is not a keyboard trap.
    ///
    /// Ownership: nothing is retained past the call. Isolation: MainActor. Errors: reported
    /// as `FocusMoveResult`. Cancellation: as `focus(_:reason:)`.
    @discardableResult
    public func moveFocus(_ direction: FocusDirection) -> FocusMoveResult {
        guard let root, !isSuspendedForBindings else { return .unavailable }

        if let target = revealFocusTarget(direction) {
            return focusEngine.focus(target, root: root, reason: .navigation)
        }
        return focusEngine.move(direction, root: root)
    }

    /// Feeds one normalized key event from a host adapter (A07/A08, D38/D43): navigation keys
    /// move focus, activation keys go to the focused control — see `FocusEngine.sendKey`.
    /// `.unhandled` tells the adapter to pass the key on to the platform. Refused without a
    /// root, while suspended, and while `skipsLayoutOnlyWrappers` is on.
    ///
    /// Ownership: `data` is copied; nothing is retained. Isolation: MainActor. Errors:
    /// reported in the outcome. Cancellation: `suspend()`/`detach()` cancel an open press
    /// cycle through the focus transition they cause.
    @discardableResult
    public func send(_ type: EventType, key data: KeyData) -> KeyOutcome {
        guard let root, !isSuspendedForBindings, !skipsLayoutOnlyWrappers else {
            Log.on(.event, "host-inactive", host: hostID, node: root?.id, "type=\(type)")
            return .unhandled
        }

        if type == .keyDown {
            let direction: FocusDirection?
            switch data.key {
            case .tab: direction = data.isShiftDown ? .previous : .next
            case .upArrow: direction = .up
            case .downArrow: direction = .down
            case .leftArrow: direction = .left
            case .rightArrow: direction = .right
            default: direction = nil
            }
            if let direction, let target = revealFocusTarget(direction) {
                _ = focusEngine.focus(target, root: root, reason: .navigation)
                return .handled
            }
        }
        return focusEngine.sendKey(data, type: type, root: root)
    }

    /// Cancels an open key press cycle on the focused control (A08) — the platform cancelled
    /// the press, no key-up follows, nothing activates.
    ///
    /// Ownership: nothing is retained. Isolation: MainActor. Errors: none. Cancellation: this
    /// is one.
    public func cancelKeyPress() {
        guard let root else { return }

        focusEngine.cancelKeyPress(root: root)
    }

    /// Performs an accessibility action on a published element (A07, D43): the identity must
    /// be a leaf of the current `accessibilityTree` (so inside the modal scope), still live
    /// under the mounted root, and — for `.activate` — enabled; then the node's
    /// `performAccessibilityAction` decides. `false` for anything stale, hidden, disabled or
    /// unhandled. Never moves keyboard focus (D45).
    ///
    /// Ownership: nothing is retained past the call. Isolation: MainActor. Errors: `false`.
    /// Cancellation: not applicable.
    @discardableResult
    public func performAccessibilityAction(_ action: AccessibilityAction, on id: NodeID) -> Bool {
        guard let root, !isSuspendedForBindings, let snapshot = semanticSnapshot,
            let element = accessibilityTree?.element(for: id), element.isElement,
            let node = snapshot.liveNode(for: id, under: root)
        else {
            Log.on(
                .event,
                "ax-action-rejected",
                host: hostID,
                node: id,
                "action=\(action) reason=stale"
            )
            return false
        }
        guard action != .activate || (element.isEnabled && node.isEnabledForSemantics) else {
            Log.on(
                .event,
                "ax-action-rejected",
                host: hostID,
                node: id,
                "action=\(action) reason=disabled"
            )
            return false
        }

        let handled = node.performAccessibilityAction(action)
        Log.on(.event, "ax-action", host: hostID, node: id, "action=\(action) handled=\(handled)")
        return handled
    }

    /// Opens a modal focus/accessibility scope at `id`, or closes it with `nil` (A05, D40):
    /// focus is confined to the subtree and the accessibility tree is built from it; closing
    /// restores the focus from before the scope opened when it is still a candidate.
    ///
    /// Ownership: the bridge stores identities only. Isolation: MainActor. Errors: an unknown
    /// id is ignored. Cancellation: `detach()` clears the scope.
    public func setFocusScope(_ id: NodeID?) {
        guard let root else { return }

        focusEngine.setScope(id, root: root)
        if rebuildAccessibilityTree(), let accessibilityTree, let semanticSnapshot {
            onSemanticsPublished?(semanticSnapshot)
            onAccessibilityTreeChanged?(accessibilityTree)
        }
    }

    /// Live pointer sessions on this host — 0 or 1 (single-touch, D30); 0 after `detach()`,
    /// `suspend()` and every `pointerUp`/`pointerCancel` (H10 asserts it after teardown).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var activePointerSessionCount: Int { pointerSessions.activeCount }

    /// Active per-session gesture arenas — an internal H10 ownership test hook.
    var activeGestureArenaCount: Int { pointerSessions.activeArenaCount }

    /// Feeds one normalized pointer event from a host adapter (H04, D16/D27/D30). `pointerDown`
    /// hit-tests the last commit and starts a session on that route; `move`/`up`/`cancel` follow
    /// the session of the same `pointerID` wherever the pointer is now. Refused (`.hostInactive`)
    /// without a root, while suspended, and while `skipsLayoutOnlyWrappers` is on — see
    /// `hitTest(_:)`.
    ///
    /// Ownership: `data` is copied; nothing is retained past the call. Isolation: MainActor.
    /// Errors: reported in the outcome. Cancellation: `detach()`, `suspend()` and replacing
    /// the root cancel every session with one `pointerCancel` along its route.
    @discardableResult
    public func send(_ type: EventType, _ data: PointerData) -> PointerOutcome {
        guard let root, !isSuspendedForBindings, !skipsLayoutOnlyWrappers else {
            Log.on(.event, "host-inactive", host: hostID, node: root?.id, "type=\(type)")
            return .hostInactive
        }

        return pointerSessions.send(type, data, snapshot: hitTestSnapshot, root: root)
    }

    /// The front-most committed node under a host point (H02b, D16) — `HitTestSnapshot.hitTest`
    /// on the last commit. `nil` before the first commit, after `detach()`, for a point outside
    /// the committed root, and while `skipsLayoutOnlyWrappers` is on: that experiment (C30,
    /// D15) flattens wrapper layers, so their children's `zPosition` is compared against the
    /// wrapper's siblings — a stacking order the snapshot does not describe (D32). The result is
    /// an identity from the commit; whether that node is still mounted is the dispatcher's
    /// question, not this one's.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func hitTest(_ point: LayoutPoint) -> NodeID? {
        guard !skipsLayoutOnlyWrappers else {
            Log.on(.host, "hit-test-unsupported", host: hostID, "reason=skipsLayoutOnlyWrappers")
            return nil
        }

        return hitTestSnapshot?.hitTest(point)
    }

    /// Whether the debug overlay (C25) is drawn on top of the rendered tree: every committed
    /// node's frame and `NodeID`, Arrangement-managed nodes in a second colour. Independent
    /// of the main render — toggling it never requests a layout or a commit; it redraws from
    /// the frames already committed and follows every later commit while enabled. Survives
    /// `attach`/`detach` as a setting; the layers themselves are removed on `detach()` and
    /// when set to `false`.
    ///
    /// Ownership: the bridge owns the overlay layers. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var isDebugOverlayEnabled = false {
        didSet {
            guard isDebugOverlayEnabled != oldValue else { return }

            if isDebugOverlayEnabled {
                redrawDebugOverlay()
            } else {
                debugOverlay.unmount()
            }
            Log.on(
                .host,
                "debug-overlay",
                host: hostID,
                node: root?.id,
                "enabled=\(isDebugOverlayEnabled)"
            )
        }
    }

    /// What the overlay's labels show (defect #11): the runtime `NodeID` by default, or the
    /// node's preorder position for reference screenshots. Redraws the overlay if it is
    /// enabled; never requests a layout or a commit.
    ///
    /// Ownership: forwarded to the overlay renderer. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var debugOverlayLabelStyle: DebugOverlayLabelStyle {
        get { debugOverlay.labelStyle }
        set {
            guard debugOverlay.labelStyle != newValue else { return }

            debugOverlay.labelStyle = newValue
            redrawDebugOverlay()
        }
    }

    /// C30 experiment switch, see `LayerRenderer.skipsLayoutOnlyWrappers`. Takes effect at
    /// the next commit; the switch itself requests none.
    ///
    /// Ownership: forwarded to the renderer. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var skipsLayoutOnlyWrappers: Bool {
        get { renderer.skipsLayoutOnlyWrappers }
        set { renderer.skipsLayoutOnlyWrappers = newValue }
    }

    /// The overlay renderer — a test hook for asserting what it mounted, never a render path.
    var debugOverlayRenderer: DebugOverlayRenderer { debugOverlay }

    /// M11 leak-detection test hooks — see `LayerRenderer.hasTransitionOverlay`/
    /// `transitionRasterLayerCount`'s own doc comments.
    var hasTransitionOverlayForTesting: Bool { renderer.hasTransitionOverlay }
    var transitionRasterLayerCountForTesting: Int { renderer.transitionRasterLayerCount }

    /// Test hook mirroring `transitionRasterLayerCountForTesting`: the raster layer for one
    /// specific role/side, if materialized (M14).
    func transitionRasterLayerForTesting(
        role: Role,
        side: TransitionEndpointSide
    ) -> CALayer? {
        renderer.transitionRasterLayer(role: role, side: side)
    }

    var committedCount: Int { coordinator?.committedCount ?? 0 }

    /// Counters of the current mount's render pipeline (C31); zeros while nothing is
    /// attached. Deterministic for a synchronous burst, so a caller can assert on them.
    ///
    /// Ownership: returns a copied value. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public var statistics: HostRenderStatistics {
        coordinator?.statistics
            ?? HostRenderStatistics(
                requested: 0,
                coalesced: 0,
                stale: 0,
                committed: 0,
                retries: 0,
                cancelled: 0
            )
    }

    /// Number of Trellis-owned `CALayer`s currently materialized for the attached tree (C31).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var materializedLayerCount: Int { renderer.layerCount }

    /// Layers created over this bridge's lifetime, across mounts (C26) — see
    /// `LayerRenderer.createdLayerTotal`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var createdLayerTotal: Int { renderer.createdLayerTotal }
    var mountedRoot: Node? { root }
    func layer(for identity: NodeID) -> CALayer? { renderer.layer(for: identity) }

    /// Creates an unattached bridge for a host layer.
    ///
    /// Ownership: borrows `hostLayer` and owns no root until `attach`. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(hostLayer: CALayer) {
        Self.nextHostID &+= 1
        hostID = Self.nextHostID
        self.hostLayer = hostLayer
    }

    /// Atomically attaches a root with its complete initial host state.
    ///
    /// `textRenderer`/`localeIdentifier` are `nil` by default (T09): a headless mount, or any
    /// existing call site that predates these parameters, keeps today's behavior exactly — the
    /// fallback `PortableTextMeasurer` (D51) and the `"en"` default locale. A real host passes
    /// its own `TextRenderer` (`CoreTextRenderer` from `TrellisRender`) and locale identifier so
    /// every `TextNode` in the subtree measures and, later, rasterizes with real typography.
    ///
    /// Ownership: retains `root` until replacement or `detach`. Isolation: MainActor. Errors:
    /// returns `false` when the host layer is unavailable, inputs are invalid, or another bridge
    /// owns the root. Cancellation: replacing an owned root detaches its scheduler and layers.
    @discardableResult
    public func attach(
        root newRoot: Node,
        bounds: LayoutFrame,
        scale: Double,
        safeAreaInsets: DirectionalEdgeInsets = DirectionalEdgeInsets(),
        layoutDirection: LayoutDirection = .leftToRight,
        textRenderer: (any TextRenderer)? = nil,
        localeIdentifier: String? = nil,
        reduceMotion: Bool? = nil,
        scrollBackingFactory: NativeScrollBackingFactory? = nil
    ) -> Bool {
        guard hostLayer != nil, bounds.width >= 0, bounds.height >= 0, scale.isFinite, scale > 0
        else {
            Log.on(.host, "attach-rejected", host: hostID, node: newRoot.id, "reason=invalid-input")
            return false
        }
        guard claim(newRoot) else { return false }

        detachCurrentRoot()
        Self.rootOwners[newRoot.id] = WeakOwner(self)

        root = newRoot
        mountEpoch &+= 1
        let epoch = mountEpoch
        // R07: the delegate is bound once here, not per backing — `renderer.scrollBackingFactory`
        // stores a plain `(NodeID) -> any NativeScrollBacking` closure with `self` already
        // captured, the same shape `textRenderer`/`localeIdentifier` already use (D51).
        if let scrollBackingFactory {
            renderer.scrollBackingFactory = { [weak self] nodeID in
                // `renderer` is a stored property of this bridge and outlives nothing past its
                // owner's deallocation, so `self` is only ever `nil` here in a defensive sense
                // — this closure cannot run once the bridge that stored it on `renderer` is
                // gone. `NullScrollBackingDelegate` exists purely to keep this total.
                scrollBackingFactory(nodeID, self ?? NullScrollBackingDelegate.shared)
            }
        } else {
            renderer.scrollBackingFactory = nil
        }
        newRoot.setSafeAreaInsets(safeAreaInsets)
        newRoot.setLayoutDirection(layoutDirection)
        if let textRenderer { newRoot.setTextRenderer(textRenderer) }
        if let localeIdentifier { newRoot.setLocaleIdentifier(localeIdentifier) }
        if let reduceMotion { newRoot.setReduceMotion(reduceMotion) }
        let coordinator = RenderCoordinator(hostID: hostID)
        self.coordinator = coordinator
        // D64: published immediately before the matching `onCommitGeometry`/`onPaintOnly` for
        // the same commit — stashed here so either can pass real `AnimationIntent`s through to
        // `LayerRenderer` (M04) instead of the request alone.
        coordinator.onAnimationCommit = { [weak self] envelope in
            self?.pendingAnimationEnvelope = envelope
        }
        coordinator.onCommitGeometry = { [weak self, weak newRoot] _, request in
            guard let self, let newRoot, self.root === newRoot, let hostLayer = self.hostLayer
            else { return }

            let envelope = self.consumeAnimationEnvelope(for: request)
            self.renderer.applyCommitted(root: newRoot, on: hostLayer, envelope: envelope)
            // R12a: in the same commit that shows the content change they compensate.
            self.applyPendingOffsetAdjustments(root: newRoot)
            self.lastCommittedRequest = request
            // Same instant, same inputs as the renderer above: nothing runs between the two
            // on the MainActor, so the snapshot and the layers agree (D25).
            self.hitTestSnapshot = HitTestSnapshot(
                root: newRoot,
                mountEpoch: epoch,
                bounds: request.bounds,
                scrollOffsets: self.renderer.currentScrollOffsets()
            )
            // Still the same synchronous stretch (D36): metadata is read now, against the
            // frames just committed, before `onPostCommit` or any user callback can mutate.
            self.publishSemantics(generation: request.generation, metadataOnly: false)
            self.redrawDebugOverlay()
            // R07: geometry (contentSize/viewportSize) may have changed for every committed
            // `ScrollNode`, independent of any native offset tick — republish so subscribers
            // never see a stale `ScrollState.contentSize` after a resize/insets change.
            self.publishScrollStates(root: newRoot)
        }
        coordinator.onPaintOnly = { [weak self, weak newRoot] request in
            guard let self, let newRoot, self.root === newRoot else { return }

            let envelope = self.consumeAnimationEnvelope(for: request)
            self.renderer.applyAppearance(root: newRoot, envelope: envelope)
        }
        coordinator.onSemanticsOnly = { [weak self, weak newRoot] request in
            guard let self, let newRoot, self.root === newRoot else { return }

            self.publishSemantics(generation: request.generation, metadataOnly: true)
        }
        let displayScheduler = DisplayScheduler()
        self.displayScheduler = displayScheduler
        // T10/D58: a node's outer layer is removed the moment it stops being active — dispose,
        // reparent-out-of-tree, or subtree removal — so this is also the earliest, and only,
        // signal `NodeHostBridge` has that its display queue entry (if any) must go with it.
        // `cancel(nodeID:)` is a no-op for a non-`TextNode` identity.
        renderer.onNodeRemoved = { [weak self] nodeID in
            self?.displayScheduler?.cancel(nodeID: nodeID)
        }
        // T07: the only consumer of a committed raster — pushes the bitmap straight to the
        // node's internal raster layer, with no geometry/solve/semantics work on this path
        // (D53's commit is display-only by construction; this closure never touches the outer
        // layer `renderer` also owns).
        displayScheduler.onArtifactCommitted = { [weak self] nodeID, artifact in
            self?.renderer.applyDisplayArtifact(artifact, for: nodeID)
        }
        coordinator.onPostCommit = { [weak self, weak newRoot] request in
            guard let self, let newRoot, self.root === newRoot else { return }

            self.scanForDisplayWork(root: newRoot, scale: request.scale)
            self.serveHostedContainers(root: newRoot, generation: request.generation)
            // M11: a `preparing` session whose destination was not yet measured retries here —
            // on real commits only, never a per-frame poll (checklist: "delayed raster").
            self.retryPendingTransitionIfNeeded()
            // M13: an active session's geometry is re-checked against the real committed tree
            // on every real commit — covers both a host resize mid-transition and a source that
            // disappeared while heading toward `.closed` (never polled per frame, same
            // discipline as the line above).
            self.reconcileTransitionGeometryIfNeeded()
        }
        coordinator.onDisplayOnly = { [weak self, weak newRoot] request in
            guard let self, let newRoot, self.root === newRoot else { return }

            self.scanForDisplayWork(root: newRoot, scale: request.scale)
            self.retryPendingTransitionIfNeeded()
            self.reconcileTransitionGeometryIfNeeded()
        }
        coordinator.mount(root: newRoot, animationEpoch: epoch)
        coordinator.invalidate(root: newRoot, bounds: bounds, scale: scale)
        // A fresh mount starts active, exactly like the fresh coordinator above: a `suspend()`
        // from a previous mount must not leave the bindings paused while the new coordinator
        // commits — the first frame would then show a tree without its bound state, and
        // nothing would deliver it until the host's next resume (defect #21).
        isSuspendedForBindings = false
        for binding in bindings.values {
            binding.start(paused: false)
        }
        Log.on(.host, "attach", host: hostID, node: newRoot.id, "scale=\(scale)")
        return true
    }

    /// Connects a `StateSubject` to a node-updating closure for the life of this bridge (C29,
    /// D14): while a root is attached and not suspended, every distinct value reaches
    /// `update` on the MainActor — a synchronous burst as one call with the last value; the
    /// current value is handed over on `attach` (and now, if already attached). `detach()`
    /// stops delivery without forgetting the binding; `suspend()` holds only the latest
    /// value for `resume()`. `update` is the model → node step: compare with what the node
    /// shows, mutate `style`/`appearance`/children, call `markArrangementDirty()` if the
    /// description changed — a synchronous burst of those mutations is one flush (C09).
    ///
    /// Ownership: the bridge retains the binding until `cancel()` (`detach()` only stops
    /// delivery); the closure must not retain the bridge. Isolation: MainActor. Errors: none.
    /// Cancellation: `StateBinding.cancel()`.
    @discardableResult
    public func bindState<Value: Sendable & Equatable>(
        _ subject: StateSubject<Value>,
        update: @escaping @MainActor (Value) -> Void
    ) -> StateBinding {
        let record = StateBindingRecordOf(subject: subject, hostID: hostID, update: update)
        bindings[ObjectIdentifier(record)] = record
        Log.on(.host, "state-bind", host: hostID, node: root?.id)
        if root != nil {
            record.start(paused: isSuspendedForBindings)
        }
        return StateBinding(record: record, owner: self)
    }

    /// Number of registered bindings — a test hook for ownership assertions.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var bindingCount: Int { bindings.count }

    func removeBinding(_ record: any StateBindingRecord) {
        bindings.removeValue(forKey: ObjectIdentifier(record))
    }

    /// Coalesces the latest host bounds and scale with pending tree invalidations.
    ///
    /// Ownership: borrows the mounted root. Isolation: MainActor. Errors: ignored without a
    /// mounted root or for invalid values. Cancellation: newer state supersedes older work.
    public func updateBounds(_ bounds: LayoutFrame, scale: Double) {
        guard let root else { return }
        coordinator?.invalidate(root: root, bounds: bounds, scale: scale)
        Log.on(.host, "bounds", host: hostID, node: root.id, "scale=\(scale)")
    }

    /// Updates inherited safe-area insets for the mounted tree.
    ///
    /// Ownership: the root's scope owns the copied insets. Isolation: MainActor. Errors: ignored
    /// without a mounted root. Cancellation: root invalidation coalesces the next layout pass.
    public func updateSafeArea(_ insets: DirectionalEdgeInsets) {
        guard let root else { return }
        root.setSafeAreaInsets(insets)
        Log.on(.host, "safe-area", host: hostID, node: root.id)
    }

    /// Updates inherited layout direction for the mounted tree.
    ///
    /// Ownership: the root's scope owns the copied direction. Isolation: MainActor. Errors:
    /// ignored without a mounted root. Cancellation: root invalidation coalesces the next pass.
    public func updateLayoutDirection(_ direction: LayoutDirection) {
        guard let root else { return }
        root.setLayoutDirection(direction)
        Log.on(.host, "direction", host: hostID, node: root.id, "value=\(direction)")
    }

    /// Updates the locale identifier for the mounted tree (T09) — every `TextNode` without its
    /// own override remeasures against it on the next flush, the same environment-revision path
    /// `updateLayoutDirection` already uses.
    ///
    /// Ownership: the root's scope owns the copied identifier. Isolation: MainActor. Errors:
    /// ignored without a mounted root. Cancellation: root invalidation coalesces the next pass.
    public func updateLocaleIdentifier(_ identifier: String) {
        guard let root else { return }
        root.setLocaleIdentifier(identifier)
        Log.on(.host, "locale", host: hostID, node: root.id, "value=\(identifier)")
    }

    /// Updates Reduce Motion for the mounted tree (D67). A future `Node.animate` intent resolves
    /// to `.none` at commit while this is `true` (`LayerRenderer.resolvedIntent`); turning it on
    /// while something is already mid-transition additionally finishes every currently active
    /// explicit animation immediately, at the target it already committed to — without a new
    /// commit or solve, per D67's own wording. Turning it off only affects future calls; nothing
    /// already snapped resumes moving.
    ///
    /// Ownership: the root's scope owns the copied value. Isolation: MainActor. Errors: ignored
    /// without a mounted root. Cancellation: not applicable.
    public func updateReduceMotion(_ isEnabled: Bool) {
        guard let root else { return }
        let wasEnabled = root.environment.reduceMotion
        root.setReduceMotion(isEnabled)
        if isEnabled, !wasEnabled {
            renderer.finishActiveAnimations(mountEpoch: mountEpoch)
            finishTransitionMotionInPlace()
        }
        Log.on(.host, "reduce-motion", host: hostID, node: root.id, "value=\(isEnabled)")
    }

    /// Suspends the mounted coordinator while retaining its root and latest host state.
    ///
    /// Active explicit animations are finished immediately at their committed target (D67:
    /// "активное движение заканчивается snap'ом к committed target") rather than left to keep
    /// running in the background while the host is not visible/active.
    ///
    /// Ownership: retains all current bridge resources. Isolation: MainActor. Errors: none.
    /// Cancellation: cancels in-flight layout work.
    public func suspend() {
        pointerSessions.cancelAll(reason: .hostSuspended, root: root)
        if let root { focusEngine.suspend(root: root) }
        isSuspendedForBindings = true
        for binding in bindings.values {
            binding.pause()
        }
        coordinator?.suspend()
        renderer.finishActiveAnimations(mountEpoch: mountEpoch)
        finishTransitionMotionInPlace()
        Log.on(.host, "suspend", host: hostID, node: root?.id)
    }

    /// Resumes the mounted coordinator, submitting the latest coalesced state if needed.
    ///
    /// Ownership: retains all current bridge resources. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func resume() {
        isSuspendedForBindings = false
        // Bindings first, synchronously: the flush the coordinator schedules on resume must
        // snapshot the tree with the latest state already applied (defect #19).
        for binding in bindings.values {
            binding.resume()
        }
        coordinator?.resume()
        if let root { focusEngine.resume(root: root) }
        Log.on(.host, "resume", host: hostID, node: root?.id)
    }

    /// Detaches the root, cancels work, and removes only layers owned by this bridge.
    ///
    /// Ownership: releases the mounted root and coordinator. Isolation: MainActor. Errors: none.
    /// Cancellation: cancels active layout work and clears root callbacks.
    public func detach() {
        detachCurrentRoot()
        Log.on(.host, "detach", host: hostID)
    }

    private func claim(_ candidate: Node) -> Bool {
        if let owner = Self.rootOwners[candidate.id]?.bridge, owner !== self {
            Log.on(
                .host,
                "attach-rejected",
                host: hostID,
                node: candidate.id,
                "reason=already-mounted owner=\(owner.hostID)"
            )
            return false
        }
        Self.rootOwners[candidate.id] = WeakOwner(self)
        return true
    }

    /// Ends every binding for good — the bridge is going away, not just its root.
    ///
    /// Ownership: releases all bindings. Isolation: MainActor. Errors: none. Cancellation:
    /// this cancels them.
    public func cancelAllBindings() {
        for binding in bindings.values {
            binding.cancel()
        }
        bindings.removeAll()
    }

    private func detachCurrentRoot() {
        guard let root else { return }

        // Before the tree and layers go: handlers on the route still see a live tree. Focus is
        // forgotten without events (D40) — the tree is not being interacted with, it is going.
        pointerSessions.cancelAll(reason: .hostDetached, root: root)
        focusEngine.cancelKeyPress(root: root)
        focusEngine.reset()
        // D72: "любое активное | detach()/replaceRoot() -> (нет сессии), немедленно" — drop
        // the session's own bookkeeping before `renderer.unmount()` below tears down its
        // layers, so a completion already queued on the run loop finds `token` invalidated.
        transitionAnimator.finishInPlace(
            on: collectTransitionLayers(),
            keyPaths: transitionAllKeyPaths
        )
        transitionSessionStorage = nil
        transitionRoleVisuals.removeAll()
        transitionSavedAccessibilityPolicies = nil
        transitionPendingRequest = nil
        transitionGestureOrigin = nil
        transitionBuiltBounds = nil
        detachHostedContainers()
        for binding in bindings.values {
            binding.stop()
        }
        // R07 §7/§9: nothing outlives `detach()` without a terminal callback — every pending
        // `ScrollCommandToken` completion resolves `.notAttached` before this method returns.
        for pending in pendingScrollCompletions.values {
            pending.completion?(.notAttached)
        }
        pendingScrollCompletions.removeAll()
        scrollPhases.removeAll()
        scrollStateRevisions.removeAll()
        if Self.rootOwners[root.id]?.bridge === self { Self.rootOwners[root.id] = nil }
        coordinator?.dispose()
        coordinator = nil
        displayScheduler?.dispose()
        displayScheduler = nil
        renderer.unmount()
        debugOverlay.unmount()
        lastCommittedRequest = nil
        pendingAnimationEnvelope = nil
        hitTestSnapshot = nil
        semanticSnapshot = nil
        accessibilityTree = nil
        self.root = nil
    }

    /// Rebuilds the accessibility tree from the current snapshot and scope; `true` when its
    /// content changed (D47) — the caller announces it after adapters saw the publish.
    private func rebuildAccessibilityTree() -> Bool {
        guard let semanticSnapshot else { return false }

        let tree = AccessibilityTree.build(from: semanticSnapshot, scope: focusEngine.scopeID)
        if let current = accessibilityTree, current.elements == tree.elements,
            current.scope == tree.scope, current.mountEpoch == tree.mountEpoch
        {
            return false
        }
        accessibilityTree = tree
        Log.on(
            .semantics,
            "tree",
            host: hostID,
            node: root?.id,
            "elements=\(tree.count) leaves=\(tree.readingOrder.count) scope=\(String(describing: tree.scope))"
        )
        return true
    }

    /// Builds and publishes the semantic snapshot from the current `hitTestSnapshot` and the
    /// live metadata (A03). A metadata-only republish whose content equals the published one
    /// is dropped — same value, zero work downstream (D41/D47); a geometry commit always
    /// publishes, since frames or topology changed.
    // Module-internal because the scroll extension republishes visible bounds after a native
    // offset tick, without requesting layout or raster work.
    func publishSemantics(generation: UInt64, metadataOnly: Bool) {
        guard let root, let geometry = hitTestSnapshot, !skipsLayoutOnlyWrappers else { return }

        let candidate = SemanticSnapshot(
            geometry: geometry,
            root: root,
            geometryGeneration: generation,
            revision: semanticRevision &+ 1,
            previous: semanticSnapshot
        )
        if metadataOnly, let current = semanticSnapshot, current.hasSameContent(as: candidate) {
            Log.on(.semantics, "no-op", host: hostID, generation: generation, node: root.id)
            return
        }
        semanticRevision = candidate.revision
        semanticSnapshot = candidate
        semanticPublishCount += 1
        if metadataOnly { metadataOnlyPublishCount += 1 }
        Log.on(
            .semantics,
            "published",
            host: hostID,
            generation: generation,
            node: root.id,
            "revision=\(candidate.revision) count=\(candidate.count) metadataOnly=\(metadataOnly)"
        )
        // The engine re-validates its focus against the new snapshot first (A04 §3.1): a
        // removed or disabled focused node falls back here, before adapters see the publish.
        focusEngine.apply(candidate, root: root)
        // D47 order: the whole published state — snapshot, then tree — is replaced first;
        // adapters rebuild their native objects on `onSemanticsPublished`, and only then is a
        // changed tree announced so their notifications describe what they already show.
        let treeChanged = rebuildAccessibilityTree()
        onSemanticsPublished?(candidate)
        if treeChanged, let accessibilityTree { onAccessibilityTreeChanged?(accessibilityTree) }
    }

    /// Walks the committed tree for every `TextNode` and schedules a raster pass for one whose
    /// `DisplayKey` (D52/D53) does not match what is already committed (T06). Tree-wide rather
    /// than tracking the specific node that changed, matching the existing paint-only/
    /// semantics-only convention (`LayerRenderer.applyAppearance(root:)`) — comparing revision
    /// numbers for every node is cheap, and `onPostCommit`/`onDisplayOnly` carry no origin node
    /// id to narrow the scan to.
    private func scanForDisplayWork(root: Node, scale: Double) {
        guard let displayScheduler else { return }

        func visit(_ node: Node) {
            if let textNode = node as? TextNode { scheduleDisplayWork(for: textNode, scale: scale) }
            for child in node.subnodes { visit(child) }
        }
        visit(root)
        Log.on(.commit, "display-scan", host: hostID, node: root.id)

        func scheduleDisplayWork(for node: TextNode, scale: Double) {
            guard let frame = node.calculatedFrame, frame.width > 0, frame.height > 0 else {
                return
            }

            let environment = node.environment
            let key = DisplayKey(
                contentRevision: node.geometryRevision,
                displayRevision: node.displayRevision,
                environmentRevision: node.environmentSnapshot.revision,
                size: MeasuredSize(width: frame.width, height: frame.height),
                scale: scale
            )
            let previousKey = displayScheduler.committedKey(for: node.id)
            guard previousKey != key else { return }

            // D65: a pure resize/rescale keeps the old bitmap on screen until the next one
            // lands; a text/style/theme/locale change must not — clear it now rather than let
            // stale content sit as if it were current while the new raster is in flight.
            if let previousKey, !previousKey.hasEqualContent(to: key) {
                renderer.clearDisplayContent(for: node.id)
            }

            let input = TextLayoutInput(
                document: node.document,
                style: node.textStyle,
                direction: environment.layoutDirection,
                localeIdentifier: environment.localeIdentifier,
                maxLines: node.maxLines,
                truncation: node.truncation
            )
            let resolvedColor =
                node.textStyle.color ?? resolveThemeColor(.text, in: environment.theme)
            let request = TextDisplayRequest(
                input: input,
                size: key.size,
                resolvedColor: resolvedColor,
                scale: scale
            )
            displayScheduler.schedule(nodeID: node.id, key: key, request: request)
        }
    }

    /// Draws the overlay from the last committed frames — a no-op until the first commit or
    /// while the overlay is disabled. Called after every commit and when the overlay is
    /// switched on, so switching it on shows the current tree without a new render pass.
    private func redrawDebugOverlay() {
        guard isDebugOverlayEnabled, let root, let hostLayer, let request = lastCommittedRequest
        else { return }
        debugOverlay.apply(root: root, on: hostLayer, request: request)
    }

    // MARK: - M11 composite transition (D70-D74)

    /// M11's single active composite card→page transition (D71), or `nil` when none is in
    /// progress — the one optional property D71 settles `TransitionSession` behind, the same
    /// "one modal scope, no stack" shape D40 already gives `focusScopeID` and this bridge's own
    /// single `mountEpoch`. See `presentTransition(_:)`/`closeTransition()`.
    ///
    /// Ownership: returns a value; `overlayLayer` remains owned by this bridge's renderer for
    /// the session's lifetime. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var transitionSession: TransitionSession? { transitionSessionStorage }

    /// One role's local source/destination mapping for a `TransitionRequest` (D70). Either side
    /// may be `nil` — a role missing on one side fades instead of flying, validated at prepare
    /// time (`presentTransition(_:)`), not per-frame.
    ///
    /// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct TransitionRoleMapping: Sendable {
        /// The role this mapping describes.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let role: Role
        /// The identity playing this role on the source side, or `nil`.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let source: NodeID?
        /// The identity playing this role on the destination side, or `nil`.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let destination: NodeID?
        /// This role's own sub-range of the session's unified progress (D70) — see
        /// `TransitionRoleEndpoints.interval`. `nil` (default) spans the full `0...1` range.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let interval: ClosedRange<Double>?

        /// Creates a role mapping.
        ///
        /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public init(
            role: Role,
            source: NodeID?,
            destination: NodeID?,
            interval: ClosedRange<Double>? = nil
        ) {
            self.role = role
            self.source = source
            self.destination = destination
            self.interval = interval
        }
    }

    /// A request to open, or retarget, a composite transition (D70–D72).
    ///
    /// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct TransitionRequest: Sendable {
        /// The source-side anchor identity, already part of the mounted tree.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let source: NodeID
        /// The destination-side root identity, already part of the mounted tree (D73).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let destinationRoot: NodeID
        /// Every role this transition carries, unique within this request (D70).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let roles: [TransitionRoleMapping]
        /// How long the automatic (non-gesture) motion takes.
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let duration: Duration

        /// The finish/cancel thresholds (D72) a live gesture on this session is decided against
        /// — `beginTransitionGesture()`/`endTransitionGesture(velocity:)` (M12).
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public let gesturePreset: TransitionGesturePreset

        /// Creates a transition request.
        ///
        /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public init(
            source: NodeID,
            destinationRoot: NodeID,
            roles: [TransitionRoleMapping],
            duration: Duration = .milliseconds(320),
            gesturePreset: TransitionGesturePreset = .default
        ) {
            self.source = source
            self.destinationRoot = destinationRoot
            self.roles = roles
            self.duration = duration
            self.gesturePreset = gesturePreset
        }
    }

    /// Opens `.expand`'s composite transition, or retargets the one already in flight for the
    /// same `(source, destinationRoot)` pair (D72's state table).
    ///
    /// A duplicate role, an unresolvable `source`, or an unresolvable `destinationRoot` is
    /// diagnosed and rejected before any layer is touched (D70/D71: validated at prepare time).
    /// A request for a *different* `(source, destinationRoot)` pair while a session is already
    /// active is rejected without touching the existing session (D72: "конкурирующий present...
    /// отклоняется... до завершения текущей сессии"). A repeat of the same pair while
    /// `.presented` is a no-op success; any other in-flight state retargets the same session —
    /// same overlay layer, same title rasters, a fresh token (D72/D66: continues from the live
    /// presentation value, never restarts).
    ///
    /// Ownership: retains nothing past the call beyond the session itself. Isolation:
    /// MainActor. Errors: `false` for every rejection above; the state is otherwise unchanged.
    /// Cancellation: superseded by a later `presentTransition`/`closeTransition`/`detach()`/
    /// `suspend()` call, which each retarget or finish this session in place.
    @discardableResult
    public func presentTransition(_ request: TransitionRequest) -> Bool {
        guard let root, let hostLayer else { return false }

        let roleNames = request.roles.map(\.role)
        guard Set(roleNames).count == roleNames.count else {
            Log.on(.host, "transition-rejected", host: hostID, "reason=duplicate-role")
            return false
        }
        guard findTransitionNode(request.source, in: root) != nil else {
            Log.on(.host, "transition-rejected", host: hostID, "reason=missing-source")
            return false
        }
        guard findTransitionNode(request.destinationRoot, in: root) != nil else {
            Log.on(.host, "transition-rejected", host: hostID, "reason=missing-destination-root")
            return false
        }

        if let current = transitionSessionStorage {
            guard current.sourceNodeID == request.source,
                current.destinationRootID == request.destinationRoot
            else {
                Log.on(.host, "transition-rejected", host: hostID, "reason=competing-session")
                return false
            }

            if case .presented = current.state { return true }

            var retargeted = current
            retargeted.token = transitionNextToken
            transitionNextToken &+= 1
            transitionSessionStorage = retargeted
            transitionDuration = request.duration
            transitionGesturePreset = request.gesturePreset
            attemptPrepareTransition(request: request)
            return true
        }

        let overlay = renderer.beginTransitionOverlay(on: hostLayer)
        captureAndHideDestinationAccessibility(request: request, root: root)
        transitionDuration = request.duration
        transitionGesturePreset = request.gesturePreset
        transitionSessionStorage = TransitionSession(
            sourceNodeID: request.source,
            destinationRootID: request.destinationRoot,
            roles: [:],
            overlayLayer: overlay,
            state: .preparing,
            progress: 0,
            token: transitionNextToken
        )
        transitionNextToken &+= 1
        attemptPrepareTransition(request: request)
        Log.on(.host, "transition-present", host: hostID, node: request.source)
        return true
    }

    /// Closes the active `.expand` session by button (non-interactive) — valid only from
    /// `.presented` (D72's state table); any other state is a diagnosed no-op, not a silent
    /// one, since M11 does not wire the gesture-driven paths that would make other states
    /// reachable.
    ///
    /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false` when no
    /// session is `.presented`. Cancellation: superseded by `detach()`/`suspend()`, which finish
    /// the resulting settle in place immediately.
    @discardableResult
    public func closeTransition() -> Bool {
        guard let hostLayer, let session = transitionSessionStorage, case .presented = session.state
        else {
            Log.on(.host, "transition-close-rejected", host: hostID)
            return false
        }

        let overlay = renderer.beginTransitionOverlay(on: hostLayer)
        transitionSessionStorage = TransitionSession(
            sourceNodeID: session.sourceNodeID,
            destinationRootID: session.destinationRootID,
            roles: session.roles,
            overlayLayer: overlay,
            state: session.state,
            progress: session.progress,
            token: transitionNextToken
        )
        transitionNextToken &+= 1
        buildTransitionVisuals(direction: .closing)
        Log.on(.host, "transition-close", host: hostID)
        return true
    }

    // MARK: - M12 gesture-driven progress (D72/D73)

    /// Begins live gesture control of the active `.expand` session — D73's "жест принимается
    /// через неподвижную host-overlay область": the caller (`TrellisUIKit`'s/`TrellisAppKit`'s
    /// gesture wiring) reports only that a gesture began on its own fixed hit-test region; this
    /// bridge never reads a moving presentation layer as gesture input.
    ///
    /// Valid from `.presented` (a fresh dismiss gesture arms a brand-new destination→source
    /// motion, parked at `progress = 0`) or from `.opening` (a gesture grabs the in-flight
    /// automatic open in place — D72: "жест начался до завершения открытия... progress
    /// продолжает расти от текущего, не сбрасывается" — `progress` keeps the value the automatic
    /// motion had already reached, not `0`). Calling this again while already
    /// `.interactiveClosing` is a same-session no-op (D72: "не создаёт вторую копию слоёв") —
    /// no new overlay, no new token. Any other state (`.preparing`, `.settling`, no session) is a
    /// diagnosed rejection.
    ///
    /// Ownership: retains nothing past the call beyond the session itself. Isolation:
    /// MainActor. Errors: `false` for every rejection above; the state is otherwise unchanged.
    /// Cancellation: superseded by `detach()`/`suspend()`, which finish the session in place
    /// immediately, or by `endTransitionGesture(velocity:)`/
    /// `cancelTransitionGestureSystemInterrupted()`, which each settle it.
    @discardableResult
    public func beginTransitionGesture() -> Bool {
        // R09: a native scroll gesture/deceleration already owns movement. Never arm the
        // transition driver alongside it; a platform recognizer that began simultaneously is
        // refused before either transition layer or scroll offset can be changed by two owners.
        guard !scrollPhases.values.contains(where: { $0 == .dragging || $0 == .decelerating })
        else {
            Log.on(.host, "transition-gesture-begin-rejected", host: hostID, "reason=scroll-owner")
            return false
        }
        guard let session = transitionSessionStorage else {
            Log.on(.host, "transition-gesture-begin-rejected", host: hostID, "reason=no-session")
            return false
        }

        switch session.state {
        case .interactiveClosing:
            return true
        case .presented:
            guard let hostLayer else { return false }
            let overlay = renderer.beginTransitionOverlay(on: hostLayer)
            transitionSessionStorage = TransitionSession(
                sourceNodeID: session.sourceNodeID,
                destinationRootID: session.destinationRootID,
                roles: session.roles,
                overlayLayer: overlay,
                state: session.state,
                progress: session.progress,
                token: transitionNextToken
            )
            transitionNextToken &+= 1
            transitionGestureOrigin = .closingFromPresented
            buildTransitionVisuals(
                direction: .closing,
                mode: .manual,
                settleState: .interactiveClosing
            )
            Log.on(.host, "transition-gesture-begin", host: hostID, "origin=presented")
            return true
        case .opening:
            guard let progress = transitionAnimator.freezeForGesture(token: session.token) else {
                Log.on(
                    .host,
                    "transition-gesture-begin-rejected",
                    host: hostID,
                    "reason=not-in-flight"
                )
                return false
            }
            var updated = session
            updated.state = .interactiveClosing
            updated.progress = progress
            transitionSessionStorage = updated
            transitionGestureOrigin = .continuingOpen
            Log.on(
                .host,
                "transition-gesture-begin",
                host: hostID,
                "origin=opening progress=\(progress)"
            )
            return true
        case .preparing, .settling(_):
            Log.on(.host, "transition-gesture-begin-rejected", host: hostID, "reason=invalid-state")
            return false
        }
    }

    /// Begins a transition gesture after resolving the initial drag against nested scroll
    /// ancestors. A downward drag closes a presented transition only when no eligible scroll
    /// ancestor can consume its corresponding content movement; the native scroll recognizer
    /// therefore remains the sole owner anywhere it can move. Coordinates are in host space.
    ///
    /// Ownership: values only; no gesture data is retained. Isolation: MainActor. Errors:
    /// `false` when the transition is unavailable, the close direction is not downward, or a
    /// scroll ancestor owns the initial movement. Cancellation: normal gesture end/cancel
    /// methods settle any accepted transition gesture.
    @discardableResult
    public func beginTransitionGesture(
        at point: LayoutPoint,
        initialDelta: LayoutPoint
    ) -> Bool {
        guard let session = transitionSessionStorage else { return false }
        guard case .presented = session.state else { return beginTransitionGesture() }
        guard initialDelta.y > 0, initialDelta.y > abs(initialDelta.x),
            let root, let geometry = hitTestSnapshot,
            let hit = geometry.hitTest(point), let route = geometry.route(to: hit)
        else {
            Log.on(.host, "transition-gesture-begin-rejected", host: hostID, "reason=direction")
            return false
        }

        let candidates = route.reversed().compactMap {
            identity -> ScrollGestureArbiter.Candidate? in
            guard let node = geometry.liveNode(for: identity, under: root) as? ScrollNode,
                node.configuration.userInteractionEnabled,
                let state = currentScrollState(for: node)
            else { return nil }
            return ScrollGestureArbiter.Candidate(
                id: identity,
                axis: node.configuration.axis,
                state: state
            )
        }
        let arbiter = ScrollGestureArbiter()
        arbiter.begin()
        // Finger motion and content offset run in opposite directions.
        let contentDelta = LayoutPoint(x: -initialDelta.x, y: -initialDelta.y)
        guard
            arbiter.decision(for: contentDelta, candidates: candidates, momentum: false).owner
                == nil
        else {
            Log.on(.host, "transition-gesture-begin-rejected", host: hostID, "reason=scroll-owner")
            return false
        }
        return beginTransitionGesture()
    }

    /// Moves the live gesture's progress by `deltaProgress` — a fraction of `0...1`, positive or
    /// negative, accumulated onto the session's current `progress` and clamped back into
    /// `0...1` (D72: reversal mid-gesture is the same driver scrubbed the other way, never a
    /// rearm — "тот же progress driver, direction inverted"). A no-op outside
    /// `.interactiveClosing`.
    ///
    /// Ownership: touches only this session's already-armed layers. Isolation: MainActor.
    /// Errors: none — an out-of-state call is silently ignored, matching a gesture recognizer
    /// that can deliver a stray `.changed` after `.ended` fired for a different reason.
    /// Cancellation: not applicable — each call fully determines the resulting progress.
    public func updateTransitionGesture(deltaProgress: Double) {
        guard var session = transitionSessionStorage, case .interactiveClosing = session.state
        else { return }

        let updatedProgress = max(0, min(1, session.progress + deltaProgress))
        transitionAnimator.scrub(updatedProgress)
        session.progress = updatedProgress
        transitionSessionStorage = session
    }

    /// Ends the live gesture, deciding the settle target from `session.progress` and `velocity`
    /// (progress fraction per second, same units `deltaProgress` accumulates) against
    /// `preset` (D72: "Решение finish/cancel учитывает progress и скорость в согласованных
    /// единицах; пороги — часть preset"). Both are first converted to "how close to closed" —
    /// `session.progress` directly if the gesture started from `.presented`, `1 - progress` if
    /// it grabbed an in-flight `.opening` (`transitionGestureOrigin`) — so one comparison covers
    /// both entry paths. At or past either threshold settles to `.closed`; otherwise to
    /// `.presented`. See `TransitionGesturePreset`'s doc comment for why this description avoids
    /// the state table's own "finish"/"cancel" words.
    ///
    /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false` outside
    /// `.interactiveClosing`; the state is otherwise unchanged. Cancellation: superseded by
    /// `detach()`/`suspend()`, which finish the resulting settle in place immediately.
    @discardableResult
    public func endTransitionGesture(
        velocity: Double,
        preset: TransitionGesturePreset? = nil
    ) -> Bool {
        guard let session = transitionSessionStorage, case .interactiveClosing = session.state,
            let origin = transitionGestureOrigin
        else {
            Log.on(.host, "transition-gesture-end-rejected", host: hostID)
            return false
        }

        let effectivePreset = preset ?? transitionGesturePreset
        let closingProgress =
            origin == .closingFromPresented ? session.progress : 1 - session.progress
        let closingVelocity = origin == .closingFromPresented ? velocity : -velocity
        let target: TransitionSettleTarget =
            (closingProgress >= effectivePreset.progressThreshold
                || closingVelocity >= effectivePreset.velocityThreshold)
            ? .closed : .presented
        settleTransitionGesture(toward: target)
        Log.on(.host, "transition-gesture-end", host: hostID, "target=\(target)")
        return true
    }

    /// Resolves a gesture the platform reports as system-cancelled (e.g. `UIGestureRecognizer.
    /// state == .cancelled` on iOS, or a right-click/escape interrupting an
    /// `NSPanGestureRecognizer` on macOS) — D72 requires this event resolve deterministically,
    /// not leave the session stuck mid-gesture. Not itself part of D72's finish/cancel decision
    /// table (that table covers a normal release only): this always settles back to
    /// `.presented`, on the reasoning that an interruption is not a confirmed dismissal intent —
    /// a documented M12 implementation choice for an event D72's own table does not enumerate,
    /// not a reinterpretation of the table's decided rows.
    ///
    /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false` outside
    /// `.interactiveClosing`; the state is otherwise unchanged. Cancellation: this call is one.
    @discardableResult
    public func cancelTransitionGestureSystemInterrupted() -> Bool {
        guard case .interactiveClosing = transitionSessionStorage?.state else { return false }

        settleTransitionGesture(toward: .presented)
        Log.on(.host, "transition-gesture-system-cancelled", host: hostID)
        return true
    }

    /// Common tail of `endTransitionGesture(velocity:)`/
    /// `cancelTransitionGestureSystemInterrupted()`: leaves manual mode and rebuilds toward
    /// `target`, always through `.automatic` playback with an explicit `settleState` (D72's
    /// table always lands `.interactiveClosing` release in `settling(target:)`, never bare
    /// `.opening`/`.settling(.closed)`). `buildTransitionVisuals` recomputes rects from the real
    /// (unmoved) node layers and `TransitionAnimator.play` retargets from each overlay layer's
    /// current (frozen) presentation value — the same D66 retarget-from-presentation this file
    /// already relies on for every other retarget, so this needs no separate continuity
    /// mechanism of its own.
    private func settleTransitionGesture(toward target: TransitionSettleTarget) {
        transitionAnimator.endManual()
        transitionGestureOrigin = nil
        buildTransitionVisuals(
            direction: target == .presented ? .opening : .closing,
            mode: .automatic,
            settleState: .settling(target: target)
        )
    }

    /// Hides or reveals `id`'s real layer for the duration of a composite transition, through
    /// `LayerRenderer.setTransitionHidden(_:hidden:)` — never a direct `CALayer.opacity` write
    /// (M13 fix: a raw write was silently undone by the next ordinary commit, see that method's
    /// doc comment and `docs/defects.md`). A no-op if `id` no longer resolves in `root` — the
    /// node, and with it its layer, is already gone.
    private func setTransitionHidden(_ id: NodeID, hidden: Bool, root: Node) {
        guard let node = findTransitionNode(id, in: root) else { return }
        renderer.setTransitionHidden(node, hidden: hidden)
    }

    private func findTransitionNode(_ id: NodeID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.subnodes {
            if let found = findTransitionNode(id, in: child) { return found }
        }
        return nil
    }

    /// A node's committed frame converted into host-layer coordinates via `CALayer.convert(_:
    /// from:)` — real coordinate translation through the layer tree's own transforms, not
    /// reimplemented arithmetic (checklist item 1's "координатная трансляция в пространство
    /// одного хоста").
    private func transitionHostRect(of node: Node) -> CGRect? {
        guard let hostLayer, node.calculatedFrame != nil, let layer = renderer.layer(for: node.id)
        else { return nil }
        return hostLayer.convert(layer.bounds, from: layer)
    }

    private func captureAndHideDestinationAccessibility(
        request: TransitionRequest,
        root: Node
    ) {
        let sourcePolicy =
            findTransitionNode(request.source, in: root)?.accessibility.childrenPolicy ?? .contain
        let destinationPolicy =
            findTransitionNode(request.destinationRoot, in: root)?.accessibility.childrenPolicy
            ?? .contain
        transitionSavedAccessibilityPolicies = (
            source: sourcePolicy, destination: destinationPolicy
        )
        // D73: "Публикуется одно логическое представление страницы без копий текста" — the
        // destination subtree is excluded from AX from the moment it is requested, before any
        // overlay frame exists, so preparing/opening never exposes two copies.
        findTransitionNode(request.destinationRoot, in: root)?.accessibility.childrenPolicy = .hide
    }

    private func restoreTransitionAccessibility(root: Node) {
        guard let session = transitionSessionStorage,
            let saved = transitionSavedAccessibilityPolicies
        else { return }
        findTransitionNode(session.sourceNodeID, in: root)?.accessibility.childrenPolicy =
            saved.source
        findTransitionNode(session.destinationRootID, in: root)?.accessibility.childrenPolicy =
            saved.destination
    }

    /// Attempts to move a `.preparing` session forward: rejects if `source` disappeared since
    /// the request, resolves every role, and either arms `.opening` (every present role fully
    /// measured) or stores `request` in `transitionPendingRequest` for the next commit to retry
    /// (checklist: "delayed raster").
    private func attemptPrepareTransition(request: TransitionRequest) {
        guard let root, transitionSessionStorage != nil else { return }
        guard findTransitionNode(request.source, in: root) != nil else {
            cancelTransition(reason: "source-removed")
            return
        }

        var resolvedRoles: [Role: TransitionRoleEndpoints] = [:]
        var allReady = true
        for mapping in request.roles {
            let sourceReady =
                mapping.source.map { findTransitionNode($0, in: root)?.calculatedFrame != nil }
                ?? true
            let destinationReady =
                mapping.destination.map { findTransitionNode($0, in: root)?.calculatedFrame != nil }
                ?? true
            if !sourceReady || !destinationReady { allReady = false }
            resolvedRoles[mapping.role] = TransitionRoleEndpoints(
                source: mapping.source,
                destination: mapping.destination,
                interval: mapping.interval
            )
        }
        transitionSessionStorage?.roles = resolvedRoles

        guard allReady else {
            transitionPendingRequest = request
            Log.on(.host, "transition-pending", host: hostID, "reason=not-measured")
            return
        }
        transitionPendingRequest = nil
        buildTransitionVisuals(direction: .opening)
    }

    private func retryPendingTransitionIfNeeded() {
        guard let request = transitionPendingRequest else { return }
        attemptPrepareTransition(request: request)
    }

    /// M13: re-checks an active session's geometry against the real committed tree on every
    /// real commit — the checklist's two lifecycle gaps M11/M12 left open:
    ///
    /// - **Host resize mid-transition** (D72's table, `presented`/`settling` rows; extended here
    ///   to `opening`/`interactiveClosing` on the same reasoning — any state with overlay
    ///   geometry armed against now-stale rects needs the same retarget): the session does not
    ///   reopen or restart, it rebuilds the same direction/settle target from the freshly
    ///   committed frames.
    /// - **Source disappears while heading toward `.closed`** (D72: "closing использует fade
    ///   вместо полёта в устаревший прямоугольник") — `buildTransitionVisuals` already falls
    ///   back to a plain opacity fade when one side of a role does not resolve (the same branch
    ///   `attemptPrepareTransition`'s `preparing`-phase check already relies on); this reuses
    ///   that existing behavior for the closing phase, which M11 explicitly left uncovered.
    ///
    /// A retarget always mints a fresh session token (D66's stale-completion rule) exactly like
    /// every other retarget in this file, so a completion already queued for the previous build
    /// is ignored rather than double-firing `completeTransitionMotion`.
    private func reconcileTransitionGeometryIfNeeded() {
        guard let session = transitionSessionStorage, let root,
            let currentBounds = lastCommittedRequest?.bounds
        else { return }

        let boundsChanged = transitionBuiltBounds != currentBounds
        let sourceNode = findTransitionNode(session.sourceNodeID, in: root)
        let sourceMissing = sourceNode == nil || sourceNode?.calculatedFrame == nil

        switch session.state {
        case .opening:
            guard boundsChanged else { return }
            rebuildTransitionForReconcile(
                direction: .opening,
                mode: .automatic,
                settleState: nil,
                preserveProgress: false
            )
        case .interactiveClosing:
            let headingToClosed = transitionGestureOrigin == .closingFromPresented
            guard boundsChanged || (headingToClosed && sourceMissing) else { return }
            let progress = session.progress
            if headingToClosed, sourceMissing { clearStaleTransitionGeometryAnimations() }
            rebuildTransitionForReconcile(
                direction: headingToClosed ? .closing : .opening,
                mode: .manual,
                settleState: .interactiveClosing,
                preserveProgress: true
            )
            transitionAnimator.scrub(progress)
        case let .settling(target):
            let headingToClosed = target == .closed
            guard boundsChanged || (headingToClosed && sourceMissing) else { return }

            if headingToClosed, sourceMissing { clearStaleTransitionGeometryAnimations() }
            rebuildTransitionForReconcile(
                direction: headingToClosed ? .closing : .opening,
                mode: .automatic,
                settleState: .settling(target: target),
                preserveProgress: false
            )
        case .preparing, .presented:
            break
        }
    }

    /// Strips a previously-armed geometry retarget (position/size/corner-radius) from every
    /// layer this session currently has — the fade branch above is about to rebuild with an
    /// opacity-only target for the affected role(s); without this, the geometry keyPaths' old
    /// explicit animations (`isRemovedOnCompletion = false`) would keep overriding the layer's
    /// presentation value at whatever position they were last parked, instead of the fresh
    /// "already at the destination's own rect" model value `buildTransitionVisuals` is about to
    /// write. Never touches `opacity` — a role's own title crossfade (or an unrelated role's
    /// still-valid geometry) is untouched.
    private func clearStaleTransitionGeometryAnimations() {
        transitionAnimator.clearStaleAnimations(
            keyPaths: [
                "position.x", "position.y", "bounds.size.width", "bounds.size.height",
                "cornerRadius",
            ],
            on: collectTransitionLayers()
        )
    }

    /// Common retarget tail for `reconcileTransitionGeometryIfNeeded()`: mints a fresh token,
    /// same as every other in-flight retarget in this file, then rebuilds from the currently
    /// committed tree.
    private func rebuildTransitionForReconcile(
        direction: TransitionDirection,
        mode: TransitionBuildMode,
        settleState: TransitionSessionState?,
        preserveProgress: Bool
    ) {
        guard var session = transitionSessionStorage else { return }
        session.token = transitionNextToken
        transitionNextToken &+= 1
        transitionSessionStorage = session
        buildTransitionVisuals(
            direction: direction,
            mode: mode,
            settleState: settleState,
            resetProgressOnManual: !preserveProgress
        )
    }

    /// Builds (or rebuilds, on retarget) every role's overlay visual for `direction` and arms
    /// `transitionAnimator` over all of them at once (D70: one shared progress driver). The
    /// first non-text role found drives the session's own `overlayLayer` directly — the
    /// `.expand` shape D74 names (`hero`) — so a common single-geometry-role request needs no
    /// extra child layer; any further geometry role gets its own child layer via
    /// `LayerRenderer.materializeTransitionRasterLayer`. Text roles nest under that anchor layer
    /// as an inset fixed at prepare time (D71: no per-frame remeasure — only `opacity`
    /// crossfades, the box itself rides along with the anchor's own animating geometry for
    /// free, exactly the shape `docs/validation/m10-transition-contract.md` §2 proved).
    ///
    /// `mode` (M12) chooses which `TransitionAnimator` entry point commits the built targets:
    /// `.automatic` plays for real, as M11 always did, and drives the resulting state from
    /// `direction` unless `settleState` overrides it; `.manual` parks the motion for a gesture
    /// to scrub (`beginTransitionGesture()`'s fresh-dismiss-from-`.presented` path — the only
    /// caller that needs a brand-new build in manual mode, since continuing an in-flight
    /// `.opening` freezes the already-armed targets in place instead of rebuilding). `settleState`
    /// (M12) overrides the state `direction` alone would imply — needed because settling a
    /// gesture decision always lands on `.settling(target:)` (D72's table), never bare
    /// `.opening`/`.settling(.closed)`, regardless of which `direction` the automatic playback
    /// that reaches it happens to run in.
    private func buildTransitionVisuals(
        direction: TransitionDirection,
        mode: TransitionBuildMode = .automatic,
        settleState: TransitionSessionState? = nil,
        resetProgressOnManual: Bool = true
    ) {
        guard let root, let session = transitionSessionStorage else { return }
        let scale = lastCommittedRequest?.scale ?? 1
        let duration = transitionDurationSeconds
        let overlay = session.overlayLayer
        var targets: [TransitionAnimator.Target] = []
        var anchorLayer = overlay
        var usedAnchor = false
        transitionRoleVisuals.removeAll()

        let roleOrder = session.roles.keys.sorted { $0.rawValue < $1.rawValue }

        for role in roleOrder {
            guard let endpoints = session.roles[role] else { continue }
            let sourceNode = endpoints.source.flatMap { findTransitionNode($0, in: root) }
            let destinationNode = endpoints.destination.flatMap { findTransitionNode($0, in: root) }
            let fromNode = direction == .opening ? sourceNode : destinationNode
            let toNode = direction == .opening ? destinationNode : sourceNode
            guard !(fromNode is TextNode), !(toNode is TextNode) else { continue }
            guard fromNode != nil || toNode != nil else { continue }

            let begin = endpoints.interval?.lowerBound ?? 0
            let end = endpoints.interval?.upperBound ?? 1

            let layer: CALayer
            if !usedAnchor {
                layer = overlay
                usedAnchor = true
            } else {
                layer = renderer.materializeTransitionRasterLayer(
                    role: role,
                    side: .source,
                    parent: overlay
                )
            }
            layer.anchorPoint = CGPoint(x: 0, y: 0)

            let fromRect = fromNode.flatMap { transitionHostRect(of: $0) }
            let toRect = toNode.flatMap { transitionHostRect(of: $0) }
            let fromCornerRadius = fromNode.flatMap { renderer.layer(for: $0.id)?.cornerRadius }
            let toCornerRadius = toNode.flatMap { renderer.layer(for: $0.id)?.cornerRadius }
            // D71's crop/fit open item, closed here: the snapshot's `contentsGravity` (and any
            // bitmap already on the "to" endpoint's real layer) is read exactly once, at
            // prepare, from whichever side this motion reveals — never re-read per frame.
            if let snapshotNode = toNode ?? fromNode,
                let snapshotLayer = renderer.layer(for: snapshotNode.id)
            {
                layer.contents = snapshotLayer.contents
                layer.contentsGravity = snapshotLayer.contentsGravity
            }
            layer.masksToBounds = true

            let startRect = fromRect ?? toRect ?? .zero
            layer.position = startRect.origin
            layer.bounds = CGRect(origin: .zero, size: startRect.size)
            layer.cornerRadius = fromCornerRadius ?? toCornerRadius ?? 0
            layer.opacity = fromRect == nil ? 0 : 1

            switch (fromRect, toRect) {
            case let (.some, .some(endRect)):
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "position.x",
                        to: endRect.origin.x,
                        beginProgress: begin,
                        endProgress: end
                    )
                )
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "position.y",
                        to: endRect.origin.y,
                        beginProgress: begin,
                        endProgress: end
                    )
                )
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "bounds.size.width",
                        to: endRect.size.width,
                        beginProgress: begin,
                        endProgress: end
                    )
                )
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "bounds.size.height",
                        to: endRect.size.height,
                        beginProgress: begin,
                        endProgress: end
                    )
                )
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "cornerRadius",
                        to: toCornerRadius ?? 0,
                        beginProgress: begin,
                        endProgress: end
                    )
                )
            case (.some, nil):
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "opacity",
                        to: Float(0),
                        beginProgress: begin,
                        endProgress: end
                    )
                )
            case (nil, .some):
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "opacity",
                        to: Float(1),
                        beginProgress: begin,
                        endProgress: end
                    )
                )
            case (nil, nil):
                break
            }

            anchorLayer = layer
            transitionRoleVisuals[role] = .geometry(layer: layer)
        }

        for role in roleOrder {
            guard let endpoints = session.roles[role] else { continue }
            let sourceNode = endpoints.source.flatMap {
                findTransitionNode($0, in: root) as? TextNode
            }
            let destinationNode = endpoints.destination.flatMap {
                findTransitionNode($0, in: root) as? TextNode
            }
            let fromNode = direction == .opening ? sourceNode : destinationNode
            let toNode = direction == .opening ? destinationNode : sourceNode
            guard fromNode != nil || toNode != nil else { continue }

            let begin = endpoints.interval?.lowerBound ?? 0
            let end = endpoints.interval?.upperBound ?? 1
            let inset = anchorLayer.bounds.insetBy(dx: 8, dy: 8)
            var fromLayer: CALayer?
            var toLayer: CALayer?

            if let fromNode {
                let layer = renderer.materializeTransitionRasterLayer(
                    role: role,
                    side: .source,
                    parent: anchorLayer
                )
                layer.frame = inset
                layer.opacity = 1
                if let image = rasterizeTransitionTitle(fromNode, scale: scale) {
                    layer.contents = image
                }
                fromLayer = layer
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "opacity",
                        to: Float(0),
                        beginProgress: begin,
                        endProgress: end
                    )
                )
            }
            if let toNode {
                let layer = renderer.materializeTransitionRasterLayer(
                    role: role,
                    side: .destination,
                    parent: anchorLayer
                )
                layer.frame = inset
                layer.opacity = 0
                if let image = rasterizeTransitionTitle(toNode, scale: scale) {
                    layer.contents = image
                }
                toLayer = layer
                targets.append(
                    Target(
                        layer: layer,
                        keyPath: "opacity",
                        to: Float(1),
                        beginProgress: begin,
                        endProgress: end
                    )
                )
            }
            transitionRoleVisuals[role] = .title(source: fromLayer, destination: toLayer)
        }

        let token = session.token
        switch mode {
        case .automatic:
            transitionAnimator.play(
                token: token,
                targets: targets,
                duration: duration,
                timingFunction: .easeInEaseOut
            ) { [weak self] in
                self?.completeTransitionMotion(direction: direction, token: token)
            }
        case .manual:
            transitionAnimator.arm(token: token, targets: targets, duration: duration)
        }

        setTransitionHidden(session.sourceNodeID, hidden: true, root: root)
        setTransitionHidden(session.destinationRootID, hidden: true, root: root)

        var updated = session
        updated.state =
            settleState ?? (direction == .opening ? .opening : .settling(target: .closed))
        if mode == .manual, resetProgressOnManual { updated.progress = 0 }
        transitionSessionStorage = updated
        transitionBuiltBounds = lastCommittedRequest?.bounds
        Log.on(
            .host,
            "transition-arm",
            host: hostID,
            "direction=\(direction) mode=\(mode) targets=\(targets.count)"
        )
    }

    private func rasterizeTransitionTitle(_ node: TextNode, scale: Double) -> CGImage? {
        guard let frame = node.calculatedFrame, frame.width > 0, frame.height > 0 else {
            return nil
        }

        let environment = node.environment
        let input = TextLayoutInput(
            document: node.document,
            style: node.textStyle,
            direction: environment.layoutDirection,
            localeIdentifier: environment.localeIdentifier,
            maxLines: node.maxLines,
            truncation: node.truncation
        )
        let resolvedColor = node.textStyle.color ?? resolveThemeColor(.text, in: environment.theme)
        let request = TextDisplayRequest(
            input: input,
            size: MeasuredSize(width: frame.width, height: frame.height),
            resolvedColor: resolvedColor,
            scale: scale
        )
        // M11 (`docs/validation/m10-transition-contract.md` §3's rasterization choice): rastered
        // directly, once per endpoint at prepare — the same synchronous CoreText call the M10
        // prototype used — rather than through `DisplayScheduler`: a title endpoint has no
        // `NodeID` of its own to key a scheduled job by, and prepare is already a one-shot
        // measurement (D71), so a background-scheduled job would add cancellation/coalescing
        // machinery this call site does not need.
        return try? CoreTextRenderer().rasterize(request, context: .noCancellation).image
    }

    private func completeTransitionMotion(direction: TransitionDirection, token: UInt64) {
        guard var session = transitionSessionStorage, session.token == token else { return }

        switch direction {
        case .opening:
            session.state = .presented
            session.progress = 1
            transitionSessionStorage = session
            renderer.endTransitionOverlay()
            transitionRoleVisuals.removeAll()
            if let root {
                setTransitionHidden(session.destinationRootID, hidden: false, root: root)
                setTransitionHidden(session.sourceNodeID, hidden: true, root: root)
                findTransitionNode(session.sourceNodeID, in: root)?.accessibility.childrenPolicy =
                    .hide
                findTransitionNode(session.destinationRootID, in: root)?.accessibility
                    .childrenPolicy = transitionSavedAccessibilityPolicies?.destination ?? .contain
                focusEngine.setScope(session.destinationRootID, root: root)
                publishTransitionAccessibilityChange()
            }
            Log.on(.host, "transition-presented", host: hostID)
        case .closing:
            renderer.endTransitionOverlay()
            transitionRoleVisuals.removeAll()
            if let root {
                setTransitionHidden(session.sourceNodeID, hidden: false, root: root)
                setTransitionHidden(session.destinationRootID, hidden: true, root: root)
                restoreTransitionAccessibility(root: root)
                focusEngine.setScope(nil, root: root)
                publishTransitionAccessibilityChange()
            }
            transitionSessionStorage = nil
            transitionSavedAccessibilityPolicies = nil
            transitionGestureOrigin = nil
            transitionBuiltBounds = nil
            Log.on(.host, "transition-closed", host: hostID)
        }
    }

    private func publishTransitionAccessibilityChange() {
        if rebuildAccessibilityTree(), let accessibilityTree, let semanticSnapshot {
            onSemanticsPublished?(semanticSnapshot)
            onAccessibilityTreeChanged?(accessibilityTree)
        }
    }

    private func cancelTransition(reason: String) {
        guard let session = transitionSessionStorage else { return }

        renderer.endTransitionOverlay()
        transitionRoleVisuals.removeAll()
        if let root {
            restoreTransitionAccessibility(root: root)
            setTransitionHidden(session.sourceNodeID, hidden: false, root: root)
            setTransitionHidden(session.destinationRootID, hidden: false, root: root)
        }
        transitionSessionStorage = nil
        transitionSavedAccessibilityPolicies = nil
        transitionPendingRequest = nil
        transitionGestureOrigin = nil
        transitionBuiltBounds = nil
        Log.on(.host, "transition-cancelled", host: hostID, "reason=\(reason)")
    }

    private var transitionAllKeyPaths: [String] {
        [
            "position.x", "position.y", "bounds.size.width", "bounds.size.height", "cornerRadius",
            "opacity",
        ]
    }

    private func collectTransitionLayers() -> [CALayer] {
        var layers: [CALayer] = []
        for visual in transitionRoleVisuals.values {
            switch visual {
            case let .geometry(layer):
                layers.append(layer)
            case let .title(source, destination):
                if let source { layers.append(source) }
                if let destination { layers.append(destination) }
            }
        }
        if let overlay = transitionSessionStorage?.overlayLayer { layers.append(overlay) }
        return layers
    }

    /// D67-style immediate finish for the active transition session — `suspend()` ("незавершён-
    /// ный interactiveClosing/opening → presented") and Reduce Motion turning on mid-transition
    /// ("немедленно к текущему логическому endpoint") both call this. `preparing` has no visible
    /// movement yet, so it cancels outright rather than "finishing" toward anything (D71: same
    /// as an explicit cancellation).
    private func finishTransitionMotionInPlace() {
        guard let session = transitionSessionStorage else { return }
        // D73: "незавершённый interactiveClosing -> presented" always snaps a live gesture
        // straight to `.opening`'s completion below, never through `settleTransitionGesture` —
        // clear the gesture bookkeeping here too, or a later `updateTransitionGesture`/
        // `endTransitionGesture` call stray from a not-yet-torn-down platform recognizer would
        // find a stale `transitionGestureOrigin` for a session that no longer has a live driver.
        transitionGestureOrigin = nil

        switch session.state {
        case .preparing:
            cancelTransition(reason: "suspend")
        case .opening, .interactiveClosing:
            transitionAnimator.finishInPlace(
                on: collectTransitionLayers(),
                keyPaths: transitionAllKeyPaths
            )
            completeTransitionMotion(direction: .opening, token: session.token)
        case let .settling(target):
            transitionAnimator.finishInPlace(
                on: collectTransitionLayers(),
                keyPaths: transitionAllKeyPaths
            )
            completeTransitionMotion(
                direction: target == .presented ? .opening : .closing,
                token: session.token
            )
        case .presented:
            break
        }
    }

    private var transitionDurationSeconds: CFTimeInterval {
        let parts = transitionDuration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Test hook: directly invokes the completion `buildTransitionVisuals(direction:)` armed
    /// for the current session's token, inferring `direction` from `state`. Real CA
    /// completion-block delivery does not reach an XCTest-hosted process on this toolchain (M02,
    /// `docs/validation/m02-animation-prototype.md` §1.4 — `LayerAnimator.completeIfCurrent`
    /// documents the same precedent for D61's own per-property animations); everything up to
    /// this point — the real explicit `CABasicAnimation`s, their `fromValue`/`toValue`, the
    /// model writes, the hidden/visible layer toggling — already ran for real. A no-op without
    /// an active session or while `.presented`/`.preparing` (nothing to complete).
    func forceCompleteTransitionMotionForTesting() {
        guard let session = transitionSessionStorage else { return }

        switch session.state {
        case .opening:
            completeTransitionMotion(direction: .opening, token: session.token)
        case let .settling(target):
            completeTransitionMotion(
                direction: target == .closed ? .closing : .opening,
                token: session.token
            )
        case .preparing, .presented, .interactiveClosing:
            break
        }
    }
}

/// Which direction `buildTransitionVisuals(direction:)` is currently arming — opening plays
/// source→destination and reveals the destination; closing plays destination→source and
/// reveals the source. Not part of `TransitionSessionState` itself: `.opening`/`.settling`
/// already distinguish this at the state-machine level (D72); this is the engine's own smaller
/// parameter for "which way do the endpoints face this call."
private enum TransitionDirection {
    case opening
    case closing
}

/// Which `TransitionAnimator` entry point `buildTransitionVisuals(direction:mode:settleState:)`
/// commits its built targets through (M12). Not part of `TransitionSessionState` — orthogonal to
/// D72's state table, which only cares about the resulting state, not the mechanism that got
/// there.
private enum TransitionBuildMode {
    /// Plays for real (`TransitionAnimator.play`), as every M11 build did.
    case automatic
    /// Parks the motion for a gesture to scrub (`TransitionAnimator.arm`).
    case manual
}

/// Which absolute endpoint a live `.interactiveClosing` gesture's `progress` is running toward
/// (M12) — see `NodeHostBridge.transitionGestureOrigin`'s doc comment for the full rationale.
private enum TransitionGestureOrigin {
    /// `progress` runs source/closed (`0`) → destination/presented (`1`): a gesture grabbed an
    /// in-flight `.opening` (D72: "жест начался до завершения открытия").
    case continuingOpen
    /// `progress` runs destination/presented (`0`) → source/closed (`1`): a fresh dismiss
    /// gesture began from `.presented`.
    case closingFromPresented
}

/// Engine-private bookkeeping for one role's overlay layer(s) — never exposed on the public
/// `TransitionSession`, which carries identities only (D71).
private enum TransitionRoleVisual {
    case geometry(layer: CALayer)
    case title(source: CALayer?, destination: CALayer?)
}

private typealias Target = TransitionAnimator.Target
