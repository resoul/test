import Testing

@testable import TrellisCore

// Case numbers refer to docs/validation/h01-contract.md §1. Root `R` is always
// (0, 0, 400, 400); every frame is committed absolute.

private let rootFrame = LayoutFrame(width: 400, height: 400)

private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: w, height: h)
}

private func p(_ x: Double, _ y: Double) -> LayoutPoint { LayoutPoint(x: x, y: y) }

/// A committed tree built without a layout pass: frames are assigned directly, the snapshot is
/// taken as the bridge would take it at commit.
@MainActor
private struct Tree {
    let root = Node()
    private var frames: [(Node, LayoutFrame)]

    init() { frames = [(root, rootFrame)] }

    @discardableResult
    mutating func add(
        _ frame: LayoutFrame,
        to parent: Node? = nil,
        visual: LayoutVisualProperties = LayoutVisualProperties(),
        wrapper: Bool = false
    ) -> Node {
        let node = Node()
        node.style.visual = visual
        node.isArrangementWrapper = wrapper
        (parent ?? root).addSubnode(node)
        frames.append((node, frame))
        return node
    }

    func snapshot() throws -> HitTestSnapshot {
        let result = LayoutResult(
            placements: frames.map { LayoutPlacement(identity: $0.0.id, frame: $0.1) },
            treeIdentity: root.id
        )
        #expect(root.applyLayoutResult(result))
        return try #require(HitTestSnapshot(root: root, mountEpoch: 1, bounds: rootFrame))
    }
}

@Test
@MainActor
func test_hitTest_ordinaryNodeRootFallbackAndOutsideRoot() throws {
    var tree = Tree()
    let a = tree.add(frame(10, 10, 100, 100))
    let snapshot = try tree.snapshot()

    #expect(snapshot.hitTest(p(50, 50)) == a.id)  // 1
    #expect(snapshot.hitTest(p(200, 200)) == tree.root.id)  // 2
    #expect(snapshot.hitTest(p(-1, 50)) == nil)  // 3
    #expect(snapshot.hitTest(p(400, 50)) == nil)  // 3: half-open, 400 is outside
    #expect(snapshot.hitTest(p(0, 0)) == tree.root.id)  // min edge is inside
}

@Test
@MainActor
func test_hitTest_arrangementWrapperIsTransparent() throws {
    var tree = Tree()
    let emptyWrapper = tree.add(frame(10, 10, 100, 100), wrapper: true)
    let snapshot = try tree.snapshot()
    #expect(snapshot.hitTest(p(50, 50)) == tree.root.id)  // 4
    #expect(snapshot.hitTest(p(50, 50)) != emptyWrapper.id)

    var covering = Tree()
    let wrapper = covering.add(frame(0, 0, 400, 400), wrapper: true)
    let inside = covering.add(frame(10, 10, 100, 100), to: wrapper)
    let coveringSnapshot = try covering.snapshot()
    #expect(coveringSnapshot.hitTest(p(50, 50)) == inside.id)  // 5
    // 5: past the wrapper to its owner
    #expect(coveringSnapshot.hitTest(p(300, 300)) == covering.root.id)
}

@Test
@MainActor
func test_hitTest_equalZIndexLastSiblingWinsAndZIndexOrdersSiblingsOnly() throws {
    var tree = Tree()
    let a = tree.add(frame(0, 0, 100, 100))
    let b = tree.add(frame(0, 0, 100, 100))
    #expect(try tree.snapshot().hitTest(p(50, 50)) == b.id)  // 10

    a.style.visual = LayoutVisualProperties(zIndex: 1)
    #expect(try tree.snapshot().hitTest(p(50, 50)) == a.id)  // 11

    var nested = Tree()
    let parent = nested.add(frame(0, 0, 200, 200))
    let deep = nested.add(
        frame(0, 0, 100, 100),
        to: parent,
        visual: LayoutVisualProperties(zIndex: 100)
    )
    let later = nested.add(frame(0, 0, 100, 100))
    let snapshot = try nested.snapshot()
    // 12: `deep` never jumps over its parent's sibling
    #expect(snapshot.hitTest(p(50, 50)) == later.id)
    #expect(snapshot.hitTest(p(150, 150)) == parent.id)
    #expect(snapshot.hitTest(p(50, 50)) != deep.id)
}

