import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private func waitForCommits(_ coordinator: RenderCoordinator, _ count: Int) async {
    for _ in 0..<200 where coordinator.committedCount < count { await Task.yield() }
}

@MainActor
private final class ResultRejectionSwitch {
    var isEnabled = false
}

@MainActor
private func waitForRetryExhaustion(_ coordinator: RenderCoordinator) async {
    for _ in 0..<10_000 where !coordinator.retryExhausted { await Task.yield() }
}

@Test
@MainActor
func test_renderCoordinator_commitsCompleteGeometryForMountedRoot() async {
    let root = Node()
    let child = Node()
    child.style.width = 40
    child.style.height = 20
    root.addSubnode(child)
    let coordinator = RenderCoordinator(hostID: 1)
    coordinator.mount(root: root)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 200, height: 100), scale: 2)

    await waitForCommits(coordinator, 1)
    #expect(coordinator.committedCount == 1)
    #expect(root.calculatedFrame == LayoutFrame(width: 200, height: 100))
    #expect(child.calculatedFrame != nil)
    #expect(coordinator.lastCommittedRequest?.scale == 2)
}

@Test
@MainActor
func test_renderCoordinator_postCommitInvalidationSurvivesPreviousCommitCleanup() async {
    let root = Node()
    let coordinator = RenderCoordinator(hostID: 3)
    coordinator.mount(root: root)
    var callbacks = 0
    coordinator.onPostCommit = { _ in
        callbacks += 1
        if callbacks == 1 {
            coordinator.invalidate(
                root: root,
                bounds: LayoutFrame(width: 300, height: 300),
                scale: 1
            )
        }
    }
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 200, height: 200), scale: 1)

    await waitForCommits(coordinator, 2)
    #expect(callbacks == 2)
    #expect(coordinator.lastCommittedRequest?.bounds == LayoutFrame(width: 300, height: 300))
    #expect(root.calculatedFrame == LayoutFrame(width: 300, height: 300))
}

@Test
@MainActor
func test_renderCoordinator_replaceRootRejectsPreviousTreesResult() async {
    let first = Node()
    let second = Node()
    let coordinator = RenderCoordinator(hostID: 4)
    coordinator.mount(root: first)
    coordinator.invalidate(root: first, bounds: LayoutFrame(width: 100, height: 100), scale: 1)
    coordinator.replaceRoot(newRoot: second)
    coordinator.invalidate(root: second, bounds: LayoutFrame(width: 150, height: 150), scale: 1)

    await waitForCommits(coordinator, 1)
    #expect(coordinator.lastCommittedResult?.treeIdentity == second.id)
    #expect(first.calculatedFrame == nil)
    #expect(second.calculatedFrame == LayoutFrame(width: 150, height: 150))
}

@Test
@MainActor
func test_renderCoordinator_retryBudgetStopsAndNewStateRecovers() async {
    let rejection = ResultRejectionSwitch()
    let root = Node()
    let coordinator = RenderCoordinator(
        hostID: 5,
        rejectResult: { _, _, _ in rejection.isEnabled ? "controlled-invalid-result" : nil }
    )
    coordinator.mount(root: root)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1)
    await waitForCommits(coordinator, 1)
    #expect(root.calculatedFrame == LayoutFrame(width: 100, height: 100))

    rejection.isEnabled = true
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 200, height: 200), scale: 1)
    await waitForRetryExhaustion(coordinator)
    #expect(coordinator.retryExhausted)
    #expect(coordinator.retryCount == 8)
    #expect(coordinator.requestedCount == 9)
    #expect(coordinator.committedCount == 1)
    #expect(root.calculatedFrame == LayoutFrame(width: 100, height: 100))

    rejection.isEnabled = false
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 1)
    await waitForCommits(coordinator, 2)
    #expect(!coordinator.retryExhausted)
    #expect(coordinator.retryCount == 0)
    #expect(root.calculatedFrame == LayoutFrame(width: 300, height: 300))
}

@Test
@MainActor
func test_renderCoordinator_burstCommitsLatestWithoutSpendingRetryBudget() async {
    let root = Node()
    let coordinator = RenderCoordinator(hostID: 6)
    coordinator.mount(root: root)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 1)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 200, height: 200), scale: 1)
    coordinator.invalidate(root: root, bounds: LayoutFrame(width: 300, height: 300), scale: 1)

    await waitForCommits(coordinator, 1)
    #expect(coordinator.requestedCount == 1)
    #expect(coordinator.retryCount == 0)
    #expect(root.calculatedFrame == LayoutFrame(width: 300, height: 300))
}
