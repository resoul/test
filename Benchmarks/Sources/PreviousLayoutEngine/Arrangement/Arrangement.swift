/// Declarative description of a node's children (C21/C22), consumed by a resolver that does
/// not exist yet (C23).
///
/// This is a marker protocol with no requirements — a Swift protocol requirement is always at
/// least as visible as the protocol itself, so a requirement cannot return a non-public type
/// the way an earlier draft of this contract tried. Instead, the closed set C21 calls for is
/// enforced by `lower(_:)` below: it recognizes only `Leaf`/`Row`/`Column`/`Overlay`/
/// `ModifiedArrangement` by concrete type, and treats any other conformance — nothing stops one
/// from being declared, since this protocol has no requirements — as an inert empty container.
/// Conforming to `Arrangement` outside this file therefore compiles but does nothing; it is not
/// a supported extensibility surface, only a consequence of the marker protocol being public.
///
/// Ownership: conformers describe, but do not own, the `Node` values a description references.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public protocol Arrangement {}

/// Lowers any `Arrangement` value into the closed set a future resolver (C23) will walk.
///
/// An unrecognized conformance (anything other than the five types listed above) lowers to an
/// empty container rather than crashing — `Arrangement` has no requirements, so the type system
/// cannot rule this case out, and a builder scope silently contributing nothing is a safer
/// default than a runtime trap over declarative UI (`FORCE_OPERATION` also disallows
/// `fatalError` here). `Log.on(.arrange, "unrecognized", ...)` records the mismatch so it does
/// not fail silently in practice.
///
/// Ownership: returns a value; any `Node` reachable from `arrangement` is borrowed. Isolation:
/// MainActor. Errors: none. Cancellation: not applicable.
@MainActor
package func lower(_ arrangement: any Arrangement) -> ArrangementDescriptor {
    switch arrangement {
    case let leaf as Leaf:
        return ArrangementDescriptor(kind: .leaf(leaf.node))
    case let row as Row:
        return ArrangementDescriptor(kind: .row(row.container))
    case let column as Column:
        return ArrangementDescriptor(kind: .column(column.container))
    case let overlay as Overlay:
        return ArrangementDescriptor(kind: .overlay(overlay.container))
    case let modified as ModifiedArrangement:
        return modified.descriptor
    default:
        Log.on(.arrange, "unrecognized", "type=\(type(of: arrangement))")
        return ArrangementDescriptor(kind: .row(ArrangementContainer(items: [])))
    }
}

/// The closed set of shapes an `Arrangement` value lowers to (`package`: this is the private
/// vocabulary a future resolver, C23, will walk, not an API surface).
package struct ArrangementDescriptor {
    /// The concrete shape this descriptor lowers to.
    package enum Kind {
        case leaf(Node)
        case row(ArrangementContainer)
        case column(ArrangementContainer)
        case overlay(ArrangementContainer)
    }

    package var kind: Kind
    package var modifiers: ArrangementModifiers

    package init(kind: Kind, modifiers: ArrangementModifiers = ArrangementModifiers()) {
        self.kind = kind
        self.modifiers = modifiers
    }
}

/// Container configuration shared by `Row`, `Column`, and `Overlay` once lowered — `spacing`/
/// `justify`/`align` are inert for `Overlay` (C21: its items never join a flex line).
package struct ArrangementContainer {
    package var spacing: Double = 0
    package var justify: JustifyContent = .start
    package var align: AlignItems = .stretch
    package var padding: DirectionalEdgeInsets = DirectionalEdgeInsets()
    package var items: [ArrangementDescriptor]
}

/// Accumulated per-item modifier deltas (C22: grow/size/align/margin/offset). A future resolver
/// (C23) applies these on top of an item's own base style; nothing here is ever written back to
/// that base (D04) — a field left `nil` here means "unspecified," not zero.
package struct ArrangementModifiers: Sendable, Equatable {
    package var grow: Double?
    package var width: SizeValue?
    package var height: SizeValue?
    package var alignSelf: AlignSelf?
    package var margin: DirectionalEdgeInsets?
    package var offset: DirectionalEdgeOffsets?

    package init(
        grow: Double? = nil,
        width: SizeValue? = nil,
        height: SizeValue? = nil,
        alignSelf: AlignSelf? = nil,
        margin: DirectionalEdgeInsets? = nil,
        offset: DirectionalEdgeOffsets? = nil
    ) {
        self.grow = grow
        self.width = width
        self.height = height
        self.alignSelf = alignSelf
        self.margin = margin
        self.offset = offset
    }

    /// Layers `other`'s explicitly set fields on top of `self`, keeping `self`'s own value for
    /// any field `other` leaves unspecified. Chaining `.grow(1).grow(2)` therefore keeps `2`,
    /// not an accumulation — the same "later modifier wins" rule as everywhere else modifiers
    /// compose in this style system.
    package mutating func merge(overriding other: ArrangementModifiers) {
        if let grow = other.grow { self.grow = grow }
        if let width = other.width { self.width = width }
        if let height = other.height { self.height = height }
        if let alignSelf = other.alignSelf { self.alignSelf = alignSelf }
        if let margin = other.margin { self.margin = margin }
        if let offset = other.offset { self.offset = offset }
    }
}