@Test
@MainActor
func test_hitTest_halfOpenBoundsSharedEdgeAndZeroSize() throws {
    var tree = Tree()
    let a = tree.add(frame(0, 0, 100, 100))
    let b = tree.add(frame(100, 0, 100, 100))
    let empty = tree.add(frame(10, 10, 0, 0))
    let snapshot = try tree.snapshot()

    #expect(snapshot.hitTest(p(100, 50)) == b.id)  // 13
    #expect(snapshot.hitTest(p(99.999, 50)) == a.id)
    #expect(snapshot.hitTest(p(10, 10)) == a.id)  // 14: zero-sized `empty` is never hit
    #expect(snapshot.hitTest(p(10, 10)) != empty.id)
}

@Test
@MainActor
func test_hitTest_overflowVisibleKeepsChildOutsideParentHittableHiddenClips() throws {
    var visible = Tree()
    let parent = visible.add(frame(0, 0, 100, 100))
    let child = visible.add(frame(150, 150, 50, 50), to: parent)
    #expect(try visible.snapshot().hitTest(p(160, 160)) == child.id)  // 15

    parent.style.visual = LayoutVisualProperties(overflow: .hidden)
    #expect(try visible.snapshot().hitTest(p(160, 160)) == visible.root.id)  // 16

    var clipping = Tree()
    let clipper = clipping.add(
        frame(0, 0, 100, 100),
        visual: LayoutVisualProperties(overflow: .hidden)
    )
    let overflowing = clipping.add(frame(50, 50, 100, 100), to: clipper)
    let snapshot = try clipping.snapshot()
    #expect(snapshot.hitTest(p(75, 75)) == overflowing.id)  // 17
    #expect(snapshot.hitTest(p(125, 125)) == clipping.root.id)  // 17

    clipper.style.visual = LayoutVisualProperties(overflow: .scroll)
    #expect(try clipping.snapshot().hitTest(p(125, 125)) == clipping.root.id)  // .scroll clips too
}

@Test
@MainActor
func test_hitTest_opacityZeroHidesSubtreeAnyOtherOpacityDoesNot() throws {
    var tree = Tree()
    let parent = tree.add(frame(0, 0, 200, 200), visual: LayoutVisualProperties(opacity: 0))
    let child = tree.add(frame(10, 10, 50, 50), to: parent)
    #expect(try tree.snapshot().hitTest(p(20, 20)) == tree.root.id)  // 18

    parent.style.visual = LayoutVisualProperties(opacity: 0.01)
    #expect(try tree.snapshot().hitTest(p(20, 20)) == child.id)  // 19

    var hiddenRoot = Tree()
    hiddenRoot.root.style.visual = LayoutVisualProperties(opacity: 0)
    hiddenRoot.add(frame(0, 0, 400, 400))
    // root at opacity 0: nothing on screen
    #expect(try hiddenRoot.snapshot().hitTest(p(20, 20)) == nil)
}

@Test
@MainActor
func test_hitTest_rotatedNodeIsHitWhereDrawnNotByOriginalFrame() throws {
    var tree = Tree()
    // 20: center (160, 145); the drawn rectangle covers x∈[135,185], y∈[95,195].
    let a = tree.add(
        frame(110, 120, 100, 50),
        visual: LayoutVisualProperties(transform: LayoutTransform(rotationRadians: .pi / 2))
    )
    let snapshot = try tree.snapshot()
    #expect(snapshot.hitTest(p(184, 96)) == a.id)  // outside the original AABB in y
    // inside the original AABB, outside the image
    #expect(snapshot.hitTest(p(112, 122)) == tree.root.id)

    var second = Tree()
    let b = second.add(
        frame(100, 100, 100, 50),
        visual: LayoutVisualProperties(transform: LayoutTransform(rotationRadians: .pi / 2))
    )
    let secondSnapshot = try second.snapshot()
    #expect(secondSnapshot.hitTest(p(150, 125)) == b.id)  // 21: the center never moves
    #expect(secondSnapshot.hitTest(p(175, 80)) == b.id)  // 21
    #expect(secondSnapshot.hitTest(p(105, 105)) == second.root.id)  // 22
}

