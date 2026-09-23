import Foundation
import Testing

@testable import TrellisCore

// ADR 0009: an auto flex basis is the item's max-content size (measured with the main axis
// `.unspecified`), not its fit-content size under the parent's `.atMost` — and a node's own
// definite size, not the parent's offer, bounds what its children lay out in.

private func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: width, height: height)
}

private let unitPadding = DirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)

private func leaf(_ raw: UInt64, width: Double = 6, height: Double = 3) -> LayoutInputSnapshot {
    LayoutInputSnapshot(
        identity: flexID(raw),
        style: flexStyle(width: .points(width), height: .points(height))
    )
}

/// `depth` nested columns with 1 pt padding, four 6×3 leaves beside the next level and one
/// at the bottom — the `makeDeepTree` shape of the C31 harness, as snapshots.
private func chain(depth: Int, grow: Double, alternate: Bool = false) -> (LayoutInputSnapshot, Int)
{
    var next: UInt64 = 1
    func makeLevel(_ level: Int) -> (LayoutInputSnapshot, Int) {
        let identity = next
        next += 1
        var children: [LayoutInputSnapshot] = []
        var count = 1
        if level < depth {
            for _ in 0..<4 {
                children.append(leaf(next))
                next += 1
                count += 1
            }
            let (nested, nestedCount) = makeLevel(level + 1)
            children.append(nested)
            count += nestedCount
        } else {
            children.append(leaf(next))
            next += 1
            count += 1
        }
        let direction: FlexDirection = alternate && level % 2 == 1 ? .row : .column
        return (
            LayoutInputSnapshot(
                identity: flexID(identity),
                style: flexStyle(
                    flexDirection: direction,
                    flexGrow: level == 0 ? 0 : grow,
                    padding: unitPadding
                ),
                children: children
            ), count
        )
    }
    return makeLevel(0)
}

@Test
func test_basis_nestedGrowColumn_doesNotShrinkFixedSiblings() throws {
    // Column(200) { 4×Leaf(3); Column.grow { 4×Leaf(3); Column.grow { Leaf(3) } } }: with a
    // fit-content basis the middle column reported the whole 198 pt, its line overflowed by
    // the four leaves and shrank them to 2.83 pt (defect #25). Max-content: leaves stay 3,
    // the growing columns take exactly what is left.
    let inner = LayoutInputSnapshot(
        identity: flexID(30),
        style: flexStyle(flexDirection: .column, flexGrow: 1, padding: unitPadding),
        children: [leaf(31)]
    )
    let mid = LayoutInputSnapshot(
        identity: flexID(20),
        style: flexStyle(flexDirection: .column, flexGrow: 1, padding: unitPadding),
        children: [leaf(21), leaf(22), leaf(23), leaf(24), inner]
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column, padding: unitPadding),
        children: [leaf(2), leaf(3), leaf(4), leaf(5), mid]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 200)
    )

    #expect(result.placement(for: flexID(5))?.frame == frame(1, 10, 6, 3))
    #expect(result.placement(for: flexID(20))?.frame == frame(1, 13, 98, 186))
    #expect(result.placement(for: flexID(24))?.frame == frame(2, 23, 6, 3))
    #expect(result.placement(for: flexID(30))?.frame == frame(2, 26, 96, 172))
    #expect(result.placement(for: flexID(31))?.frame == frame(3, 27, 6, 3))
}

@Test
func test_basis_growingRowInsideRow_keepsFixedSiblingsAtTheirSize() throws {
    // The S19 progress bar: Row(320) { Leaf(28); Row.grow { Leaf.grow(3); Leaf.grow(7) }; Leaf(28) }
    // with a 10 pt gap. The pills are 28 and the track 244 — the reference rendered before
    // ADR 0009 had 22.3 pt pills and a 255 pt track (defect #25).
    let track = LayoutInputSnapshot(
        identity: flexID(3),
        style: flexStyle(flexGrow: 1, height: .points(4)),
        children: [
            LayoutInputSnapshot(identity: flexID(4), style: flexStyle(flexGrow: 3)),
            LayoutInputSnapshot(identity: flexID(5), style: flexStyle(flexGrow: 7)),
        ]
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(alignItems: .center, gap: 10),
        children: [leaf(2, width: 28, height: 8), track, leaf(6, width: 28, height: 8)]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 320, height: 20)
    )

    #expect(result.placement(for: flexID(2))?.frame.width == 28)
    #expect(result.placement(for: flexID(6))?.frame.width == 28)
    #expect(result.placement(for: flexID(3))?.frame == frame(38, 8, 244, 4))
    // 73.2 and 170.8, rounded to the 1× pixel grid.
    #expect(result.placement(for: flexID(4))?.frame.width == 73)
    #expect(result.placement(for: flexID(5))?.frame.width == 171)
}

@Test
func test_explicitMainSize_boundsWhatChildrenGrowInto() throws {
    // Column(200) { Column(height: 50) { Leaf.grow(1) } }: the leaf fills its parent's 50,
    // not the 200 the grandparent offered (defect #26).
    let mid = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexDirection: .column, height: .points(50)),
        children: [
            LayoutInputSnapshot(
                identity: flexID(3),
                style: flexStyle(flexGrow: 1, width: .points(6))
            )
        ]
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column),
        children: [mid]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 200)
    )

    #expect(result.placement(for: flexID(2))?.frame.height == 50)
    #expect(result.placement(for: flexID(3))?.frame == frame(0, 0, 6, 50))
}

