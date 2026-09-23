import Testing

@testable import TrellisCore

@MainActor
private func commit(_ root: Node, _ frames: [(Node, LayoutFrame)]) {
    let result = LayoutResult(
        placements: frames.map { LayoutPlacement(identity: $0.0.id, frame: $0.1) },
        treeIdentity: root.id
    )
    #expect(root.applyLayoutResult(result))
}

@Test
@MainActor
func test_hitTestSnapshot_capturesTreeFramesVisualAndPaintOrder() throws {
    let root = Node()
    let first = Node()
    let second = Node()
    let leaf = Node()
    root.addSubnode(first)
    root.addSubnode(second)
    second.addSubnode(leaf)
    second.style.visual = LayoutVisualProperties(
        zIndex: 3,
        overflow: .hidden,
        opacity: 0.5,
        transform: LayoutTransform(rotationRadians: 1)
    )
    commit(
        root,
        [
            (root, LayoutFrame(width: 400, height: 400)),
            (first, LayoutFrame(origin: LayoutPoint(x: 10, y: 10), width: 100, height: 100)),
            (second, LayoutFrame(origin: LayoutPoint(x: 10, y: 10), width: 100, height: 100)),
            (leaf, LayoutFrame(origin: LayoutPoint(x: 20, y: 20), width: 10, height: 10)),
        ]
    )

    let snapshot = try #require(
        HitTestSnapshot(root: root, mountEpoch: 7, bounds: LayoutFrame(width: 400, height: 400))
    )

    #expect(snapshot.root == root.id)
    #expect(snapshot.mountEpoch == 7)
    #expect(snapshot.bounds == LayoutFrame(width: 400, height: 400))
    #expect(snapshot.count == 4)
    let rootRecord = try #require(snapshot.record(for: root.id))
    #expect(rootRecord.parent == nil)
    #expect(rootRecord.children == [first.id, second.id])
    let secondRecord = try #require(snapshot.record(for: second.id))
    #expect(secondRecord.parent == root.id)
    #expect(secondRecord.children == [leaf.id])
    #expect(
        secondRecord.frame
            == LayoutFrame(origin: LayoutPoint(x: 10, y: 10), width: 100, height: 100)
    )
    #expect(secondRecord.visual == second.style.visual)
    #expect(!secondRecord.isArrangementWrapper)
    #expect(try #require(snapshot.record(for: leaf.id)).parent == second.id)
}

@Test
@MainActor
func test_hitTestSnapshot_marksArrangementWrappersAndSkipsUncommittedSubtrees() throws {
    let root = Node()
    let wrapper = Node()
    let inside = Node()
    wrapper.isArrangementWrapper = true
    root.addSubnode(wrapper)
    wrapper.addSubnode(inside)
    commit(
        root,
        [
            (root, LayoutFrame(width: 400, height: 400)),
            (wrapper, LayoutFrame(width: 400, height: 400)),
            (inside, LayoutFrame(width: 50, height: 50)),
        ]
    )
    // `applyLayoutResult` rejects an incomplete result, so a node without a frame can only be
    // one added after the commit; the renderer skips it with its subtree, and so does the
    // snapshot.
    let uncommitted = Node()
    let orphan = Node()
    root.addSubnode(uncommitted)
    uncommitted.addSubnode(orphan)

    let snapshot = try #require(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: LayoutFrame(width: 400, height: 400))
    )

    #expect(try #require(snapshot.record(for: wrapper.id)).isArrangementWrapper)
    #expect(!(try #require(snapshot.record(for: inside.id)).isArrangementWrapper))
    #expect(snapshot.record(for: uncommitted.id) == nil)
    #expect(snapshot.record(for: orphan.id) == nil)
    #expect(try #require(snapshot.record(for: root.id)).children == [wrapper.id])
    #expect(snapshot.count == 3)
}

@Test
@MainActor
func test_hitTestSnapshot_isNilWithoutCommittedRoot() {
    let root = Node()
    root.addSubnode(Node())

    #expect(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: LayoutFrame(width: 1, height: 1)) == nil
    )
}

@Test
@MainActor
func test_hitTestSnapshot_doesNotFollowLiveMutations() throws {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    commit(
        root,
        [
            (root, LayoutFrame(width: 400, height: 400)),
            (child, LayoutFrame(origin: LayoutPoint(x: 10, y: 10), width: 100, height: 100)),
        ]
    )
    let snapshot = try #require(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: LayoutFrame(width: 400, height: 400))
    )

    child.style.visual = LayoutVisualProperties(opacity: 0)
    child.removeFromSupernode()
    child.dispose()

    let record = try #require(snapshot.record(for: child.id))
    #expect(record.visual.opacity == 1)
    #expect(try #require(snapshot.record(for: root.id)).children == [child.id])
}

@Test
@MainActor
func test_hitTestSnapshot_hittableBoundsFollowTransformClipAndDescendants() throws {
    let root = Node()
    let visibleParent = Node()
    let farChild = Node()
    let clippingParent = Node()
    let clippedChild = Node()
    let rotated = Node()
    root.addSubnode(visibleParent)
    visibleParent.addSubnode(farChild)
    root.addSubnode(clippingParent)
    clippingParent.addSubnode(clippedChild)
    root.addSubnode(rotated)
    clippingParent.style.visual = LayoutVisualProperties(overflow: .hidden)
    rotated.style.visual = LayoutVisualProperties(
        transform: LayoutTransform(rotationRadians: .pi / 2)
    )
    commit(
        root,
        [
            (root, LayoutFrame(width: 400, height: 400)),
            (visibleParent, LayoutFrame(width: 100, height: 100)),
            (farChild, LayoutFrame(origin: LayoutPoint(x: 150, y: 150), width: 50, height: 50)),
            (
                clippingParent,
                LayoutFrame(origin: LayoutPoint(x: 200, y: 0), width: 100, height: 100)
            ),
            (
                clippedChild,
                LayoutFrame(origin: LayoutPoint(x: 250, y: 50), width: 100, height: 100)
            ),
            (rotated, LayoutFrame(origin: LayoutPoint(x: 100, y: 300), width: 100, height: 50)),
        ]
    )
    let snapshot = try #require(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: LayoutFrame(width: 400, height: 400))
    )

    // `.visible`: the far child widens its parent's box (T03).
    #expect(
        try #require(snapshot.record(for: visibleParent.id)).hittableBounds
            == LayoutFrame(width: 200, height: 200)
    )
    // `.hidden`: the child cannot be hit outside the parent, so the box is the parent's frame.
    #expect(
        try #require(snapshot.record(for: clippingParent.id)).hittableBounds
            == LayoutFrame(origin: LayoutPoint(x: 200, y: 0), width: 100, height: 100)
    )
    // Rotation around the center (150, 325): a 100×50 frame becomes a 50×100 box.
    let box = try #require(snapshot.record(for: rotated.id)).hittableBounds
    #expect(abs(box.origin.x - 125) < 1e-9)
    #expect(abs(box.origin.y - 275) < 1e-9)
    #expect(abs(box.width - 50) < 1e-9)
    #expect(abs(box.height - 100) < 1e-9)
    // The root's box is the union of everything; the far child and the rotated box are inside.
    #expect(
        try #require(snapshot.record(for: root.id)).hittableBounds
            == LayoutFrame(width: 400, height: 400)
    )
}