@Test
@MainActor
func test_hitTest_parentTransformMovesChildrenAndComposes() throws {
    var translated = Tree()
    let parent = translated.add(
        frame(100, 100, 200, 100),
        visual: LayoutVisualProperties(transform: LayoutTransform(translationX: 50))
    )
    let child = translated.add(frame(100, 100, 50, 50), to: parent)
    let snapshot = try translated.snapshot()
    #expect(snapshot.hitTest(p(175, 125)) == child.id)  // 23
    #expect(snapshot.hitTest(p(125, 125)) == translated.root.id)  // 23: the original spot is empty

    var rotated = Tree()
    let pivot = rotated.add(
        frame(100, 100, 200, 100),
        visual: LayoutVisualProperties(transform: LayoutTransform(rotationRadians: .pi / 2))
    )
    let deep = rotated.add(frame(100, 100, 50, 50), to: pivot)
    let rotatedSnapshot = try rotated.snapshot()
    #expect(rotatedSnapshot.hitTest(p(225, 75)) == deep.id)  // 24: image of the child's center
    #expect(rotatedSnapshot.hitTest(p(125, 125)) != deep.id)

    // Child transform composes with the parent's: the child's own pivot is its frame center in
    // the parent's local space. Rotate the child by −π/2 inside the +π/2 parent → the child's
    // image is axis-aligned again around the image of its center.
    var composed = Tree()
    let outer = composed.add(
        frame(100, 100, 200, 100),
        visual: LayoutVisualProperties(transform: LayoutTransform(rotationRadians: .pi / 2))
    )
    let inner = composed.add(
        frame(100, 100, 50, 20),
        to: outer,
        visual: LayoutVisualProperties(transform: LayoutTransform(rotationRadians: -.pi / 2))
    )
    let composedSnapshot = try composed.snapshot()
    // inner center (125, 110) → under outer rotation around (200, 150): (240, 75).
    // inner's image is 50 wide along outer's y → along host x after both rotations? No: the two
    // rotations cancel, so the image is a 50×20 box centered at (240, 75): x∈[215,265], y∈[65,85].
    #expect(composedSnapshot.hitTest(p(216, 66)) == inner.id)
    #expect(composedSnapshot.hitTest(p(264, 84)) == inner.id)
    #expect(composedSnapshot.hitTest(p(240, 90)) == outer.id)
}

@Test
@MainActor
func test_hitTest_transformedAncestorClipsInItsLocalSpace() throws {
    var tree = Tree()
    let diamond = tree.add(
        frame(100, 100, 100, 100),
        visual: LayoutVisualProperties(
            overflow: .hidden,
            transform: LayoutTransform(rotationRadians: .pi / 4)
        )
    )
    let huge = tree.add(frame(0, 0, 400, 400), to: diamond)
    let snapshot = try tree.snapshot()

    #expect(snapshot.hitTest(p(150, 150)) == huge.id)  // 25: center of the diamond
    // 25: the original corner lies outside the diamond
    #expect(snapshot.hitTest(p(100, 100)) == tree.root.id)
    // the diamond's top tip (150, 150 − 70.7) is inside
    #expect(snapshot.hitTest(p(150, 82)) == huge.id)
}

@Test
@MainActor
func test_hitTest_coincidingParentAndChildFramesChildWins() throws {
    var tree = Tree()
    let a = tree.add(frame(10, 10, 100, 100))
    let a1 = tree.add(frame(10, 10, 100, 100), to: a)
    #expect(try tree.snapshot().hitTest(p(50, 50)) == a1.id)  // 26
}

@Test
@MainActor
func test_hitTest_thousandNodeTreeWalksInMicroseconds() throws {
    var tree = Tree()
    // 10 rows × 10 columns × 10 leaves, every frame distinct, no transforms: the plain walk.
    for row in 0..<10 {
        let rowNode = tree.add(frame(0, Double(row) * 40, 400, 40))
        for column in 0..<10 {
            let cell = tree.add(frame(Double(column) * 40, Double(row) * 40, 40, 40), to: rowNode)
            for leaf in 0..<10 {
                tree.add(
                    frame(Double(column) * 40 + Double(leaf) * 4, Double(row) * 40, 4, 40),
                    to: cell
                )
            }
        }
    }
    let snapshot = try tree.snapshot()
    #expect(snapshot.count == 1 + 10 + 100 + 1000)

    let clock = ContinuousClock()
    var hits = 0
    let elapsed = clock.measure {
        for index in 0..<1000 {
            if snapshot.hitTest(p(Double(index % 400) + 0.5, Double(index % 397) + 0.5)) != nil {
                hits += 1
            }
        }
    }
    #expect(hits == 1000)
    // Generous bound so CI noise never fails it; the measured figure is in the validation note.
    #expect(elapsed < .milliseconds(500), "1000 hit-tests took \(elapsed)")
    Log.on(.snapshot, "hit-test-bench", "nodes=1111 hits=1000 elapsed=\(elapsed)")
}
