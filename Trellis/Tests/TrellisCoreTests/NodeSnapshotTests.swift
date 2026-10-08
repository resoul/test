import Testing

@testable import TrellisCore

private final class ConstraintCapturingNode: Node {
    private(set) var capturedConstraint: SizeConstraint?

    override func layoutContentMetrics(for constraint: SizeConstraint) -> LayoutContentMetrics {
        capturedConstraint = constraint
        return super.layoutContentMetrics(for: constraint)
    }
}

@Test @MainActor
func test_makeLayoutInputSnapshot_narrowsConstraintFromEachAncestorsOwnResolvedSize() {
    // §3.3 fix: the grandchild must see the *middle* node's own resolved width (100), not the
    // root's original incoming constraint (300) forwarded unchanged past every level.
    let root = Node()
    root.style.width = .points(300)
    root.style.height = .points(200)
    let middle = Node()
    middle.style.width = .points(100)
    root.addSubnode(middle)
    let grandchild = ConstraintCapturingNode()
    middle.addSubnode(grandchild)

    _ = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )

    #expect(grandchild.capturedConstraint?.width == .exact(100))
    #expect(grandchild.capturedConstraint?.height == .exact(200))
}

@Test @MainActor
func test_makeLayoutInputSnapshot_unspecifiedAxisStaysUnspecifiedNotInvented() {
    let root = Node()
    let child = ConstraintCapturingNode()
    root.addSubnode(child)

    _ = root.makeLayoutInputSnapshot()

    #expect(child.capturedConstraint?.width == .unspecified)
    #expect(child.capturedConstraint?.height == .unspecified)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_explicitParentSizeResolvesChildFraction() {
    let root = Node()
    root.style.width = .points(300)
    root.style.height = .points(200)
    let child = ConstraintCapturingNode()
    root.addSubnode(child)

    _ = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(300), height: .exact(200))
    )

    #expect(child.capturedConstraint?.width == .exact(300))
    #expect(child.capturedConstraint?.height == .exact(200))
}

@Test @MainActor
func test_makeLayoutInputSnapshot_rootFoldsSafeAreaIntoPaddingOnTopOfStored() {
    let root = Node()
    root.style.padding = DirectionalEdgeInsets(top: 10)
    root.setSafeAreaInsets(DirectionalEdgeInsets(top: 20, leading: 5, bottom: 0, trailing: 5))

    let snapshot = root.makeLayoutInputSnapshot()

    #expect(snapshot.style.padding.top == 30)
    #expect(snapshot.style.padding.leading == 5)
    #expect(snapshot.style.padding.trailing == 5)
    #expect(snapshot.style.padding.bottom == 0)
    #expect(root.style.padding.top == 10)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_ignoredEdgeExcludesThatInsetFromFold() {
    let root = Node()
    root.setSafeAreaInsets(DirectionalEdgeInsets(top: 20, leading: 5, bottom: 8, trailing: 5))
    root.safeAreaIgnoredEdges = .top

    let snapshot = root.makeLayoutInputSnapshot()

    #expect(snapshot.style.padding.top == 0)
    #expect(snapshot.style.padding.leading == 5)
    #expect(snapshot.style.padding.bottom == 8)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_nonBoundaryDescendantDoesNotFoldSafeArea() {
    let root = Node()
    root.setSafeAreaInsets(DirectionalEdgeInsets(top: 20))
    let child = Node()
    root.addSubnode(child)

    let snapshot = root.makeLayoutInputSnapshot()

    #expect(snapshot.children[0].style.padding.top == 0)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_boundaryDescendantFoldsInheritedSafeArea() {
    let root = Node()
    root.setSafeAreaInsets(DirectionalEdgeInsets(top: 20))
    let child = Node()
    child.safeAreaBoundary = true
    root.addSubnode(child)

    let snapshot = root.makeLayoutInputSnapshot()

    #expect(snapshot.children[0].style.padding.top == 20)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_repeatedCallsDoNotAccumulateSafeAreaPadding() {
    let root = Node()
    root.style.padding = DirectionalEdgeInsets(top: 5)
    root.setSafeAreaInsets(DirectionalEdgeInsets(top: 20))

    let first = root.makeLayoutInputSnapshot()
    let second = root.makeLayoutInputSnapshot()

    #expect(first.style.padding.top == 25)
    #expect(second.style.padding.top == 25)
    #expect(root.style.padding.top == 5)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_reflectsDirectionOverride() {
    let root = Node()
    root.setLayoutDirection(.rightToLeft)

    #expect(root.makeLayoutInputSnapshot().direction == .rightToLeft)
}

@Test @MainActor
func test_makeLayoutInputSnapshot_childInheritsAncestorsDirectionOverride() {
    let root = Node()
    root.setLayoutDirection(.rightToLeft)
    let child = Node()
    root.addSubnode(child)

    let snapshot = root.makeLayoutInputSnapshot()

    #expect(snapshot.children[0].direction == .rightToLeft)
}

@Test @MainActor
func test_addSubnode_reparentsEnvironmentScopeSoDirectionChangesOnNextSnapshot() {
    let oldParent = Node()
    let newParent = Node()
    newParent.setLayoutDirection(.rightToLeft)
    let child = Node()
    oldParent.addSubnode(child)
    #expect(child.makeLayoutInputSnapshot().direction == .leftToRight)

    newParent.addSubnode(child)

    #expect(child.makeLayoutInputSnapshot().direction == .rightToLeft)
}

@Test @MainActor
func test_removeFromSupernode_detachesEnvironmentScopeFallingBackToOwnDefaults() {
    let parent = Node()
    parent.setLayoutDirection(.rightToLeft)
    let child = Node()
    parent.addSubnode(child)
    #expect(child.makeLayoutInputSnapshot().direction == .rightToLeft)

    child.removeFromSupernode()

    #expect(child.makeLayoutInputSnapshot().direction == .leftToRight)
}

@Test @MainActor
func test_setSafeAreaInsets_marksGeometryDirtyOnce() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.setSafeAreaInsets(DirectionalEdgeInsets(top: 10))

    #expect(invalidationCount == 1)
}

@Test @MainActor
func test_setLayoutDirection_marksGeometryDirtyOnce() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.setLayoutDirection(.rightToLeft)

    #expect(invalidationCount == 1)
}

@Test @MainActor
func test_safeAreaBoundaryToggle_marksGeometryDirtyOnlyOnChange() {
    let node = Node()
    var invalidationCount = 0
    node.onInvalidate = { _, _ in invalidationCount += 1 }

    node.safeAreaBoundary = false
    #expect(invalidationCount == 0)

    node.safeAreaBoundary = true
    #expect(invalidationCount == 1)
}

@Test @MainActor
func test_inheritEnvironment_adoptsSharedScopesValuesAndMarksDirty() {
    let sharedSource = Node()
    sharedSource.setLayoutDirection(.rightToLeft)
    let detachedRoot = Node()
    var invalidationCount = 0
    detachedRoot.onInvalidate = { _, _ in invalidationCount += 1 }

    detachedRoot.inheritEnvironment(from: sharedSource.environmentScope)

    #expect(detachedRoot.makeLayoutInputSnapshot().direction == .rightToLeft)
    #expect(invalidationCount == 1)
}

@Test @MainActor
func test_nodeInit_withEnvironmentScopeInheritsFromFirstSnapshot() {
    let sharedSource = Node()
    sharedSource.setLayoutDirection(.rightToLeft)

    let node = Node(environment: sharedSource.environmentScope)

    #expect(node.makeLayoutInputSnapshot().direction == .rightToLeft)
}
