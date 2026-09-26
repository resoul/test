import Foundation

/// Which axis or axes a `ScrollNode` scrolls along (`docs/validation/r06-scroll-api-sketch.md`,
/// `docs/scroll-configuration.md` §2.1).
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum ScrollAxis: Sendable, Hashable {
    case vertical
    case horizontal
    case both
}

/// How `reveal(frame:alignment:)` positions a target frame inside the viewport
/// (`r06-scroll-api-sketch.md` §1, ported in shape from Weave's `ScrollAlignment`).
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum ScrollAlignment: Sendable, Hashable {
    /// Moves the minimum distance needed to bring the frame fully inside the viewport; a no-op
    /// if it already is (scenario 6, `r06-scroll-api-sketch.md` §10).
    case nearest
    case start
    case center
    case end
}

/// Where a `ScrollNode`'s current motion comes from (`r06-scroll-api-sketch.md` §6). Trellis
/// only ever reads `.dragging`/`.decelerating` from the native backing — it cannot initiate or
/// end either transition itself; `.settling`/`.programmatic` are the two a `ScrollCommand`
/// handler puts a node into.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum ScrollPhase: Sendable, Hashable {
    case idle
    /// User touch/trackpad actively moving the offset — native-driven, native is the source of
    /// truth (§8).
    case dragging
    /// Native momentum after release — still native-driven.
    case decelerating
    /// A programmatic `scroll(_:animated: true)` in flight.
    case settling
    /// A programmatic `scroll(_:animated: false)` — synchronous; visible for one published
    /// revision only.
    case programmatic
}

/// Snapshot of one `ScrollNode`'s viewport geometry and motion — the Sendable value every
/// coordinate conversion, command, and completion reads (`r06-scroll-api-sketch.md` §1/§7).
/// Holds no `CALayer`/native reference; `TrellisCore` stays Foundation-only (AGENTS.md).
///
/// `offset` is always clamped to `[0, contentSize - viewportSize]` on each axis independently —
/// the same clamp Weave's `Scroll.swift` used, ported without changing the math
/// (`docs/weave-scroll-analysis.md` §6, AGENTS.md "Перенос из Weave": layout math preserved).
///
/// Ownership: a plain value; not owned by `ScrollNode` alone — published to it, held until
/// superseded, by whichever host bridge owns the node's native backing (D14-style owner,
/// `scroll-configuration.md` §2.5). Isolation: none — Sendable. Errors: non-finite/negative
/// geometry is clamped or rejected by `LayoutPoint`/`MeasuredSize`'s own constructors.
/// Cancellation: not applicable.
public struct ScrollState: Sendable, Hashable {
    /// Current scroll offset, in content space, already clamped to this state's own
    /// `contentSize`/`viewportSize`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let offset: LayoutPoint

    /// Content extent in content space — the union of the `ScrollNode`'s children's committed
    /// frames, never smaller than `viewportSize` (a short/empty content clamps to the viewport
    /// itself, so `offset` stays at zero — scenario "empty/short content",
    /// `implementation-plan-6.md` R07 checklist).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let contentSize: MeasuredSize

    /// Native viewport size — read from `NativeScrollBacking.viewportSize`, never computed by
    /// Trellis independently (§8).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let viewportSize: MeasuredSize

    /// This state's motion phase.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let phase: ScrollPhase

    /// `true` while native owns `offset` (`phase` is `.dragging` or `.decelerating`) — the
    /// feedback-suppression flag of §8: while this is `true`, nothing writes
    /// `NativeScrollBacking.contentOffset`, only reads it.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isUserDriven: Bool

    /// Monotonically increasing per published state for this node — bumped by the publisher on
    /// every change, including an offset-only tick (mirrors Weave's `Scroll.swift` `commit`,
    /// which bumps on every call, `docs/weave-scroll-analysis.md` §2).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let revision: UInt64

