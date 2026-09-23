import Foundation

/// A container node whose overflow is scrolled by a real native scroll view, not by Trellis
/// itself (R07, `r06-scroll-api-sketch.md`). Same shape as `ControlNode`: a plain `open class`
/// with no CALayer/UIKit reference of its own — the native backing is owned by
/// `LayerRenderer`/the platform adapter (D16's layering), never by this node.
///
/// Setting `style.visual.overflow` to anything other than `.scroll` on a `ScrollNode` is
/// accepted (nothing prevents it) but the renderer only materializes a native backing while it
/// reads `.scroll` — the node behaves like a plain clipping/visible container otherwise. A
/// fresh `ScrollNode` defaults its own `style.visual.overflow` to `.scroll` in `init`, since a
/// `ScrollNode` that does not scroll is very likely a mistake, not an intended configuration.
///
/// `state`/`onScrollStateChanged` are published by whichever host bridge owns this node's
/// native backing (`NodeHostBridge`, R07's ownership table) — never written by this node
/// itself; `publish(_:)` exists for that bridge to call, not for general use.
///
/// Ownership: owns its `configuration` and last-published `state` as values; owns no native
/// object. Isolation: MainActor. Errors: none. Cancellation: `dispose()` (inherited) is this
/// node's only lifecycle-owned cancellation point — a pending `ScrollCommandToken` completion is
/// the host bridge's own cancellation point (`ScrollCommandIssuing`, `TrellisRender`), not this
/// node's.
@MainActor
open class ScrollNode: Node {
    /// This node's scroll configuration. Assigning an equal value is a no-op; changing it does
    /// not by itself request a flush — a host bridge reads the new value at its next commit
    /// (`scroll-configuration.md` §4's per-field timing table is the adapter's responsibility,
    /// not this node's).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    ///
    /// Changing `axis` realigns `style.flexDirection` with it (ADR 0026 amendment, defect #84):
    /// the scrollable axis is the flex main axis, so a vertical scroll node lays out as a column
    /// and a horizontal one as a row; a reverse direction keeps its reversal, `.both` changes
    /// nothing.
    public var configuration: ScrollConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            Log.on(.style, "changed", node: id, "kind=scroll-configuration")
            if configuration.axis != oldValue.axis {
                alignDirectionWithAxis()
            }
        }
    }

    /// Layout style of the scroll node. Setting a `flexDirection` whose main axis differs from
    /// `configuration.axis` is allowed but logged as `style scroll-axis-mismatch`: the content
    /// then does not scroll along the configured axis.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none — a mismatch is logged,
    /// not rejected. Cancellation: not applicable.
    public override var style: LayoutStyle {
        didSet {
            guard style.flexDirection != oldValue.flexDirection, directionMismatchesAxis else {
                return
            }
            Log.on(
                .style,
                "scroll-axis-mismatch",
                node: id,
                "axis=\(configuration.axis) direction=\(style.flexDirection)"
            )
        }
    }

    /// Whether `style.flexDirection`'s main axis differs from `configuration.axis`.
    var directionMismatchesAxis: Bool {
        Self.aligned(style.flexDirection, to: configuration.axis) != style.flexDirection
    }

    /// The last state published for this node by its host bridge — `ScrollState()` (zero
    /// offset, zero content/viewport) before any commit with a real native backing.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var state = ScrollState()

    /// Called every time `state` changes — offset-only ticks included (the "offset-only путь"
    /// R07's checklist names). Mirrors the existing host-callback pattern already used
    /// elsewhere in this module (`onInvalidate`), not a new `ActionPipe`-shaped API.
    ///
    /// Ownership: the node retains the closure; capture `self` weakly. Isolation: MainActor.
    /// Errors: none. Cancellation: the owner clears it by assigning `nil`; never called after
    /// `dispose()`.
    public var onScrollStateChanged: (@MainActor (ScrollState) -> Void)?

    /// Creates a scroll node with `.scroll` overflow already set on `style.visual` and a
    /// `flexDirection` aligned with the default vertical axis (`.row` becomes `.column`).
    ///
    /// Ownership: as `Node.init`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public override init(
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        var resolvedStyle = style
        resolvedStyle.visual = LayoutVisualProperties(
            zIndex: style.visual.zIndex,
            overflow: .scroll,
            opacity: style.visual.opacity,
            transform: style.visual.transform
        )
        // The default axis is vertical, so the default layout is a column (defect #84).
        resolvedStyle.flexDirection = Self.aligned(style.flexDirection, to: .vertical)
        configuration = ScrollConfiguration(axis: .vertical)
        super.init(style: resolvedStyle, appearance: appearance, environment: environment)
    }

    private func alignDirectionWithAxis() {
        let aligned = Self.aligned(style.flexDirection, to: configuration.axis)
        guard aligned != style.flexDirection else { return }

        style.flexDirection = aligned
        Log.on(
            .style,
            "scroll-direction-aligned",
            node: id,
            "axis=\(configuration.axis) direction=\(aligned)"
        )
    }

    static func aligned(_ direction: FlexDirection, to axis: ScrollAxis) -> FlexDirection {
        switch (axis, direction) {
        case (.vertical, .row): return .column
        case (.vertical, .rowReverse): return .columnReverse
        case (.horizontal, .column): return .row
        case (.horizontal, .columnReverse): return .rowReverse
        default: return direction
        }
    }

    /// Publishes a new state and notifies `onScrollStateChanged` — called by the host bridge
    /// that owns this node's native backing at every geometry commit and every native-driven
    /// offset tick (R07's offset-only path). Not for general use: a caller other than the
    /// owning bridge that calls this races the bridge's own bookkeeping.
    ///
    /// Ownership: takes ownership of `newState`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func publish(_ newState: ScrollState) {
        state = newState
        onScrollStateChanged?(newState)
    }
}
