import Testing

@testable import TrellisCore

@Test
func test_layoutContentMetrics_defaultsToZeroSizeNoBaseline() {
    let metrics = LayoutContentMetrics()

    #expect(metrics.intrinsic == MeasuredSize(width: 0, height: 0))
    #expect(metrics.firstBaseline == nil)
}

@Test
func test_layoutContentMetrics_omittedBaselineStaysNilNotZero() {
    let metrics = LayoutContentMetrics(intrinsic: MeasuredSize(width: 10, height: 10))

    #expect(metrics.firstBaseline == nil)
}

@Test
func test_layoutContentMetrics_nonFiniteOrNegativeBaselineBecomesZero() {
    #expect(LayoutContentMetrics(firstBaseline: .nan).firstBaseline == 0)
    #expect(LayoutContentMetrics(firstBaseline: .infinity).firstBaseline == 0)
    #expect(LayoutContentMetrics(firstBaseline: -5).firstBaseline == 0)
}

@Test
func test_layoutContentMetrics_validBaselineIsPreserved() {
    #expect(LayoutContentMetrics(firstBaseline: 12).firstBaseline == 12)
}

@Test @MainActor
func test_layoutInputSnapshot_storesConstructorArguments() {
    let root = NodeIDAllocator.allocate()
    let child = LayoutInputSnapshot(identity: NodeIDAllocator.allocate(), style: LayoutStyle())
    let snapshot = LayoutInputSnapshot(
        identity: root,
        style: LayoutStyle(),
        content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 5, height: 5)),
        children: [child],
        direction: .rightToLeft,
        environmentRevision: 3,
        contentRevision: 7
    )

    #expect(snapshot.identity == root)
    #expect(snapshot.children == [child])
    #expect(snapshot.direction == .rightToLeft)
    #expect(snapshot.environmentRevision == 3)
    #expect(snapshot.contentRevision == 7)
}
