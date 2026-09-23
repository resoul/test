import Testing

@testable import TrellisCore

// M05 (implementation-plan-5.md §5, D67): `ReduceMotionKey` is a plain inherited environment
// value here — the resolution into `.none` at commit time and the "finish active transitions
// immediately" lifecycle behavior live in `TrellisRender` (`LayerRenderer`/`NodeHostBridge`,
// see `ReduceMotionLifecycleTests.swift`). This file only covers the environment plumbing
// itself: default, override, and inheritance, matching `LocaleKey`'s own test shape.

@Test
func m05_reduceMotionDefaultsToFalse() {
    let values = EnvironmentValues()

    #expect(values.reduceMotion == false)
}

@Test @MainActor
func m05_setReduceMotionOverridesForSelfAndUnsetDescendants() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)

    root.setReduceMotion(true)

    #expect(root.environment.reduceMotion == true)
    #expect(child.environment.reduceMotion == true, "inherited from the ancestor scope")
}

@Test @MainActor
func m05_childOverrideWinsOverInheritedReduceMotion() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    root.setReduceMotion(true)

    child.setReduceMotion(false)

    #expect(child.environment.reduceMotion == false)
    #expect(root.environment.reduceMotion == true, "the ancestor's own value is untouched")
}
