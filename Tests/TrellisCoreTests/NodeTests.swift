import Testing

@testable import TrellisCore

@Test @MainActor
func test_node_startsWithNoParentAndNoChildren() {
    let node = Node()

    #expect(node.supernode == nil)
    #expect(node.subnodes.isEmpty)
    #expect(node.isDisposed == false)
    #expect(node.calculatedFrame == nil)
}

@Test @MainActor
func test_node_defaultStyleAndAppearanceAreFresh() {
    let node = Node()

    #expect(node.style == LayoutStyle())
    #expect(node.appearance == VisualStyle())
}

@Test @MainActor
func test_addSubnode_appendsAndSetsParent() {
    let parent = Node()
    let child = Node()

    parent.addSubnode(child)

    #expect(parent.subnodes.map(\.id) == [child.id])
    #expect(child.supernode === parent)
}

@Test @MainActor
func test_addSubnode_appendsInCallOrder() {
    let parent = Node()
    let first = Node()
    let second = Node()

    parent.addSubnode(first)
    parent.addSubnode(second)

    #expect(parent.subnodes.map(\.id) == [first.id, second.id])
}

@Test @MainActor
func test_addSubnode_reparentsFromPreviousParentPreservingIdentity() {
    let oldParent = Node()
    let newParent = Node()
    let child = Node()
    let childID = child.id
    oldParent.addSubnode(child)

    newParent.addSubnode(child)

    #expect(oldParent.subnodes.isEmpty)
    #expect(newParent.subnodes.map(\.id) == [childID])
    #expect(child.id == childID)
    #expect(child.supernode === newParent)
}

@Test @MainActor
func test_addSubnode_selfCycleIsRejected() {
    let node = Node()

    node.addSubnode(node)

    #expect(node.subnodes.isEmpty)
}

@Test @MainActor
func test_addSubnode_ancestorCycleIsRejected() {
    let grandparent = Node()
    let parent = Node()
    let child = Node()
    grandparent.addSubnode(parent)
    parent.addSubnode(child)

    child.addSubnode(grandparent)

    #expect(child.subnodes.map(\.id) == [])
    #expect(grandparent.supernode == nil)
}

@Test @MainActor
func test_addSubnode_sameParentReAddIsANoOpNotAMove() {
    let parent = Node()
    let first = Node()
    let second = Node()
    parent.addSubnode(first)
    parent.addSubnode(second)

    parent.addSubnode(first)

    #expect(parent.subnodes.map(\.id) == [first.id, second.id])
}

@Test @MainActor
func test_addSubnode_disposedChildIsRejected() {
    let parent = Node()
    let child = Node()
    child.dispose()

    parent.addSubnode(child)

    #expect(parent.subnodes.isEmpty)
}

@Test @MainActor
func test_addSubnode_disposedParentIsRejected() {
    let parent = Node()
    let child = Node()
    parent.dispose()

    parent.addSubnode(child)

    #expect(parent.subnodes.isEmpty)
    #expect(child.supernode == nil)
}

@Test @MainActor
func test_insertSubnode_insertsAtRequestedIndex() {
    let parent = Node()
    let first = Node()
    let second = Node()
    let inserted = Node()
    parent.addSubnode(first)
    parent.addSubnode(second)

    parent.insertSubnode(inserted, at: 1)

    #expect(parent.subnodes.map(\.id) == [first.id, inserted.id, second.id])
}

@Test @MainActor
func test_insertSubnode_outOfRangeIndexIsRejected() {
    let parent = Node()
    let child = Node()

    parent.insertSubnode(child, at: 5)

    #expect(parent.subnodes.isEmpty)
    #expect(child.supernode == nil)
}

@Test @MainActor
func test_insertSubnode_negativeIndexIsRejected() {
    let parent = Node()
    let child = Node()

    parent.insertSubnode(child, at: -1)

    #expect(parent.subnodes.isEmpty)
}

@Test @MainActor
func test_insertSubnode_atChildCountAppends() {
    let parent = Node()
    let first = Node()
    let appended = Node()
    parent.addSubnode(first)

    parent.insertSubnode(appended, at: 1)

    #expect(parent.subnodes.map(\.id) == [first.id, appended.id])
}

@Test @MainActor
func test_moveSubnode_reordersWithinSameParent() {
    let parent = Node()
    let first = Node()
    let second = Node()
    let third = Node()
    parent.addSubnode(first)
    parent.addSubnode(second)
    parent.addSubnode(third)

    parent.moveSubnode(from: 0, to: 2)

    #expect(parent.subnodes.map(\.id) == [second.id, third.id, first.id])
}

@Test @MainActor
func test_moveSubnode_invalidFromIndexIsRejected() {
    let parent = Node()
    let child = Node()
    parent.addSubnode(child)

    parent.moveSubnode(from: 5, to: 0)

    #expect(parent.subnodes.map(\.id) == [child.id])
}

@Test @MainActor
func test_moveSubnode_invalidToIndexIsRejected() {
    let parent = Node()
    let child = Node()
    parent.addSubnode(child)

    parent.moveSubnode(from: 0, to: 5)

    #expect(parent.subnodes.map(\.id) == [child.id])
}

@Test @MainActor
func test_removeFromSupernode_detachesWithoutDisposing() {
    let parent = Node()
    let child = Node()
    parent.addSubnode(child)

    child.removeFromSupernode()

    #expect(parent.subnodes.isEmpty)
    #expect(child.supernode == nil)
    #expect(child.isDisposed == false)
}

@Test @MainActor
func test_removeFromSupernode_withoutParentIsANoOp() {
    let node = Node()

    node.removeFromSupernode()

    #expect(node.supernode == nil)
}

@Test @MainActor
func test_detachThenReattach_preservesIdentity() {
    let parent = Node()
    let other = Node()
    let child = Node()
    let childID = child.id
    parent.addSubnode(child)

    child.removeFromSupernode()
    other.addSubnode(child)

    #expect(child.id == childID)
    #expect(other.subnodes.map(\.id) == [childID])
}

@Test @MainActor
func test_dispose_isTerminalAndIdempotent() {
    let node = Node()

    node.dispose()
    node.dispose()

    #expect(node.isDisposed)
}

@Test @MainActor
func test_dispose_removesAttachedNodeFromParentsList() {
    let parent = Node()
    let child = Node()
    parent.addSubnode(child)

    child.dispose()

    #expect(parent.subnodes.isEmpty)
    #expect(child.supernode == nil)
}

@Test @MainActor
func test_dispose_cascadesToDescendantsAndClearsParentsList() {
    let root = Node()
    let child = Node()
    let grandchild = Node()
    root.addSubnode(child)
    child.addSubnode(grandchild)

    root.dispose()

    #expect(root.subnodes.isEmpty)
    #expect(child.isDisposed)
    #expect(grandchild.isDisposed)
}

@Test @MainActor
func test_dispose_disposedNodeRejectsFurtherAddSubnode() {
    let node = Node()
    let child = Node()
    node.dispose()

    node.addSubnode(child)

    #expect(node.subnodes.isEmpty)
}

private final class CountingDisposeNode: Node {
    var disposeCallCount = 0

    override func dispose() {
        guard !isDisposed else { return }
        disposeCallCount += 1
        super.dispose()
    }
}

@Test @MainActor
func test_dispose_subclassOverrideRunsExactlyOnceEvenWhenCascaded() {
    let parent = Node()
    let child = CountingDisposeNode()
    parent.addSubnode(child)

    parent.dispose()
    child.dispose()

    #expect(child.disposeCallCount == 1)
}
