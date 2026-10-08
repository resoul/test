import Testing

@testable import TrellisCore

@Test
func test_environmentValues_unsetKeyReadsAsDefault() {
    let values = EnvironmentValues()

    #expect(values.layoutDirection == .leftToRight)
    #expect(values.safeAreaInsets == DirectionalEdgeInsets())
}

@Test
func test_environmentValues_setKeyOverridesDefault() {
    var values = EnvironmentValues()

    values.layoutDirection = .rightToLeft

    #expect(values.layoutDirection == .rightToLeft)
}

@Test @MainActor
func test_environmentScope_withNoParentReadsOwnOverridesOnly() {
    let scope = EnvironmentScope()

    scope.set(TestDirectionKey.self, to: .rightToLeft)

    #expect(scope.snapshot.values.layoutDirectionForTestKey == .rightToLeft)
}

@Test @MainActor
func test_environmentScope_inheritsFromParentWhenUnset() {
    let parent = EnvironmentScope()
    parent.set(TestDirectionKey.self, to: .rightToLeft)
    let child = EnvironmentScope(parent: parent)

    #expect(child.snapshot.values.layoutDirectionForTestKey == .rightToLeft)
}

@Test @MainActor
func test_environmentScope_ownOverrideWinsOverInherited() {
    let parent = EnvironmentScope()
    parent.set(TestDirectionKey.self, to: .rightToLeft)
    let child = EnvironmentScope(parent: parent)

    child.set(TestDirectionKey.self, to: .leftToRight)

    #expect(child.snapshot.values.layoutDirectionForTestKey == .leftToRight)
    #expect(parent.snapshot.values.layoutDirectionForTestKey == .rightToLeft)
}

@Test @MainActor
func test_environmentScope_reparentAdoptsNewParentsValues() {
    let oldParent = EnvironmentScope()
    let newParent = EnvironmentScope()
    newParent.set(TestDirectionKey.self, to: .rightToLeft)
    let child = EnvironmentScope(parent: oldParent)
    #expect(child.snapshot.values.layoutDirectionForTestKey == .leftToRight)

    child.reparent(to: newParent)

    #expect(child.snapshot.values.layoutDirectionForTestKey == .rightToLeft)
}

@Test @MainActor
func test_environmentScope_reparentAdvancesRevision() {
    let oldParent = EnvironmentScope()
    let newParent = EnvironmentScope()
    let child = EnvironmentScope(parent: oldParent)
    let revisionBefore = child.snapshot.revision

    child.reparent(to: newParent)

    #expect(child.snapshot.revision > revisionBefore)
}

@Test @MainActor
func test_environmentScope_ancestorChangeAdvancesDescendantSnapshotRevision() {
    let parent = EnvironmentScope()
    let child = EnvironmentScope(parent: parent)
    let revisionBefore = child.snapshot.revision

    parent.set(TestDirectionKey.self, to: .rightToLeft)

    #expect(child.snapshot.revision > revisionBefore)
    #expect(child.snapshot.values.layoutDirectionForTestKey == .rightToLeft)
}

@Test @MainActor
func test_environmentScope_detachingToNilFallsBackToOwnDefaults() {
    let parent = EnvironmentScope()
    parent.set(TestDirectionKey.self, to: .rightToLeft)
    let child = EnvironmentScope(parent: parent)
    #expect(child.snapshot.values.layoutDirectionForTestKey == .rightToLeft)

    child.reparent(to: nil)

    #expect(child.snapshot.values.layoutDirectionForTestKey == .leftToRight)
}

// Defect #81: a descendant whose own scope changed more often than its ancestor (here by
// repeated reparenting) must still observe the ancestor's later change as a new revision.
@Test @MainActor
func test_environmentScope_ancestorChangeAdvancesBusierDescendantRevision() {
    let parent = EnvironmentScope()
    let child = EnvironmentScope(parent: parent)
    for _ in 0..<5 {
        child.reparent(to: nil)
        child.reparent(to: parent)
    }
    let revisionBefore = child.snapshot.revision

    parent.set(TestDirectionKey.self, to: .rightToLeft)

    #expect(child.snapshot.revision > revisionBefore)
}

private enum TestDirectionKey: EnvironmentKey {
    static let defaultValue = LayoutDirection.leftToRight
}

extension EnvironmentValues {
    fileprivate var layoutDirectionForTestKey: LayoutDirection {
        get { self[TestDirectionKey.self] }
        set { self[TestDirectionKey.self] = newValue }
    }
}
