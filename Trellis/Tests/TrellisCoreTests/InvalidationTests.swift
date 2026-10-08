import Testing

@testable import TrellisCore

private struct TestFailure: Error {}

@Test @MainActor
func test_styleWrite_singleFieldChangeFiresOneInvalidation() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.style.width = 100

    #expect(invalidationCount == 1)
    #expect(node.geometryRevision == 1)
}

@Test @MainActor
func test_styleBatch_multipleFieldChangesFireOneInvalidation() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.style { style in
        style.width = 100
        style.height = 50
        style.gap = 8
    }

    #expect(invalidationCount == 1)
    #expect(node.geometryRevision == 1)
}

@Test @MainActor
func test_appearanceBatch_multipleFieldChangesFireOneInvalidation() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.appearance { appearance in
        appearance.cornerRadius = 4
        appearance.background = .color(ThemeColor(red: 1, green: 0, blue: 0))
    }

    #expect(invalidationCount == 1)
    #expect(node.appearanceRevision == 1)
}

@Test @MainActor
func test_styleWrite_assigningTheSameDefaultValueIsANoOp() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.style = LayoutStyle()

    #expect(invalidationCount == 0)
    #expect(node.geometryRevision == 0)
}

@Test @MainActor
func test_styleBatch_normalizingToTheSameEffectiveValueIsANoOp() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.style { $0.gap = -5 }

    #expect(invalidationCount == 0)
    #expect(node.geometryRevision == 0)
}

@Test @MainActor
func test_appearanceWrite_equalValueIsANoOp() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.appearance = VisualStyle()

    #expect(invalidationCount == 0)
    #expect(node.appearanceRevision == 0)
}

@Test @MainActor
func test_appearanceWrite_changeReportsOnlyAppearanceReason() {
    let node = Node()
    var capturedReasons: DirtyReasons?
    node.onInvalidate = { _, reasons in capturedReasons = reasons }

    node.appearance.cornerRadius = 8

    #expect(capturedReasons == .appearance)
    #expect(node.appearanceRevision == 1)
    #expect(node.geometryRevision == 0)
}

@Test @MainActor
func test_appearanceChange_doesNotBumpAncestorGeometryRevision() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let rootGeometryBefore = root.geometryRevision

    child.appearance.cornerRadius = 4

    #expect(root.geometryRevision == rootGeometryBefore)
    #expect(root.appearanceRevision == 0)
}

@Test @MainActor
func test_addSubnode_bumpsStructureAndGeometryOnParent() {
    let parent = Node()
    let child = Node()
    var capturedReasons: DirtyReasons?
    parent.onInvalidate = { _, reasons in capturedReasons = reasons }

    parent.addSubnode(child)

    #expect(parent.geometryRevision == 1)
    #expect(parent.structureRevision == 1)
    #expect(capturedReasons == [.structure, .geometry])
}

@Test @MainActor
func test_addSubnode_sameParentNoOpDoesNotInvalidate() {
    let parent = Node()
    let child = Node()
    parent.addSubnode(child)
    parent.consumePendingInvalidation()
    var invalidationCount = 0
    parent.onInvalidate = { _, _ in invalidationCount += 1 }

    parent.addSubnode(child)

    #expect(invalidationCount == 0)
    #expect(parent.structureRevision == 1)
}

@Test @MainActor
func test_grandchildStyleChange_bumpsGeometryRevisionOnEveryAncestor() {
    let root = Node()
    let child = Node()
    let grandchild = Node()
    root.addSubnode(child)
    child.addSubnode(grandchild)
    let rootBefore = root.geometryRevision
    let childBefore = child.geometryRevision

    grandchild.style.width = 42

    #expect(root.geometryRevision == rootBefore + 1)
    #expect(child.geometryRevision == childBefore + 1)
    #expect(grandchild.geometryRevision == 1)
}

@Test @MainActor
func test_deepMutation_pingsOnlyRootCallbackWithOriginalNode() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    root.consumePendingInvalidation()
    var capturedOrigin: Node?
    var rootPings = 0
    var childPings = 0
    root.onInvalidate = { origin, _ in
        capturedOrigin = origin
        rootPings += 1
    }
    child.onInvalidate = { _, _ in childPings += 1 }

    child.style.width = 10

    #expect(capturedOrigin === child)
    #expect(rootPings == 1)
    #expect(childPings == 0)
}