@Test
func test_explicitMainSize_boundsWhatChildrenShrinkInto() throws {
    // Row(400) { Row(width: 100) { Leaf(80); Leaf(80) } }: the leaves shrink to the 100, not
    // to the 400 the grandparent offered.
    let mid = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(100)),
        children: [leaf(3, width: 80, height: 10), leaf(4, width: 80, height: 10)]
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [mid])

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 400, height: 30)
    )

    #expect(result.placement(for: flexID(3))?.frame.width == 50)
    #expect(result.placement(for: flexID(4))?.frame == frame(50, 0, 50, 10))
}

@Test
func test_fractionOnCrossAxis_resolvesAgainstParentSize() throws {
    // Row(200) { Leaf(40); Column.grow { Leaf(width: 50%) } }: the column is 160 wide, so the
    // leaf is 80 — it was 40, half of its own content-derived size (defect #28).
    let mid = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexDirection: .column, flexGrow: 1),
        children: [
            LayoutInputSnapshot(
                identity: flexID(3),
                style: flexStyle(width: .fraction(0.5), height: .points(10))
            )
        ]
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        children: [leaf(4, width: 40, height: 10), mid]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 200, height: 100)
    )

    #expect(result.placement(for: flexID(2))?.frame.width == 160)
    #expect(result.placement(for: flexID(3))?.frame == frame(40, 0, 80, 10))
}

@Test
func test_fractionBelowAnItemAtItsNaturalSize_resolvesAgainstTheFinalSize() throws {
    // Row(200) { Column { Leaf(width: 50%); Leaf(width: 100) } }: the column's max-content
    // width is 100 and it ends up exactly 100 wide, so the reuse of its max-content
    // measurement (ADR 0008) would carry the 50% leaf resolved against nothing — 0 wide.
    // `dependsOnAvailableSize` forces the `.exact` pass: the leaf is 50.
    let column = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexDirection: .column),
        children: [
            LayoutInputSnapshot(
                identity: flexID(3),
                style: flexStyle(width: .fraction(0.5), height: .points(10))
            ),
            leaf(4, width: 100, height: 10),
        ]
    )
    let root = LayoutInputSnapshot(identity: flexID(1), children: [column])

    var cache = FlexMeasureCache()
    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 200, height: 100),
        cache: &cache
    )

    #expect(result.placement(for: flexID(2))?.frame.width == 100)
    #expect(result.placement(for: flexID(3))?.frame.width == 50)
    let natural = cache.lookup(
        key: LayoutMeasureCacheKey(
            treeIdentity: flexID(2),
            contentRevision: column.contentRevision,
            environmentRevision: column.environmentRevision,
            constraint: SizeConstraint(width: .unspecified, height: .atMost(100)),
            direction: column.direction
        )
    )
    #expect(natural?.dependsOnAvailableSize == true)
    #expect(natural?.parentSize.width == 100)
}

@Test
func test_wrappingRowInsideColumn_wrapsAtTheColumnWidth() throws {
    // The cross axis of the column stays `.atMost`: a wrapping row in a 100 pt column breaks
    // its five 30 pt items into two lines, as before ADR 0009.
    let items = (10..<15).map { leaf(UInt64($0), width: 30, height: 10) }
    let row = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(flexWrap: .wrap),
        children: items
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(flexDirection: .column),
        children: [row]
    )

    let result = try FlexboxEngine.layoutContainer(
        input: root,
        frame: LayoutFrame(width: 100, height: 200)
    )

    #expect(result.placement(for: flexID(2))?.frame == frame(0, 0, 100, 20))
    #expect(result.placement(for: flexID(13))?.frame == frame(0, 10, 30, 10))
}

@Test
func test_overflowingChains_measureALinearNumberOfStates() throws {
    // Defect #24: a chain that shrinks (or grows) at every level measured 2^depth distinct
    // `(node, constraint)` states — depth 16 was 500k states, depth 300 never finished. With a
    // max-content basis each node is measured under at most three constraints: its basis,
    // its `.exact` main from the parent's line, and the placement frame. The solver is
    // recursive by level, so the pass runs on a thread with the scheduler's stack size
    // rather than the test runner's (defect #22).
    for (grow, height, alternate) in [
        (0.0, 285.0, false), (1.0, 1130.0, false), (0.0, 285.0, true),
    ] {
        let (root, count) = chain(depth: 40, grow: grow, alternate: alternate)
        let frame = LayoutFrame(width: 800, height: height)
        let stats = try solveOnLargeStack {
            var cache = FlexMeasureCache()
            _ = try FlexboxEngine.layoutContainer(input: root, frame: frame, cache: &cache)
            return cache.statistics
        }

        #expect(count == 202)
        #expect(stats.maxEntriesPerNode <= 5, "grow=\(grow) alternate=\(alternate): \(stats)")
        #expect(stats.entries <= 3 * count + 40, "grow=\(grow) alternate=\(alternate): \(stats)")
    }
}

private func solveOnLargeStack<Result: Sendable>(
    _ body: @escaping @Sendable () throws -> Result
) throws -> Result {
    let box = ResultBox<Result>()
    let thread = Thread {
        box.set(Swift.Result { try body() })
    }
    thread.stackSize = 16 << 20
    thread.start()
    return try box.wait().get()
}

private final class ResultBox<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Swift.Result<Value, any Error>?

    func set(_ result: Swift.Result<Value, any Error>) {
        value = result
        semaphore.signal()
    }

    func wait() -> Swift.Result<Value, any Error> {
        semaphore.wait()
        return value!
    }
}