/// What a parent owner's resolve decided about one node it placed as an item — a `Leaf` or an
/// implicit wrapper (C23). Only the explicitly written modifiers and the Overlay rule are
/// kept, never a computed style, so the node's effective style can always be re-derived from
/// its *current* base (D04) and combined with whatever the node's own `Arrangement` says about
/// its container fields (`ArrangementContainerStyle`).
package struct ArrangementPlacement: Sendable, Equatable {
    package var modifiers: ArrangementModifiers
    /// `true` for an item of an `Overlay` — laid out with `positionType == .absolute` (C21).
    package var isAbsolute: Bool

    package init(modifiers: ArrangementModifiers, isAbsolute: Bool) {
        self.modifiers = modifiers
        self.isAbsolute = isAbsolute
    }
}

/// What a node's own root `Row`/`Column`/`Overlay` decided about the node itself (C21: the
/// root container *is* self): the container fields, plus the modifiers written on that root
/// container. Held as source data rather than a computed style for the same reason as
/// `ArrangementPlacement`.
package struct ArrangementContainerStyle: Sendable, Equatable {
    package var flexDirection: FlexDirection
    package var gap: Double
    package var justifyContent: JustifyContent
    package var alignItems: AlignItems
    package var padding: DirectionalEdgeInsets
    package var modifiers: ArrangementModifiers

    package init(
        flexDirection: FlexDirection,
        gap: Double,
        justifyContent: JustifyContent,
        alignItems: AlignItems,
        padding: DirectionalEdgeInsets,
        modifiers: ArrangementModifiers
    ) {
        self.flexDirection = flexDirection
        self.gap = gap
        self.justifyContent = justifyContent
        self.alignItems = alignItems
        self.padding = padding
        self.modifiers = modifiers
    }
}

extension LayoutStyle {
    /// The one place `Arrangement` data is turned into a snapshot style (D04). Layered in a
    /// fixed order over `base` (the node's untouched `style`):
    ///
    /// 1. the node's own root container — its container fields (`flexDirection`, `gap`,
    ///    `justifyContent`, `alignItems`, `padding`) always replace the base's, then the
    ///    modifiers written on that root container;
    /// 2. the placement its parent owner gave it — the item's modifiers, then `.absolute` for
    ///    an `Overlay` item.
    ///
    /// The parent's placement is layered last on purpose: an owner controls where its items
    /// go, exactly as it overrides an item's base `style`. Returns `nil` when neither owner
    /// has anything to say, so the snapshot falls back to the raw base.
    package static func arrangementEffective(
        base: LayoutStyle,
        container: ArrangementContainerStyle?,
        placement: ArrangementPlacement?
    ) -> LayoutStyle? {
        guard container != nil || placement != nil else { return nil }
        var style = base
        if let container {
            style.flexDirection = container.flexDirection
            style.gap = container.gap
            style.justifyContent = container.justifyContent
            style.alignItems = container.alignItems
            style.padding = container.padding
            style.apply(container.modifiers)
        }
        if let placement {
            style.apply(placement.modifiers)
            if placement.isAbsolute { style.positionType = .absolute }
        }
        return style
    }

    private mutating func apply(_ modifiers: ArrangementModifiers) {
        if let grow = modifiers.grow { flexGrow = grow }
        if let width = modifiers.width { self.width = width }
        if let height = modifiers.height { self.height = height }
        if let alignSelf = modifiers.alignSelf { self.alignSelf = alignSelf }
        if let margin = modifiers.margin { self.margin = margin }
        if let offset = modifiers.offset { offsets = offset }
    }
}
