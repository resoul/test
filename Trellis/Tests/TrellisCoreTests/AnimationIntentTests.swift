import Testing

@testable import TrellisCore

@MainActor
private final class WeakNodeBox {
    weak var value: Node?

    init(_ value: Node?) { self.value = value }
}

@Test
func m03_animationValueNormalizesNoneAndProvidesNamedCurves() {
    #expect(Animation.none == Animation(duration: .milliseconds(-1), curve: .easeOut))
    #expect(Animation.smooth == Animation(duration: .milliseconds(250), curve: .easeInOut))
    #expect(Animation.linear(duration: .seconds(1)).curve == .linear)
    #expect(Animation.easeIn(duration: .seconds(1)).curve == .easeIn)
    #expect(Animation.easeOut(duration: .seconds(1)).curve == .easeOut)
    #expect(Animation.easeInOut(duration: .seconds(1)).curve == .easeInOut)
}

@Test
func m09_springNormalizesItsTwoParametersAndNeverCollapsesToNone() {
    let plain = Animation.spring(response: 0.4, dampingFraction: 0.7)
    #expect(plain.curve == .spring(response: 0.4, dampingFraction: 0.7))
    #expect(plain.duration > .zero)

    // A non-positive/zero response has no physical meaning (would divide by zero converting
    // to stiffness/damping) — clamped to a small positive floor rather than propagated.
    let zeroResponse = Animation.spring(response: 0, dampingFraction: 0.7)
    #expect(zeroResponse.curve == .spring(response: 0.05, dampingFraction: 0.7))

    // Zero damping never settles (undamped oscillation forever) — clamped up, not accepted.
    let zeroDamping = Animation.spring(response: 0.4, dampingFraction: 0)
    #expect(zeroDamping.curve == .spring(response: 0.4, dampingFraction: 0.05))

    // Above 1 (overdamped) is physically valid for a real spring but outside this model's
    // documented 0...1 range — clamped down to critically damped instead of silently accepted.
    let overDamped = Animation.spring(response: 0.4, dampingFraction: 1.5)
    #expect(overDamped.curve == .spring(response: 0.4, dampingFraction: 1))
}

@Test
func m09_snappyIsAConcreteSpringPresetNotJustAnAlias() {
    #expect(Animation.snappy.curve == .spring(response: 0.35, dampingFraction: 0.86))
    #expect(Animation.snappy.duration > .zero)
}

@Test @MainActor
func m03_scopeCollectorObservesMutationAfterPendingWindowWasAlreadyDirty() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    root.consumePendingInvalidation()
    root.beginAnimationIntentCollection(epoch: 9)

    root.style.width = 100
    child.animate(.smooth) { child.style.height = 40 }
    child.appearance.cornerRadius = 6

    let records = root.pendingAnimationIntentRecords
    #expect(records.count == 1)
    #expect(records.first?.scopeNodeID == child.id)
    #expect(records.first?.epoch == 9)
    #expect(
        root.resolvedAnimationIntent(for: child.id, from: records, epoch: 9)?.animation == .smooth
    )
    #expect(root.resolvedAnimationIntent(for: root.id, from: records, epoch: 9) == nil)
}

@Test @MainActor
func m03_nestedScopeWinsAndCoversLaterOuterMutationInItsSubtree() {
    let root = Node()
    let card = Node()
    let badge = Node()
    root.addSubnode(card)
    card.addSubnode(badge)
    root.consumePendingInvalidation()
    root.beginAnimationIntentCollection(epoch: 3)

    root.animate(.smooth) {
        card.style.width = 200
        card.animate(.none) { badge.style.height = 10 }
        badge.style.width = 20
    }

    let records = root.pendingAnimationIntentRecords.sorted { $0.sequence < $1.sequence }
    #expect(records.count == 2)
    #expect(records.map(\.scopeNodeID) == [root.id, card.id])
    #expect(records.map(\.sequence) == [1, 2])
    #expect(
        root.resolvedAnimationIntent(for: root.id, from: records, epoch: 3)?.animation == .smooth
    )
    #expect(
        root.resolvedAnimationIntent(for: card.id, from: records, epoch: 3)?.animation
            == Animation.none
    )
    #expect(
        root.resolvedAnimationIntent(for: badge.id, from: records, epoch: 3)?.animation
            == Animation.none
    )
}

