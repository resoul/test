import QuartzCore
import TrellisCore

/// Which side of a transition a title-endpoint raster belongs to — `LayerRenderer`'s
/// `transitionRasterLayers` key, alongside `Role` (D71).
enum TransitionEndpointSide: Hashable {
    case source
    case destination
}

/// `LayerRenderer.transitionRasterLayers`'s key: a role's raster is session-scoped, not
/// node-scoped, so it is addressed by `(Role, side)` rather than `NodeID`.
struct TransitionRasterKey: Hashable {
    let role: Role
    let side: TransitionEndpointSide
}

/// One role's endpoints inside a `TransitionSession` (D70/D71): the local identity that plays
/// this role on the source side and on the destination side. Either side may be `nil` — a role
/// missing on one side uses fade instead of flight (D70), validated at prepare time, not
/// per-frame.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TransitionRoleEndpoints: Sendable, Hashable {
    /// The identity playing this role on the source side, or `nil` if this role has no source
    /// counterpart.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let source: NodeID?

    /// The identity playing this role on the destination side, or `nil` if this role has no
    /// destination counterpart.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let destination: NodeID?

    /// The sub-range of the session's unified `0...1` progress this role's own motion is
    /// confined to (D70: "все части используют единый progress 0…1, собственные интервалы и
    /// кривые внутри него") — before `interval.lowerBound` the role holds its starting value,
    /// after `interval.upperBound` it holds its ending value. `nil` (the default, and every
    /// mapping before M14) spans the full range — identical to the M11–M13 behavior of a single
    /// shared timeline for every role.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let interval: ClosedRange<Double>?

    /// Creates a role's endpoint pair.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(source: NodeID?, destination: NodeID?, interval: ClosedRange<Double>? = nil) {
        self.source = source
        self.destination = destination
        self.interval = interval
    }
}

/// Which logical endpoint a `settling` session is headed to (D72's state table).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TransitionSettleTarget: Sendable, Hashable {
    /// Settling back toward the fully-open destination page.
    case presented
    /// Settling toward the fully-closed source card — the session ends when this completes.
    case closed
}

/// D72's accepted state table (`docs/validation/m10-transition-contract.md` §1.3), implemented
/// exactly as tabulated. M11 only drives `preparing`/`opening`/`presented`/`settling` through a
/// button; `interactiveClosing` is modeled so M12's gesture input has a state to land in without
/// a shape change, per M11's own checklist.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TransitionSessionState: Sendable, Hashable {
    /// Roles/artifacts are being validated and the destination is being measured; the source
    /// stays interactive and the request can still be cancelled (D71).
    case preparing
    /// Automatic (non-gesture) motion from source to destination is in flight.
    case opening
    /// At rest on the destination; the modal scope is open (D73).
    case presented
    /// A live gesture drives `progress` directly — not wired by M11 (M12).
    case interactiveClosing
    /// Automatic motion is settling toward `target`, from either a finished/cancelled gesture
    /// (M12) or a non-interactive button close (M11).
    case settling(target: TransitionSettleTarget)
}

/// One in-flight composite card→page transition (D70–D74, settled by
/// `docs/validation/m10-transition-contract.md` §1.2). Exactly one at a time per
/// `NodeHostBridge` — `NodeHostBridge.transitionSession` is a single optional property, not a
/// registry, the same "one modal scope, no stack" shape D40 already uses for
/// `focusScopeID` and the bridge's own single `mountEpoch`.
///
/// `sourceNodeID`/`destinationRootID` are identities into the mounted tree, not strong `Node`
/// references (D71: "Live source/destination остаются во владении обычных деревьев") —
/// `overlayLayer` is the one thing this session itself owns, a temporary `LayerRenderer`-owned
/// `CALayer` in the same pattern as `LayerRenderer.rasterLayers` (D65/T07): a render-only object
/// with no `NodeID` and no place in `LayerRegistry`.
///
/// `token` is one value per **session**, not per `(NodeID, property)` the way
/// `LayerAnimator.ActiveKey` addresses D61 animations — a whole-session retarget (D72: a
/// repeated `present`/close reverses the same session) invalidates every layer this session
/// touches at once, never one property independently of the others.
///
/// Ownership: retains `overlayLayer`, which the session's owner (`NodeHostBridge`, through its
/// private transition engine) also detaches on close/detach/suspend. Isolation: MainActor —
/// `CALayer` is native mutable state. Errors: none — invalid requests are rejected before a
/// session is created (`NodeHostBridge.presentTransition(_:)`). Cancellation: the owning engine
/// tears down `overlayLayer` and any transition-only raster layers when the session ends, by any
/// path (close, detach, suspend).
@MainActor
public struct TransitionSession {
    /// The identity playing the transition's "whole card"/"whole page" anchor on the source
    /// side.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let sourceNodeID: NodeID

    /// The root identity of the destination side, already part of the mounted tree (D73: modal
    /// scope reuses `FocusEngine.setScope(_:)`, which scopes to a node already under the
    /// mounted root).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let destinationRootID: NodeID

    /// Every role this session carries, local to this session only (D70).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public internal(set) var roles: [Role: TransitionRoleEndpoints]

    /// The temporary overlay layer `LayerRenderer` created and mounted directly on the host
    /// layer for this session — every role's transient visual (hero geometry, title-endpoint
    /// rasters) is a sublayer of this one, so tearing it down releases the whole set at once.
    ///
    /// Ownership: retained by the session and by `LayerRenderer` for its lifetime. Isolation:
    /// MainActor. Errors: none. Cancellation: removed from its superlayer when the session ends.
    public let overlayLayer: CALayer

    /// This session's current place in D72's state table.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public internal(set) var state: TransitionSessionState

    /// `0...1` progress toward the destination — driven automatically during `opening`/
    /// `settling`, or (M12) directly by a live gesture during `interactiveClosing`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public internal(set) var progress: Double

    /// One monotonic value per session (not per property) — a fresh `present`/close retarget
    /// bumps this, so a completion callback captured under the previous value is ignored rather
    /// than settling a session it no longer describes (D66's stale-completion rule, applied at
    /// session granularity per D71).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public internal(set) var token: UInt64

    init(
        sourceNodeID: NodeID,
        destinationRootID: NodeID,
        roles: [Role: TransitionRoleEndpoints],
        overlayLayer: CALayer,
        state: TransitionSessionState,
        progress: Double,
        token: UInt64
    ) {
        self.sourceNodeID = sourceNodeID
        self.destinationRootID = destinationRootID
        self.roles = roles
        self.overlayLayer = overlayLayer
        self.state = state
        self.progress = progress
        self.token = token
    }
}
