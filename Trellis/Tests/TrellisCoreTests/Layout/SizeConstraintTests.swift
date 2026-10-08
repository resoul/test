import Testing

@testable import TrellisCore

@Test
func test_sizeConstraintAxis_unspecifiedNormalizesToItself() {
    #expect(SizeConstraintAxis.unspecified.normalized() == .unspecified)
}

@Test
func test_sizeConstraintAxis_negativeAtMostBecomesUnspecified() {
    #expect(SizeConstraintAxis.atMost(-1).normalized() == .unspecified)
}

@Test
func test_sizeConstraintAxis_nonFiniteExactBecomesUnspecified() {
    #expect(SizeConstraintAxis.exact(.nan).normalized() == .unspecified)
    #expect(SizeConstraintAxis.exact(.infinity).normalized() == .unspecified)
}

@Test
func test_sizeConstraintAxis_validValuesArePreserved() {
    #expect(SizeConstraintAxis.atMost(120).normalized() == .atMost(120))
    #expect(SizeConstraintAxis.exact(44).normalized() == .exact(44))
}

@Test
func test_sizeConstraint_defaultsToUnspecifiedBothAxes() {
    let constraint = SizeConstraint()

    #expect(constraint.width == .unspecified)
    #expect(constraint.height == .unspecified)
}

@Test
func test_sizeConstraint_normalizesEachAxisIndependently() {
    let constraint = SizeConstraint(width: .exact(-5), height: .atMost(100))

    #expect(constraint.width == .unspecified)
    #expect(constraint.height == .atMost(100))
}