    /// Creates a scroll state, clamping `offset` to `[0, contentSize - viewportSize]` on each
    /// axis independently.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        offset: LayoutPoint = LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize = MeasuredSize(width: 0, height: 0),
        viewportSize: MeasuredSize = MeasuredSize(width: 0, height: 0),
        phase: ScrollPhase = .idle,
        isUserDriven: Bool = false,
        revision: UInt64 = 0
    ) {
        self.offset = Self.clamp(offset, contentSize: contentSize, viewportSize: viewportSize)
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.phase = phase
        self.isUserDriven = isUserDriven
        self.revision = revision
    }

    /// Clamps a candidate offset to `[0, max(0, contentSize - viewportSize)]` on each axis
    /// independently — the one clamp formula every command/native-offset path shares (§2.5's
    /// "clamp with anchor" resize rule reduces to this once the anchor itself is resolved).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func clamp(
        _ offset: LayoutPoint,
        contentSize: MeasuredSize,
        viewportSize: MeasuredSize
    ) -> LayoutPoint {
        let maxX = max(0, contentSize.width - viewportSize.width)
        let maxY = max(0, contentSize.height - viewportSize.height)
        return LayoutPoint(x: min(max(offset.x, 0), maxX), y: min(max(offset.y, 0), maxY))
    }

    /// The currently visible content rectangle — `LayoutFrame(origin: offset, size:
    /// viewportSize)`, pure geometry from already-known fields, never a fresh child walk (this
    /// is the concrete meaning of the checklist's "offset-only путь", R07's plan).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var visibleContentFrame: LayoutFrame {
        LayoutFrame(origin: offset, width: viewportSize.width, height: viewportSize.height)
    }

    /// Converts a content-space point to viewport space — `viewportPoint = contentPoint -
    /// offset` (§1's single conversion, shared by hit-testing, reveal, and AX).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func viewportPoint(fromContent point: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: point.x - offset.x, y: point.y - offset.y)
    }

    /// Converts a viewport-space point to content space — the inverse of
    /// `viewportPoint(fromContent:)`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func contentPoint(fromViewport point: LayoutPoint) -> LayoutPoint {
        LayoutPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    /// The offset `reveal(frame:alignment:)` should scroll to, computed independently per axis
    /// and then clamped once with this state's own `contentSize`/`viewportSize`. `.nearest`
    /// leaves an axis unchanged when `frame` is already fully within the current viewport on
    /// that axis (scenario 6, §10) — the only alignment with a real no-op case.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func revealOffset(for frame: LayoutFrame, alignment: ScrollAlignment) -> LayoutPoint {
        let targetX = Self.revealOffset(
            frameOrigin: frame.origin.x,
            frameLength: frame.width,
            currentOffset: offset.x,
            viewportLength: viewportSize.width,
            alignment: alignment
        )
        let targetY = Self.revealOffset(
            frameOrigin: frame.origin.y,
            frameLength: frame.height,
            currentOffset: offset.y,
            viewportLength: viewportSize.height,
            alignment: alignment
        )
        return Self.clamp(
            LayoutPoint(x: targetX, y: targetY),
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }

    private static func revealOffset(
        frameOrigin: Double,
        frameLength: Double,
        currentOffset: Double,
        viewportLength: Double,
        alignment: ScrollAlignment
    ) -> Double {
        switch alignment {
        case .start:
            return frameOrigin
        case .center:
            return frameOrigin + frameLength / 2 - viewportLength / 2
        case .end:
            return frameOrigin + frameLength - viewportLength
        case .nearest:
            let viewportStart = currentOffset
            let viewportEnd = currentOffset + viewportLength
            let frameEnd = frameOrigin + frameLength
            if frameOrigin < viewportStart { return frameOrigin }
            if frameEnd > viewportEnd { return frameEnd - viewportLength }
            return currentOffset
        }
    }
}

/// A programmatic scroll request (`r06-scroll-api-sketch.md` §7,
/// `scroll-configuration.md` §2.4). Issued through `ScrollCommandIssuing`, never directly on
/// `ScrollNode` — command issuance and completion bookkeeping live on the host bridge that owns
/// the node's native backing, not on the node itself (R07's ownership table).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ScrollCommand: Sendable, Hashable {
    /// Scrolls to an absolute content-space offset.
    case to(LayoutPoint, animated: Bool)
    /// Scrolls by a content-space delta from the current offset.
    case by(LayoutPoint, animated: Bool)
    /// Scrolls to make `frame` visible under `alignment`.
    case reveal(frame: LayoutFrame, alignment: ScrollAlignment, animated: Bool)
    /// Scrolls to an absolute offset with a Trellis `Animation` (duration and curve) instead of
    /// the platform's own programmatic animation, so other nodes animated with the same value
    /// move in step (R13's pager and tab indicator). `.none` jumps.
    case timed(LayoutPoint, animation: Animation)
}

