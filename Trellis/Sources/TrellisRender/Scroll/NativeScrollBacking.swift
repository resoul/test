import CoreGraphics
import QuartzCore
import TrellisCore

/// Adapter boundary for one `ScrollNode`'s real native scroll view (R07,
/// `docs/validation/r06-scroll-api-sketch.md` §3). `TrellisRender` only knows this protocol —
/// `TrellisUIKit`/`TrellisAppKit` supply the concrete `UIScrollView`/`NSScrollView` wrapper, the
/// same module-boundary shape already used by `TextRenderer` (D51) and Weave's analogous
/// `EdgePullContainer` (`docs/weave-scroll-analysis.md` §2).
///
/// `containerLayer` is a refinement found while implementing this protocol against the sketch
/// (`docs/validation/r07-scroll-node.md`): `LayerRenderer` needs a concrete `CALayer` to
/// register as this node's layer (`layer(for:)`) and apply ordinary presentation
/// (`appearance`/`opacity`/`zIndex`/`transform`) to — the sketch specified the *content* layer
/// (`installContentLayer(_:)`) but not what `LayerRenderer` itself materializes for the node.
///
/// Ownership: created by a `NativeScrollBackingFactory` closure and retained by
/// `LayerRenderer`'s `scrollBackings` table until the node leaves the committed tree,
/// `unmount()`, or `detach()`. Isolation: MainActor. Errors: none. Cancellation:
/// `removeContentLayer()` releases this backing's reference to the `ScrollNode`'s children; the
/// concrete native view is released when `LayerRenderer` drops its last strong reference to
/// this backing.
@MainActor
public protocol NativeScrollBacking: AnyObject {
    /// The native scroll view's own layer. Added to a fixed top-level container by the adapter
    /// itself at creation, positioned at the `ScrollNode`'s committed frame in host-absolute
    /// coordinates — `LayerRenderer` applies presentation and geometry to it exactly as it
    /// would a plain `CALayer`, but never calls `addSublayer`/`insertSublayer` on it (R07's
    /// scope boundary: full nested-ancestor-clip/transform compositing of the native view
    /// itself is not built here, see `docs/validation/r07-scroll-node.md` "Открытые пункты").
    ///
    /// Ownership: returns a value; the adapter retains the native view this layer belongs to.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    var containerLayer: CALayer { get }

    /// Positions the native scroll view at `frame`, host-absolute (the same coordinate space
    /// `HitTestSnapshot.Record.frame` uses), optionally relative to an ancestor scroll content
    /// surface. A `UIView`/`NSView` keeps its own `frame`/`bounds`
    /// bookkeeping independent of its `CALayer`'s `bounds`/`position` — writing the layer's
    /// geometry directly desyncs the view's own `frame` property from what is actually on
    /// screen, which matters because UIKit's own touch hit-testing (and AppKit's mouse
    /// hit-testing) read the *view*'s frame, not the layer's (found while implementing R07's
    /// embedding tests, `docs/validation/r07-scroll-node.md`: a first version had
    /// `LayerRenderer` write `containerLayer.bounds`/`.position` directly, which visually
    /// looked correct but left `UIScrollView.frame`/`NSScrollView.frame` stale at their
    /// creation-time `.zero`). The adapter implements this by setting its native view's own
    /// `frame`, not by touching `containerLayer` itself.
    ///
    /// Ownership: no ownership change. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    ///
    /// Ownership: no ownership change. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?)

    /// Root-absolute origin of this backing's native content surface. A nested backing uses this
    /// to convert its committed root-absolute frame to the coordinate system of its native
    /// parent. The value does not include the parent's changing scroll offset: a native content
    /// view performs that translation itself.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var contentOriginInHost: LayoutPoint { get }

    /// Creates a backing whose native view is a child of this backing's content surface. The
    /// renderer calls this only for a nested `ScrollNode`; a root-level backing returns `nil`
    /// when the platform cannot host native children this way.
    ///
    /// Ownership: the returned backing is retained by `LayerRenderer`; this backing retains no
    /// child through this call. Isolation: MainActor. Errors: none. Cancellation: the child's
    /// `removeContentLayer()` releases its native content on teardown.
    func makeChildBacking(
        nodeID: NodeID
    ) -> (any NativeScrollBacking)?

