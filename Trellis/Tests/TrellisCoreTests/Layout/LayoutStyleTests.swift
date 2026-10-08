import Testing

@testable import TrellisCore

@Test
func test_layoutStyle_hasDocumentedDefaults() {
    let style = LayoutStyle()

    #expect(style.flexDirection == .row)
    #expect(style.flexWrap == .noWrap)
    #expect(style.justifyContent == .start)
    #expect(style.alignContent == .stretch)
    #expect(style.alignItems == .stretch)
    #expect(style.alignSelf == .auto)
    #expect(style.flexGrow == 0)
    #expect(style.flexShrink == 1)
    #expect(style.flexBasis == .auto)
    #expect(style.width == .auto)
    #expect(style.height == .auto)
    #expect(style.minWidth == .auto)
    #expect(style.maxWidth == .auto)
    #expect(style.minHeight == .auto)
    #expect(style.maxHeight == .auto)
    #expect(style.aspectRatio == nil)
    #expect(style.padding == DirectionalEdgeInsets())
    #expect(style.margin == DirectionalEdgeInsets())
    #expect(style.gap == 0)
    #expect(style.crossGap == 0)
    #expect(style.positionType == .relative)
    #expect(style.offsets == DirectionalEdgeOffsets())
    #expect(style.visual == LayoutVisualProperties())
}

@Test
func test_layoutStyle_mutationsNormalizeImmediately() {
    var style = LayoutStyle()

    style.flexGrow = -1
    style.flexShrink = .infinity
    style.gap = .nan
    style.crossGap = -8
    style.aspectRatio = 0

    #expect(style.flexGrow == 0)
    #expect(style.flexShrink == 0)
    #expect(style.gap == 0)
    #expect(style.crossGap == 0)
    #expect(style.aspectRatio == nil)

    style.aspectRatio = .infinity
    #expect(style.aspectRatio == nil)

    style.aspectRatio = 1.5
    #expect(style.aspectRatio == 1.5)
}

@Test
func test_layoutStyle_normalizationIsIdempotent() {
    var style = LayoutStyle()
    style.flexGrow = -.infinity
    style.flexShrink = -.nan
    style.gap = -4
    style.crossGap = .infinity
    style.aspectRatio = -.infinity

    let normalized = style
    style.flexGrow = -.infinity
    style.flexShrink = -.nan
    style.gap = -4
    style.crossGap = .infinity
    style.aspectRatio = -.infinity

    #expect(style == normalized)
}

@Test
func test_layoutStyle_directMutationPreservesUnchangedFields() {
    var style = LayoutStyle()
    style.width = 120
    style.height = .fraction(0.5)
    style.padding = DirectionalEdgeInsets(top: 4, leading: 8, bottom: 12, trailing: 16)

    #expect(style.width == .points(120))
    #expect(style.height == .fraction(0.5))
    #expect(style.flexDirection == .row)
    #expect(style.padding.leading == 8)
}

@Test
func test_layoutStyle_measuredUsesRatioLimitsAndConstraint() {
    var style = LayoutStyle()
    style.height = 40
    style.aspectRatio = 2
    style.minWidth = 100
    style.maxHeight = 30

    let measured = style.measured(constraint: SizeConstraint(width: .atMost(90)))

    #expect(measured == MeasuredSize(width: 90, height: 30))
}

@Test
func test_layoutVisualProperties_normalizesOpacity() {
    #expect(LayoutVisualProperties(opacity: -1).opacity == 0)
    #expect(LayoutVisualProperties(opacity: 2).opacity == 1)
    #expect(LayoutVisualProperties(opacity: .nan).opacity == 1)
}