/// Terminal result of one `ScrollCommand` (`r06-scroll-api-sketch.md` §7) — an explicit
/// callback instead of Weave's synchronous return, because native `animated: true` completes
/// later and user input can interrupt a command already in flight.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ScrollCommandOutcome: Sendable, Hashable {
    /// The command reached its target; carries the state at that moment.
    case completed(ScrollState)
    /// A later `scroll(_:on:completion:)` call for the same node replaced this one before it
    /// finished — delivered synchronously, at the moment the later command was issued.
    case supersededByLaterCommand
    /// The user began a gesture before this command finished, or the node was already mid-gesture
    /// when it was issued.
    case cancelledByUserInput
    /// Issued before the node's first commit, after `detach()`, or for a node with no native
    /// backing yet.
    case notAttached
}

/// Identifies one issued `ScrollCommand` — only the most recently issued token for a given node
/// can resolve `.completed` (§7).
///
/// Ownership: the caller holds this only to correlate it with the eventual outcome; nothing is
/// owned. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ScrollCommandToken: Sendable, Hashable {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: UInt64

    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(id: UInt64) {
        self.id = id
    }
}

/// Whether/how a `ScrollNode`'s native scroll indicators show (`scroll-configuration.md` §2.1).
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum ScrollIndicatorPolicy: Sendable, Hashable {
    /// System indicators, platform default — no indicators on tvOS (no system indicator
    /// concept there, `scroll-configuration.md` §3).
    case automatic
    case hidden
}

/// Overscroll/bounce policy (`scroll-configuration.md` §2.3). Deceleration/momentum itself is
/// deliberately not configurable — it is entirely native, §2.3's explicit boundary.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum ScrollBouncePolicy: Sendable, Hashable {
    /// `true` on iOS/iPadOS/macOS trackpad, `false` on tvOS.
    case automatic
    case always
    case never
}

/// iOS/iPadOS keyboard dismissal while scrolling (`scroll-configuration.md` §2.7). Ignored on
/// tvOS/macOS — no on-screen keyboard that overlaps content the same way.
///
/// Ownership: the value is owned by its caller. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum KeyboardDismissPolicy: Sendable, Hashable {
    case none
    case interactive
    case onDrag
}

/// Configuration shared by `ScrollNode` and, later, `ListNode`/`GridNode`/`TableNode`/
/// `TabbedScrollNode` (`scroll-configuration.md` §1/§2). `edgeLoad` is deliberately not a field
/// here yet — its concrete type belongs to whichever P6.7 card introduces pull-to-refresh/
/// load-more (R07's plan, "Files"; `scroll-configuration.md` §2.6/§6 open item).
///
/// Ownership: the value is owned by its caller — typically a `ScrollNode`. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public struct ScrollConfiguration: Sendable, Hashable {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var axis: ScrollAxis

    /// Whether native touch/trackpad/wheel input can move this node's offset. `false` still
    /// allows programmatic `ScrollCommand`s.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var userInteractionEnabled: Bool

    /// For `axis == .both`: whether the first movement's direction locks the gesture to one
    /// axis (`scroll-configuration.md` §2.1) — `false` keeps today's Weave-equivalent behavior
    /// (both directions at once).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var directionalLockEnabled: Bool

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var indicators: ScrollIndicatorPolicy

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var contentInsets: DirectionalEdgeInsets

    /// Whether safe-area insets are folded into `contentInsets` once (§2.2) — `false` opts out
    /// of the platform's own adaptive content-inset behavior entirely, not just Trellis's own
    /// addition, to avoid a double inset.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var insetsSafeArea: Bool

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var bounce: ScrollBouncePolicy

    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var keyboardDismissMode: KeyboardDismissPolicy

    /// Creates a configuration with the documented defaults (`scroll-configuration.md` §2).
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        axis: ScrollAxis = .vertical,
        userInteractionEnabled: Bool = true,
        directionalLockEnabled: Bool = false,
        indicators: ScrollIndicatorPolicy = .automatic,
        contentInsets: DirectionalEdgeInsets = DirectionalEdgeInsets(),
        insetsSafeArea: Bool = true,
        bounce: ScrollBouncePolicy = .automatic,
        keyboardDismissMode: KeyboardDismissPolicy = .none
    ) {
        self.axis = axis
        self.userInteractionEnabled = userInteractionEnabled
        self.directionalLockEnabled = directionalLockEnabled
        self.indicators = indicators
        self.contentInsets = contentInsets
        self.insetsSafeArea = insetsSafeArea
        self.bounce = bounce
        self.keyboardDismissMode = keyboardDismissMode
    }
}