    /// The native viewport's current size — read-only: native
    /// (`documentVisibleRect`/`bounds`) is the source of truth (§8's feedback suppression),
    /// Trellis never derives this independently.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var viewportSize: MeasuredSize { get }

    /// The native view's current content offset. Reading always returns native's live value;
    /// writing is only ever done by a `ScrollCommand` handler while `isUserDriven == false`
    /// (§8) — never during an active gesture/deceleration.
    ///
    /// Ownership: returns/accepts a value. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    var contentOffset: LayoutPoint { get set }

    /// Sets the native scrollable content size (`UIScrollView.contentSize`/an `NSScrollView`'s
    /// document view frame) from the union of the `ScrollNode`'s children's committed frames.
    ///
    /// Ownership: no ownership change. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func setContentSize(_ size: MeasuredSize)

    /// Applies `ScrollConfiguration.contentInsets` plus safe area (already summed once by the
    /// caller, `scroll-configuration.md` §2.2) as the native content-inset equivalent.
    ///
    /// Ownership: no ownership change. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func setInsets(_ insets: DirectionalEdgeInsets)

    /// Applies interaction and presentation settings owned by `ScrollNode.configuration` to
    /// the native scroll view. Geometry stays on the separate `setFrame`, `setContentSize`, and
    /// `setInsets` paths, so changing a policy never needs a layout solve.
    ///
    /// Ownership: no ownership change. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func apply(configuration: ScrollConfiguration)

    /// Installs the `CALayer` that holds the `ScrollNode`'s children as sublayers, inside the
    /// native scroll view's own content/document layer. Called once, right after this backing
    /// is created.
    ///
    /// Ownership: the backing retains `layer` until `removeContentLayer()`. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    func installContentLayer(_ layer: CALayer)

    /// Releases the content layer installed by `installContentLayer(_:)`.
    ///
    /// Ownership: releases the retained content layer. Isolation: MainActor. Errors: none.
    /// Cancellation: this is one.
    func removeContentLayer()

    /// Removes the backing's native scroll view from its native parent after its content layer
    /// has been released. A `CALayer.removeFromSuperlayer()` alone does not remove a UIKit or
    /// AppKit view from its superview, so this is the one explicit native-view teardown path for
    /// both root and nested scrolls.
    ///
    /// Ownership: releases the backing's native view hierarchy. Isolation: MainActor. Errors:
    /// none. Cancellation: this call is the backing's teardown cancellation point.
    func dispose()

    /// Issues a native scroll command. `completion`'s `Bool` is native's own "finished" flag —
    /// `false` for an animation interrupted by user input or a later command, `true` for a
    /// completed scroll (including a synchronous, already-there no-op for `animated: false`).
    ///
    /// Ownership: retains `completion` until it is called exactly once. Isolation: MainActor.
    /// Errors: none. Cancellation: a later call to this method, or user input, ends the
    /// previous one's animation without calling its own `completion` — the caller
    /// (`NodeHostBridge`) resolves that outcome itself via `NativeScrollBackingDelegate`.
    func scroll(
        to offset: LayoutPoint,
        animated: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    )

    /// Scrolls to `offset` with a Trellis `Animation` — its duration and curve, the same timing
    /// `LayerAnimator` gives layer animations (`ScrollCommand.timed`, R13).
    ///
    /// Ownership: retains `completion` until it is called exactly once. Isolation: MainActor.
    /// Errors: none. Cancellation: as `scroll(to:animated:completion:)`; a later scroll call
    /// stops the animation where it is on screen.
    func scroll(
        to offset: LayoutPoint,
        animation: Animation,
        completion: @escaping @MainActor (Bool) -> Void
    )

    /// The offset shown on screen right now — mid-animation the presented value, otherwise
    /// `contentOffset`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var presentedContentOffset: LayoutPoint { get }
}

