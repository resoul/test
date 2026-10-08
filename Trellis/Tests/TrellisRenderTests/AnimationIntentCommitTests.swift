import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private final class RetryMutationState {
    var shouldInject = false
    var didInject = false
}

@MainActor
private func waitForAnimationPublications(
    _ publications: @escaping @MainActor () -> Int,
    count: Int
) async {
    for _ in 0..<10_000 where publications() < count { await Task.yield() }
}

@MainActor
private func mountedCoordinator(
    root: Node,
    onAnimationCommit: @escaping @MainActor (AnimationCommitEnvelope) -> Void
) async -> RenderCoordinator {
    let coordinator = RenderCoordinator(hostID: 303)
    coordinator.onAnimationCommit = onAnimationCommit
    coordinator.mount(root: root, animationEpoch: 41)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 2)
    for _ in 0..<10_000 where coordinator.committedCount < 1 { await Task.yield() }
    return coordinator
}

@Test @MainActor
func m03_paintOnlyEnvelopePreservesIndependentScopesAndConsumesThemOnce() async {
    let root = Node()
    let first = Node()
    let second = Node()
    root.addSubnode(first)
    root.addSubnode(second)
    var envelopes: [AnimationCommitEnvelope] = []
    let coordinator = await mountedCoordinator(root: root) { envelopes.append($0) }
    envelopes.removeAll()

    first.animate(.smooth) { first.appearance.cornerRadius = 8 }
    second.animate(.easeOut(duration: .milliseconds(180))) {
        second.appearance.cornerRadius = 12
    }

    await waitForAnimationPublications({ envelopes.count }, count: 1)
    let intents = envelopes.first?.intents ?? []
    #expect(coordinator.layoutSnapshotCount == 1)
    #expect(intents.map(\.scopeNodeID) == [first.id, second.id])
    #expect(intents.map(\.sequence) == [1, 2])

    root.accessibility.label = "semantic update"
    await waitForAnimationPublications({ envelopes.count }, count: 2)
    #expect(envelopes.last?.intents.isEmpty == true)
}

@Test @MainActor
func m03_sameWorkArrangementPublishCarriesIntentWithoutChangingLayoutIdentity() async {
    final class Owner: Node {
        let child = Node()
        override func arrangeSubnodes() -> (any Arrangement)? { Row { Leaf(child) } }
    }

    let root = Owner()
    var envelopes: [AnimationCommitEnvelope] = []
    let coordinator = await mountedCoordinator(root: root) { envelopes.append($0) }
    let committedRequest = coordinator.lastCommittedRequest
    let snapshotsBefore = coordinator.layoutSnapshotCount
    envelopes.removeAll()

    root.animate(.smooth) { root.markArrangementDirty() }
    await waitForAnimationPublications({ envelopes.count }, count: 1)

    #expect(coordinator.committedCount == 1)
    #expect(coordinator.layoutSnapshotCount == snapshotsBefore + 1)
    #expect(coordinator.lastCommittedRequest == committedRequest)
    #expect(envelopes.first?.request == committedRequest)
    #expect(envelopes.first?.intents.first?.animation == .smooth)
}

@Test @MainActor
func m03_retryMergesOlderIntentWithNewerNoneBySequence() async {
    let root = Node()
    let state = RetryMutationState()
    let coordinator = RenderCoordinator(
        hostID: 304,
        rejectResult: { _, _, _ in
            guard state.shouldInject, !state.didInject else { return nil }
            state.didInject = true
            root.animate(.none) { root.style.width = 180 }
            return "controlled-retry"
        }
    )
    var envelopes: [AnimationCommitEnvelope] = []
    coordinator.onAnimationCommit = { envelopes.append($0) }
    coordinator.mount(root: root, animationEpoch: 12)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1)
    for _ in 0..<10_000 where coordinator.committedCount < 1 { await Task.yield() }
    envelopes.removeAll()

    state.shouldInject = true
    root.animate(.smooth) { root.style.width = 160 }
    for _ in 0..<20_000 where coordinator.committedCount < 2 { await Task.yield() }

    #expect(state.didInject)
    #expect(coordinator.staleCount == 1)
    #expect(envelopes.count == 1)
    let intents = envelopes.first?.intents ?? []
    #expect(intents.map(\.sequence) == [1, 2])
    #expect(intents.map(\.animation) == [.smooth, .none])
    #expect(
        root.resolvedAnimationIntent(for: root.id, from: intents, epoch: 12)?.animation
            == Animation.none
    )
    #expect(root.style.width == .points(180))
}

@Test @MainActor
func m03_appearanceMutationDuringCommitValidationJoinsTheActiveLayoutEnvelope() async {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    var mutateAppearanceOnNextValidation = false
    let coordinator = RenderCoordinator(
        hostID: 305,
        rejectResult: { _, _, _ in
            if mutateAppearanceOnNextValidation {
                mutateAppearanceOnNextValidation = false
                child.animate(.easeIn(duration: .milliseconds(90))) {
                    child.appearance.cornerRadius = 7
                }
            }
            return nil
        }
    )
    var envelopes: [AnimationCommitEnvelope] = []
    coordinator.onAnimationCommit = { envelopes.append($0) }
    coordinator.mount(root: root, animationEpoch: 8)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1)
    for _ in 0..<10_000 where coordinator.committedCount < 1 { await Task.yield() }
    envelopes.removeAll()

    mutateAppearanceOnNextValidation = true
    root.animate(.smooth) { child.style.width = 120 }
    for _ in 0..<10_000 where coordinator.committedCount < 2 { await Task.yield() }

    #expect(envelopes.count == 1)
    #expect(envelopes.first?.intents.map(\.sequence) == [1, 2])
    #expect(
        root.resolvedAnimationIntent(
            for: child.id,
            from: envelopes.first?.intents ?? [],
            epoch: 8
        )?.animation == .easeIn(duration: .milliseconds(90))
    )
}

@Test @MainActor
func m03_suspendAndReplacementDiscardOldEpochIntents() async {
    let first = Node()
    var envelopes: [AnimationCommitEnvelope] = []
    let coordinator = await mountedCoordinator(root: first) { envelopes.append($0) }
    envelopes.removeAll()

    coordinator.suspend()
    first.animate(.smooth) { first.style.width = 100 }
    coordinator.resume()
    for _ in 0..<10_000 where coordinator.committedCount < 2 { await Task.yield() }
    #expect(envelopes.last?.intents.isEmpty == true)

    let second = Node()
    coordinator.replaceRoot(newRoot: second)
    coordinator.invalidate(root: second, bounds: LayoutFrame(width: 300, height: 200), scale: 2)
    for _ in 0..<10_000 where coordinator.committedCount < 3 { await Task.yield() }
    #expect(envelopes.last?.intents.isEmpty == true)
}