@Test @MainActor
func m03_noOpAndSemanticOnlyClosuresDoNotCreateIntentOrVisualWork() {
    let root = Node()
    root.beginAnimationIntentCollection(epoch: 1)

    root.animate(.smooth) {}
    root.animate(.smooth) { root.accessibility.label = "card" }

    #expect(root.pendingAnimationIntentRecords.isEmpty)
    #expect(root.pendingInvalidationReasons == .semantics)
}

@Test @MainActor
func m03_twoRootsKeepIndependentEpochAndSequenceCollectors() {
    let first = Node()
    let second = Node()
    first.beginAnimationIntentCollection(epoch: 11)
    second.beginAnimationIntentCollection(epoch: 22)

    first.animate(.linear(duration: .seconds(1))) { first.style.width = 10 }
    second.animate(.easeOut(duration: .seconds(2))) { second.style.width = 20 }

    #expect(first.pendingAnimationIntentRecords.first?.epoch == 11)
    #expect(second.pendingAnimationIntentRecords.first?.epoch == 22)
    #expect(first.pendingAnimationIntentRecords.first?.sequence == 1)
    #expect(second.pendingAnimationIntentRecords.first?.sequence == 1)
}

@Test @MainActor
func m03_scopeResolutionUsesCommitTimeTreeAndDoesNotRetainRemovedNode() {
    let firstRoot = Node()
    let secondRoot = Node()
    var scope: Node? = Node()
    let weakScope = WeakNodeBox(scope)
    firstRoot.addSubnode(scope!)
    firstRoot.consumePendingInvalidation()
    firstRoot.beginAnimationIntentCollection(epoch: 7)

    scope!.animate(.smooth) { scope!.style.width = 50 }
    let records = firstRoot.pendingAnimationIntentRecords
    secondRoot.addSubnode(scope!)

    #expect(firstRoot.resolvedAnimationIntent(for: scope!.id, from: records, epoch: 7) == nil)
    scope = nil
    #expect(weakScope.value != nil)  // secondRoot owns it, not the intent record
    secondRoot.subnodes.first?.removeFromSupernode()
    #expect(weakScope.value == nil)
    #expect(records.count == 1)
}

@Test @MainActor
func m03_deferredArrangementWrapperJoinsItsOwnersScopeAtCommitResolution() {
    final class Owner: Node {
        let leaf = Node()

        override func arrangeSubnodes() -> (any Arrangement)? {
            Row { Column { Leaf(leaf) } }
        }
    }

    let root = Node()
    let owner = Owner()
    root.addSubnode(owner)
    root.resolveDirtyArrangements()
    root.consumePendingInvalidation()
    root.beginAnimationIntentCollection(epoch: 5)

    owner.animate(.smooth) { owner.markArrangementDirty() }
    root.resolveDirtyArrangements()

    let wrapper = owner.subnodes.first
    let records = root.pendingAnimationIntentRecords
    #expect(wrapper?.isArrangementWrapper == true)
    #expect(
        root.resolvedAnimationIntent(for: wrapper!.id, from: records, epoch: 5)?.animation
            == .smooth
    )
}

@Test @MainActor
func m03_unmountedAndPausedTreesApplyChangesWithoutSavingIntent() {
    let root = Node()
    root.animate(.smooth) { root.style.width = 10 }
    #expect(root.style.width == .points(10))
    #expect(root.pendingAnimationIntentRecords.isEmpty)

    root.beginAnimationIntentCollection(epoch: 4)
    root.consumePendingInvalidation()
    root.pauseAnimationIntentCollection()
    root.animate(.smooth) { root.style.width = 20 }
    #expect(root.style.width == .points(20))
    #expect(root.pendingAnimationIntentRecords.isEmpty)
}
