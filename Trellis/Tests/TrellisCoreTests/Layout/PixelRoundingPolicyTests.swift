import Testing

@testable import TrellisCore

@Test
func test_pixelRoundingPolicy_defaultsToScaleOne() {
    #expect(PixelRoundingPolicy().scale == 1)
}

@Test
func test_pixelRoundingPolicy_nonPositiveOrNonFiniteScaleNormalizesToOne() {
    #expect(PixelRoundingPolicy(scale: 0).scale == 1)
    #expect(PixelRoundingPolicy(scale: -2).scale == 1)
    #expect(PixelRoundingPolicy(scale: .nan).scale == 1)
    #expect(PixelRoundingPolicy(scale: .infinity).scale == 1)
}

@Test
func test_pixelRoundingPolicy_validScaleIsPreserved() {
    #expect(PixelRoundingPolicy(scale: 3).scale == 3)
}

@Test
func test_pixelRoundingPolicy_snapsToNearestPixelAtScale() {
    let policy = PixelRoundingPolicy(scale: 3)

    #expect(policy.snapped(10.1) == (10.1 * 3).rounded() / 3)
}

@Test
func test_pixelRoundingPolicy_scaleOneSnapsToWholeNumbers() {
    let policy = PixelRoundingPolicy(scale: 1)

    #expect(policy.snapped(10.4) == 10)
    #expect(policy.snapped(10.6) == 11)
}

@Test
func test_layoutFrame_roundedSnapsOriginAndSize() {
    let frame = LayoutFrame(origin: LayoutPoint(x: 10.1, y: 20.1), width: 30.1, height: 40.1)

    let rounded = frame.rounded(to: PixelRoundingPolicy(scale: 1))

    #expect(rounded == LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 30, height: 40))
}
