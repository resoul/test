import LayoutCore

/// How a node comes onto the screen and leaves it in an animated change: when it joins a
/// tree already shown or leaves it (an `if` in `layoutSpec()`, a `Breakpoint` switching
/// sides), and when it is hidden or shown again. A node without one fades.
///
///     badge.transition = .scale.combined(with: .opacity)
///     toast.transition = .move(edge: .bottom)
///     page.transition = .asymmetric(insertion: .push(from: .trailing), removal: .opacity)
///
/// A transition only says where the node is while away; the change's animation — or the
/// transition's own, `animation(_:)` — moves it. Without an animation it comes and goes at
/// once.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Transition: Sendable, Hashable {
    /// A side of the node's box; leading and trailing follow the layout direction.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Edge: Sendable, Hashable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case top
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case bottom
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case leading
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case trailing

        /// The side across from this one.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var opposite: Edge {
            switch self {
            case .top: .bottom
            case .bottom: .top
            case .leading: .trailing
            case .trailing: .leading
            }
        }
    }

    /// A point of the node's box as fractions of its size: (0, 0) the top leading corner,
    /// (1, 1) the bottom trailing one.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct Anchor: Sendable, Hashable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var x: Double
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var y: Double

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let center = Anchor(x: 0.5, y: 0.5)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let top = Anchor(x: 0.5, y: 0)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let bottom = Anchor(x: 0.5, y: 1)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let leading = Anchor(x: 0, y: 0.5)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let trailing = Anchor(x: 1, y: 0.5)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let topLeading = Anchor(x: 0, y: 0)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let topTrailing = Anchor(x: 1, y: 0)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let bottomLeading = Anchor(x: 0, y: 1)
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let bottomTrailing = Anchor(x: 1, y: 1)
    }

    /// Where and how the node is while away from the screen: it comes in from this and goes
    /// out to it. The identity effect changes nothing.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct Effect: Sendable, Hashable {
        /// Its opacity times this.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var opacity: Double
        /// Its size times this, across and down, about `anchor`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var scaleX: Double
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var scaleY: Double
        /// Degrees it is turned by, clockwise on the screen, about `anchor`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var rotation: Double
        /// Degrees it is turned by about the horizontal line through `anchor` — its top
        /// tipping away — and about the vertical one — its trailing side tipping away — seen
        /// in perspective. At 90 it is edge on, and does not show.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var flipX: Double
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var flipY: Double
        /// Points it is moved by: `x` toward the trailing side, `y` down.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var offset: LayoutPoint
        /// How far it is moved in its own size: 1 across moves it by its width toward the
        /// trailing side, 1 down by its height.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var sizeOffset: LayoutPoint
        /// The point of the box it is scaled and turned about.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var anchor: Anchor

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(
            opacity: Double = 1,
            scaleX: Double = 1,
            scaleY: Double = 1,
            rotation: Double = 0,
            flipX: Double = 0,
            flipY: Double = 0,
            offset: LayoutPoint = LayoutPoint(x: 0, y: 0),
            sizeOffset: LayoutPoint = LayoutPoint(x: 0, y: 0),
            anchor: Anchor = .center
        ) {
            self.opacity = opacity
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.rotation = rotation
            self.flipX = flipX
            self.flipY = flipY
            self.offset = offset
            self.sizeOffset = sizeOffset
            self.anchor = anchor
        }

        /// No change.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let identity = Effect()

        /// Whether it changes nothing about how the node looks.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var isIdentity: Bool {
            opacity == 1 && !changesGeometry
        }

        /// Whether it moves, scales or turns the node.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var changesGeometry: Bool {
            scaleX != 1 || scaleY != 1 || rotation != 0 || flipX != 0 || flipY != 0
                || offset != LayoutPoint(x: 0, y: 0)
                || sizeOffset != LayoutPoint(x: 0, y: 0)
        }

        /// Both at once: opacities and scales multiply, turns and moves add up. The anchor
        /// is this one's, unless it is the center.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public func combined(with other: Effect) -> Effect {
            Effect(
                opacity: opacity * other.opacity,
                scaleX: scaleX * other.scaleX,
                scaleY: scaleY * other.scaleY,
                rotation: rotation + other.rotation,
                flipX: flipX + other.flipX,
                flipY: flipY + other.flipY,
                offset: LayoutPoint(
                    x: offset.x + other.offset.x,
                    y: offset.y + other.offset.y
                ),
                sizeOffset: LayoutPoint(
                    x: sizeOffset.x + other.sizeOffset.x,
                    y: sizeOffset.y + other.sizeOffset.y
                ),
                anchor: anchor == .center ? other.anchor : anchor
            )
        }
    }

    /// Where the node comes in from.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var insertion: Effect
    /// Where the node goes out to.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var removal: Effect
    /// The animation the node comes and goes with instead of the change's; `nil` takes the
    /// change's. Either way, a change made without an animation shows at once.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var animation: Animation?

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(insertion: Effect, removal: Effect, animation: Animation? = nil) {
        self.insertion = insertion
        self.removal = removal
        self.animation = animation
    }

    /// The same way in and out.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(_ effect: Effect) {
        self.init(insertion: effect, removal: effect)
    }

    // MARK: - Transitions

    /// Comes and goes at once, even in an animated change.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let identity = Transition(.identity)

    /// Fades in and out; what a node does without a transition.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let opacity = Transition(Effect(opacity: 0))

    /// Grows from nothing and shrinks to nothing, about its center.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let scale = scale(0)

    /// Grows from `scale` times its size and shrinks to it, about `anchor`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func scale(_ scale: Double, anchor: Anchor = .center) -> Transition {
        Transition(Effect(scaleX: scale, scaleY: scale, anchor: anchor))
    }

    /// Slides in from `edge`, by its own size, and out toward it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func move(edge: Edge) -> Transition {
        Transition(Effect(sizeOffset: sizeOffset(toward: edge)))
    }

    /// Comes in from `x` points toward the trailing side and `y` down, and goes out there.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func offset(x: Double = 0, y: Double = 0) -> Transition {
        Transition(Effect(offset: LayoutPoint(x: x, y: y)))
    }

    /// Slides in from the leading side and out toward the trailing one.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let slide = asymmetric(
        insertion: .move(edge: .leading),
        removal: .move(edge: .trailing)
    )

    /// Slides and fades in from `edge` and out toward the one across, as a page pushed onto
    /// a stack: the next one comes from the same side and pushes it on.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func push(from edge: Edge) -> Transition {
        Transition(
            insertion: Effect(opacity: 0, sizeOffset: sizeOffset(toward: edge)),
            removal: Effect(opacity: 0, sizeOffset: sizeOffset(toward: edge.opposite))
        )
    }

    /// Turns in from `degrees`, clockwise, about `anchor`, and back out.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func rotation(degrees: Double, anchor: Anchor = .center) -> Transition {
        Transition(Effect(opacity: 0, rotation: degrees, anchor: anchor))
    }

    /// Turns in from edge on, as a card flipped over, about the line through its center
    /// across `axis` — `.horizontal` tips it over its top, `.vertical` over its side — and
    /// out the same way.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func flip(_ axis: Axis = .vertical) -> Transition {
        switch axis {
        case .horizontal: Transition(Effect(flipX: 90))
        case .vertical: Transition(Effect(flipY: 90))
        }
    }

    /// Pops in from a little smaller with a springy bounce and fades out shrinking.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let pop = Transition(
        insertion: Effect(opacity: 0, scaleX: 0.6, scaleY: 0.6),
        removal: Effect(opacity: 0, scaleX: 0.8, scaleY: 0.8),
        animation: .spring(response: 0.4, dampingRatio: 0.6)
    )

    /// Comes in the way `insertion` does and goes out the way `removal` does.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func asymmetric(insertion: Transition, removal: Transition) -> Transition {
        Transition(
            insertion: insertion.insertion,
            removal: removal.removal,
            animation: insertion.animation ?? removal.animation
        )
    }

    /// Both at once, in and out; see `Effect.combined(with:)`. The animation is this one's,
    /// else `other`'s.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func combined(with other: Transition) -> Transition {
        Transition(
            insertion: insertion.combined(with: other.insertion),
            removal: removal.combined(with: other.removal),
            animation: animation ?? other.animation
        )
    }

    /// The same, moving with `animation` instead of the change's.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func animation(_ animation: Animation?) -> Transition {
        var result = self
        result.animation = animation
        return result
    }

    /// A direction across the node, for `flip(_:)`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Axis: Sendable, Hashable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case horizontal
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case vertical
    }

    private static func sizeOffset(toward edge: Edge) -> LayoutPoint {
        switch edge {
        case .top: LayoutPoint(x: 0, y: -1)
        case .bottom: LayoutPoint(x: 0, y: 1)
        case .leading: LayoutPoint(x: -1, y: 0)
        case .trailing: LayoutPoint(x: 1, y: 0)
        }
    }
}
