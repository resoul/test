@testable import TrellisCore

/// Builds a `LayoutStyle` from named fields in one call, for ports of Weave's flex regression
/// suite (Weave's `LayoutStyle` had an all-fields initializer; Trellis's has only `init()` plus
/// direct mutation — `node.style.width = 100` is the real product API, but a test fixture with
/// twenty fields reads far better built in one expression than assembled field-by-field).
func flexStyle(
    flexDirection: FlexDirection = .row,
    flexWrap: FlexWrap = .noWrap,
    justifyContent: JustifyContent = .start,
    alignContent: AlignContent = .stretch,
    alignItems: AlignItems = .stretch,
    alignSelf: AlignSelf = .auto,
    flexGrow: Double = 0,
    flexShrink: Double = 1,
    flexBasis: SizeValue = .auto,
    width: SizeValue = .auto,
    height: SizeValue = .auto,
    minWidth: SizeValue = .auto,
    maxWidth: SizeValue = .auto,
    minHeight: SizeValue = .auto,
    maxHeight: SizeValue = .auto,
    aspectRatio: Double? = nil,
    padding: DirectionalEdgeInsets = DirectionalEdgeInsets(),
    margin: DirectionalEdgeInsets = DirectionalEdgeInsets(),
    gap: Double = 0,
    crossGap: Double = 0,
    positionType: PositionType = .relative,
    offsets: DirectionalEdgeOffsets = DirectionalEdgeOffsets()
) -> LayoutStyle {
    var style = LayoutStyle()
    style.flexDirection = flexDirection
    style.flexWrap = flexWrap
    style.justifyContent = justifyContent
    style.alignContent = alignContent
    style.alignItems = alignItems
    style.alignSelf = alignSelf
    style.flexGrow = flexGrow
    style.flexShrink = flexShrink
    style.flexBasis = flexBasis
    style.width = width
    style.height = height
    style.minWidth = minWidth
    style.maxWidth = maxWidth
    style.minHeight = minHeight
    style.maxHeight = maxHeight
    style.aspectRatio = aspectRatio
    style.padding = padding
    style.margin = margin
    style.gap = gap
    style.crossGap = crossGap
    style.positionType = positionType
    style.offsets = offsets
    return style
}

/// Constructs a fixture `NodeID` from a small integer, for readable ported test snapshots.
/// `NodeID.init(rawValue:)` is internal-only by design (D02) — externally, identities are
/// issued only by `NodeIDAllocator` — so this helper needs `@testable import TrellisCore`.
func flexID(_ raw: UInt64) -> NodeID {
    NodeID(rawValue: raw)
}
