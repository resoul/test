import Testing

@testable import TrellisCore

@Test
func test_layoutPoint_nonFiniteCoordinatesBecomeZero() {
    let point = LayoutPoint(x: .nan, y: .infinity)

    #expect(point.x == 0)
    #expect(point.y == 0)
}

@Test
func test_layoutPoint_finiteCoordinatesArePreserved() {
    let point = LayoutPoint(x: -12.5, y: 40)

    #expect(point.x == -12.5)
    #expect(point.y == 40)
}

@Test
func test_measuredSize_negativeDimensionsClampToZero() {
    let size = MeasuredSize(width: -10, height: -1)

    #expect(size.width == 0)
    #expect(size.height == 0)
}

@Test
func test_measuredSize_nonFiniteDimensionsBecomeZero() {
    let size = MeasuredSize(width: .nan, height: .infinity)

    #expect(size.width == 0)
    #expect(size.height == 0)
}

@Test
func test_measuredSize_finiteNonNegativeDimensionsArePreserved() {
    let size = MeasuredSize(width: 120, height: 44)

    #expect(size.width == 120)
    #expect(size.height == 44)
}

@Test
func test_layoutFrame_negativeAndNonFiniteDimensionsClampToZero() {
    let frame = LayoutFrame(width: -5, height: .nan)

    #expect(frame.width == 0)
    #expect(frame.height == 0)
}

@Test
func test_layoutFrame_defaultOriginIsZero() {
    let frame = LayoutFrame(width: 10, height: 10)

    #expect(frame.origin == LayoutPoint(x: 0, y: 0))
}