@Test @MainActor
func test_manySynchronousWrites_coalesceToOnePing() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    for value in 0..<100 {
        node.style.width = .points(Double(value))
    }

    #expect(invalidationCount == 1)
    #expect(node.consumePendingInvalidation()?.reasons == .geometry)
}

@Test @MainActor
func test_consumePendingInvalidation_returnsNilWhenNothingPending() {
    let node = Node()

    #expect(node.consumePendingInvalidation() == nil)
}

@Test @MainActor
func test_consumePendingInvalidation_allowsNextMutationToPingAgain() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.style.width = 10
    #expect(invalidationCount == 1)
    node.consumePendingInvalidation()
    node.style.width = 20

    #expect(invalidationCount == 2)
}

@Test @MainActor
func test_mutationWithoutHostAttached_doesNotCrash() {
    let node = Node()

    node.style.width = 10

    #expect(node.geometryRevision == 1)
}

@Test @MainActor
func test_invalidationTransaction_suppressesPingUntilExit() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    InvalidationTransaction.perform {
        node.style.width = 10
        #expect(invalidationCount == 0)
    }

    #expect(invalidationCount == 1)
}

@Test @MainActor
func test_invalidationTransaction_nestedOnlyFlushesAtOutermostExit() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    InvalidationTransaction.perform {
        InvalidationTransaction.perform {
            node.style.width = 10
        }
        #expect(invalidationCount == 0)
    }

    #expect(invalidationCount == 1)
}

@Test @MainActor
func test_invalidationTransaction_restoresNormalModeEvenWhenBodyThrows() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    #expect(throws: TestFailure.self) {
        try InvalidationTransaction.perform {
            node.style.width = 10
            throw TestFailure()
        }
    }
    #expect(invalidationCount == 1)

    node.consumePendingInvalidation()
    node.style.width = 20

    #expect(invalidationCount == 2)
}

@Test @MainActor
func test_reparentAcrossTrees_pingsBothOldAndNewRootOnce() {
    let oldRoot = Node()
    let newRoot = Node()
    let child = Node()
    oldRoot.addSubnode(child)
    oldRoot.consumePendingInvalidation()
    var oldRootPings = 0
    var newRootPings = 0
    oldRoot.onInvalidate = { _, _ in oldRootPings += 1 }
    newRoot.onInvalidate = { _, _ in newRootPings += 1 }

    newRoot.addSubnode(child)

    #expect(oldRootPings == 1)
    #expect(newRootPings == 1)
}

@Test @MainActor
func test_dispose_cascadingSubtreeFiresOnlyOnePing() {
    let root = Node()
    let child = Node()
    let grandchild = Node()
    root.addSubnode(child)
    child.addSubnode(grandchild)
    root.consumePendingInvalidation()
    var pingCount = 0
    var capturedOrigin: Node?
    root.onInvalidate = { origin, _ in
        pingCount += 1
        capturedOrigin = origin
    }

    child.dispose()

    #expect(pingCount == 1)
    #expect(capturedOrigin === child)
    #expect(root.subnodes.isEmpty)
}

@MainActor
private func makeUnmountedTreeWithPendingWindow() -> Node {
    let root = Node()
    root.addSubnode(Node())  // structure change at the root: origin == root
    root.style.width = 10  // and again, folded into the same pending window
    return root
}

@Test
@MainActor
func test_invalidation_pendingWindowDoesNotRetainAnUnmountedTree() {
    // Defect #31: the origin of the pending window used to be a strong reference — when the
    // origin is the root itself, a self-retain that outlived every owner.
    weak var weakRoot: Node?
    do {
        let root = makeUnmountedTreeWithPendingWindow()
        weakRoot = root
        #expect(root.consumePendingInvalidation() != nil)  // still drains while alive
        root.addSubnode(Node())  // leave a fresh window pending on release
    }

    #expect(weakRoot == nil)

    // With the origin gone before the drain, the root reports itself as origin.
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    #expect(root.consumePendingInvalidation() != nil)
    child.style.width = 5
    child.removeFromSupernode()
    let pending = root.consumePendingInvalidation()
    #expect(pending?.origin === child)
}
