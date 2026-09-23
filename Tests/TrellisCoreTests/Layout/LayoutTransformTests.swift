import Testing

@testable import TrellisCore

@Test
func test_layoutTransform_nonFiniteComponentsUseIdentityFallbacks() {
    let transform = LayoutTransform(
        scaleX: .nan,
        scaleY: .infinity,
        rotationRadians: -.infinity,
        translationX: .nan,
        translationY: .infinity
    )

    #expect(transform == .identity)
}

@Test
func test_layoutTransform_inverseApplyingReversesTranslationAndScale() {
    let transform = LayoutTransform(scaleX: 2, scaleY: 4, translationX: 10, translationY: 20)

    let result = transform.inverseApplying(
        LayoutPoint(x: 30, y: 60),
        around: LayoutPoint(x: 0, y: 0)
    )

    #expect(result == LayoutPoint(x: 10, y: 10))
}

@Test
func test_layoutTransform_rotationPivotsAroundFrameCenter() {
    // Defect #30 / D17: the pivot is the frame center, not its origin. A quarter-turn
    // clockwise around (60, 45) sends the top-left corner to the top-right side.
    let frame = LayoutFrame(origin: LayoutPoint(x: 10, y: 20), width: 100, height: 50)
    let transform = LayoutTransform(rotationRadians: .pi / 2)

    let corner = transform.applying(frame.origin, in: frame)

    #expect(abs(corner.x - 85) < 1e-9)
    #expect(abs(corner.y - -5) < 1e-9)
    let back = transform.inverseApplying(corner, in: frame)
    #expect(abs(back.x - frame.origin.x) < 1e-9)
    #expect(abs(back.y - frame.origin.y) < 1e-9)
}

@Test
func test_layoutTransform_nonUniformScalePivotsAroundFrameCenter() {
    let frame = LayoutFrame(width: 100, height: 50)
    let transform = LayoutTransform(scaleX: 2, scaleY: 0.5)
    let bottomRight = LayoutPoint(x: 100, y: 50)

    let scaled = transform.applying(bottomRight, in: frame)

    #expect(scaled == LayoutPoint(x: 150, y: 37.5))
    #expect(transform.inverseApplying(scaled, in: frame) == bottomRight)
    // The center itself never moves under scale or rotation.
    #expect(transform.applying(LayoutPoint(x: 50, y: 25), in: frame) == LayoutPoint(x: 50, y: 25))
}

@Test
func test_layoutTransform_inverseApplyingRoundTripsScaleRotationAndTranslation() {
    let frame = LayoutFrame(origin: LayoutPoint(x: 30, y: 40), width: 100, height: 50)
    let transform = LayoutTransform(
        scaleX: 2,
        scaleY: 0.5,
        rotationRadians: .pi / 3,
        translationX: 7,
        translationY: -3
    )
    let points = [
        LayoutPoint(x: 30, y: 40),
        LayoutPoint(x: 130, y: 90),
        LayoutPoint(x: 67, y: 51),
        LayoutPoint(x: 80, y: 65),
    ]

    for point in points {
        let back = transform.inverseApplying(transform.applying(point, in: frame), in: frame)
        #expect(abs(back.x - point.x) < 1e-9)
        #expect(abs(back.y - point.y) < 1e-9)
    }
}
