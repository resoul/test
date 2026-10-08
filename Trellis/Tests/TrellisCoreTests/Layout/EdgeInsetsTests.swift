import Testing

@testable import TrellisCore

@Test
func test_directionalEdgeInsets_negativeAndNonFiniteClampToZero() {
    let insets = DirectionalEdgeInsets(top: -1, leading: .nan, bottom: .infinity, trailing: 5)

    #expect(insets.top == 0)
    #expect(insets.leading == 0)
    #expect(insets.bottom == 0)
    #expect(insets.trailing == 5)
}

@Test
func test_directionalEdgeInsets_leftToRightMapsLeadingToLeft() {
    let insets = DirectionalEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)

    let resolved = insets.resolved(for: .leftToRight)

    #expect(resolved == PhysicalEdgeInsets(top: 1, left: 2, bottom: 3, right: 4))
}

@Test
func test_directionalEdgeInsets_rightToLeftSwapsLeadingAndTrailing() {
    let insets = DirectionalEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)

    let resolved = insets.resolved(for: .rightToLeft)

    #expect(resolved == PhysicalEdgeInsets(top: 1, left: 4, bottom: 3, right: 2))
}

@Test
func test_physicalEdgeInsets_negativeAndNonFiniteClampToZero() {
    let insets = PhysicalEdgeInsets(top: -1, left: .nan, bottom: .infinity, right: 5)

    #expect(insets.top == 0)
    #expect(insets.left == 0)
    #expect(insets.bottom == 0)
    #expect(insets.right == 5)
}

@Test
func test_directionalEdgeOffsets_nonFiniteBecomesNilNotZero() {
    let offsets = DirectionalEdgeOffsets(top: .nan, leading: 10)

    #expect(offsets.top == nil)
    #expect(offsets.leading == 10)
    #expect(offsets.bottom == nil)
    #expect(offsets.trailing == nil)
}

@Test
func test_directionalEdgeOffsets_unsetEdgeStaysNilThroughResolution() {
    let offsets = DirectionalEdgeOffsets(top: 8)

    let resolved = offsets.resolved(for: .leftToRight)

    #expect(resolved.top == 8)
    #expect(resolved.left == nil)
    #expect(resolved.bottom == nil)
    #expect(resolved.right == nil)
}

@Test
func test_directionalEdgeOffsets_rightToLeftSwapsLeadingAndTrailing() {
    let offsets = DirectionalEdgeOffsets(leading: 2, trailing: 4)

    let resolved = offsets.resolved(for: .rightToLeft)

    #expect(resolved.left == 4)
    #expect(resolved.right == 2)
}
