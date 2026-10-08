import Testing

@testable import TrellisCore

@Test
func test_sizeValue_finitePointsResolveDirectly() {
    #expect(SizeValue.points(120).resolved(parent: nil) == 120)
}

@Test
func test_sizeValue_negativePointsAreInvalid() {
    #expect(SizeValue.points(-1).resolved(parent: nil) == nil)
}

@Test
func test_sizeValue_nonFinitePointsAreInvalid() {
    #expect(SizeValue.points(.nan).resolved(parent: nil) == nil)
    #expect(SizeValue.points(.infinity).resolved(parent: nil) == nil)
}

@Test
func test_sizeValue_fractionWithoutParentIsUnspecifiedNotZero() {
    #expect(SizeValue.fraction(0.5).resolved(parent: nil) == nil)
}

@Test
func test_sizeValue_fractionResolvesAgainstAKnownParent() {
    #expect(SizeValue.fraction(0.5).resolved(parent: 200) == 100)
}

@Test
func test_sizeValue_fractionOutOfUnitRangeIsInvalid() {
    #expect(SizeValue.fraction(-0.1).resolved(parent: 200) == nil)
    #expect(SizeValue.fraction(1.1).resolved(parent: 200) == nil)
}

@Test
func test_sizeValue_fractionWithNonFiniteParentIsInvalid() {
    #expect(SizeValue.fraction(0.5).resolved(parent: .infinity) == nil)
}

@Test
func test_sizeValue_autoAlwaysResolvesToNil() {
    #expect(SizeValue.auto.resolved(parent: nil) == nil)
    #expect(SizeValue.auto.resolved(parent: 200) == nil)
}

@Test
func test_sizeValue_numericLiteralsMeanPoints() {
    let integer: SizeValue = 12
    let floatingPoint: SizeValue = 12.5

    #expect(integer == .points(12))
    #expect(floatingPoint == .points(12.5))
    #expect(SizeValue.fraction(0.5) == .fraction(0.5))
}