/// Default nesting behaviour for a native scroll backing.
///
/// Ownership: adds no retained state. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
public extension NativeScrollBacking {
    /// Default for adapters that cannot embed a native scroll view inside their content surface.
    /// `LayerRenderer` falls back to the host factory for a non-nested backing; Trellis's UIKit
    /// and AppKit adapters override this to preserve true native nesting.
    ///
    /// Ownership: returns no object. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func makeChildBacking(
        nodeID: NodeID
    ) -> (any NativeScrollBacking)? { nil }

    /// Default for adapters without timed animation: the platform's own animated scroll.
    ///
    /// Ownership: retains `completion` until it is called. Isolation: MainActor. Errors: none.
    /// Cancellation: as `scroll(to:animated:completion:)`.
    func scroll(
        to offset: LayoutPoint,
        animation: Animation,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        scroll(to: offset, animated: animation.duration > .zero, completion: completion)
    }

    /// Default: the committed offset.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var presentedContentOffset: LayoutPoint { contentOffset }
}

/// Reports native-driven scroll changes back to whoever owns command bookkeeping and hit-test
/// offset state (`NodeHostBridge`, R07) — kept out of `NativeScrollBacking` itself so the
/// protocol only describes what Trellis asks the backing to do, not who it tells (mirrors
/// `EdgePullContainer`'s adapter-holds-a-weak-back-reference shape,
/// `docs/weave-scroll-analysis.md` §2).
///
/// Ownership: implemented by `NodeHostBridge`; a backing holds its delegate weakly. Isolation:
/// MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public protocol NativeScrollBackingDelegate: AnyObject {
    /// Called on every native offset/phase change — a drag tick, deceleration, or a
    /// `scroll(to:animated:completion:)` call's own intermediate frames.
    ///
    /// Ownership: nothing retained past the call. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func scrollBacking(
        for node: NodeID,
        didChangeOffset offset: LayoutPoint,
        phase: ScrollPhase
    )
}

/// Creates a `NativeScrollBacking` for one committed `ScrollNode`, with `delegate` already
/// bound — supplied to `NodeHostBridge.attach(...)` the same way `textRenderer` already is
/// (D51's precedent), not a global registry.
///
/// Ownership: the factory borrows `delegate` for the call; the returned backing holds it
/// weakly. Isolation: MainActor. Errors: none. Cancellation: not applicable.
public typealias NativeScrollBackingFactory =
    @MainActor (_ node: NodeID, _ delegate: any NativeScrollBackingDelegate) ->
    any NativeScrollBacking

/// Issues programmatic scroll commands against a mounted `ScrollNode` (R07,
/// `r06-scroll-api-sketch.md` §7/§9) — command issuance and pending-completion bookkeeping live
/// on the host bridge that owns the node's native backing, not on `ScrollNode` itself, mirroring
/// the existing `send(_:_:)`/`bindState(_:update:)` explicit-target pattern instead of a new one.
///
/// Ownership: implemented by `NodeHostBridge`. Isolation: MainActor. Errors: none. Cancellation:
/// `detach()` resolves every pending completion with `.notAttached` before returning.
@MainActor
public protocol ScrollCommandIssuing: AnyObject {
    /// Issues `command` against `node`. Only the most recently issued token for `node` can
    /// resolve `.completed` — an earlier pending one resolves `.supersededByLaterCommand`
    /// synchronously, before this call returns.
    ///
    /// Ownership: retains `completion` until it is called exactly once. Isolation: MainActor.
    /// Errors: none — every rejection is a terminal `ScrollCommandOutcome`, not a thrown error.
    /// Cancellation: user input starting a gesture while this command is pending resolves it
    /// `.cancelledByUserInput`; `detach()` resolves it `.notAttached`.
    @discardableResult
    func scroll(
        _ command: ScrollCommand,
        on node: ScrollNode,
        completion: (@MainActor (ScrollCommandOutcome) -> Void)?
    ) -> ScrollCommandToken
}
