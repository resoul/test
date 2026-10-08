import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// A04/A05 — the bridge owns the engine (D35): focus follows publishes through the real
// pipeline, and lifecycle (detach, suspend/resume, root replacement) clears or restores it.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func settle() async {
    for _ in 0..<300 { await Task.yield() }
}

@MainActor
private final class Grid {
    let root = Node()
    let cards: [ControlNode] = (0..<3).map { _ in ControlNode() }
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    var changes: [FocusChange] = []

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        root.style {
            $0.flexDirection = .row; $0.gap = 20
        }
        for card in cards {
            card.style {
                $0.width = 80; $0.height = 80
            }
            root.addSubnode(card)
        }
        bridge.onFocusChange = { [weak self] change in self?.changes.append(change) }
    }

    func attach() async {
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 400, height: 200), scale: 1))
        await waitForCommits(bridge, 1)
    }
}

@Test @MainActor
func a04_bridgeRefusesFocusBeforeFirstCommitAndServesItAfter() async {
    let grid = Grid()
    #expect(grid.bridge.focus(grid.cards[0].id) == .unavailable)
    #expect(grid.bridge.moveFocus(.next) == .unavailable)
    await grid.attach()
    #expect(grid.bridge.focusedID == nil)
    #expect(
        grid.bridge.moveFocus(.next)
            == .moved(FocusChange(previous: nil, next: grid.cards[0].id, reason: .navigation))
    )
    #expect(
        grid.bridge.moveFocus(.right)
            == .moved(
                FocusChange(previous: grid.cards[0].id, next: grid.cards[1].id, reason: .navigation)
            )
    )
    #expect(grid.bridge.focusedID == grid.cards[1].id)
    #expect(grid.bridge.lastFocusTrace?.selected == grid.cards[1].id)
    #expect(grid.changes.count == 2)
}

@Test @MainActor
func a04_commitRemovingTheFocusedCardFallsBackThroughThePipeline() async {
    let grid = Grid()
    await grid.attach()
    grid.bridge.focus(grid.cards[1].id)
    grid.changes.removeAll()

    grid.cards[1].dispose()
    // Until the commit lands the published tree still shows the card; focus stays.
    #expect(grid.bridge.focusedID == grid.cards[1].id)
    await waitForCommits(grid.bridge, 2)
    #expect(grid.bridge.focusedID == grid.cards[2].id)
    #expect(
        grid.changes == [
            FocusChange(previous: grid.cards[1].id, next: grid.cards[2].id, reason: .invalidation)
        ]
    )
}

@Test @MainActor
func a04_disablingTheFocusedCardIsAMetadataOnlyPublishThatMovesFocus() async {
    let grid = Grid()
    await grid.attach()
    grid.bridge.focus(grid.cards[0].id)
    grid.changes.removeAll()

    grid.cards[0].isEnabled = false
    await settle()
    #expect(grid.bridge.statistics.committed == 1)
    #expect(grid.bridge.metadataOnlyPublishCount == 1)
    #expect(grid.bridge.focusedID == grid.cards[1].id)
    #expect(grid.changes.last?.reason == .invalidation)
}

@Test @MainActor
func a04_detachClearsFocusWithoutEventsAndReattachStartsFresh() async {
    let grid = Grid()
    await grid.attach()
    grid.bridge.focus(grid.cards[2].id)
    grid.changes.removeAll()

    grid.bridge.detach()
    #expect(grid.bridge.focusedID == nil)
    #expect(grid.changes.isEmpty)
    #expect(grid.bridge.focus(grid.cards[2].id) == .unavailable)

    await grid.attach()
    #expect(grid.bridge.focusedID == nil)
    #expect(
        grid.bridge.focus(grid.cards[2].id)
            == .moved(FocusChange(previous: nil, next: grid.cards[2].id, reason: .request))
    )
}

@Test @MainActor
func a05_suspendClearsFocusKeepsRestorationAndResumeRestoresIt() async {
    let grid = Grid()
    await grid.attach()
    grid.bridge.focus(grid.cards[1].id)
    grid.changes.removeAll()

    grid.bridge.suspend()
    #expect(grid.bridge.focusedID == nil)
    #expect(grid.changes == [FocusChange(previous: grid.cards[1].id, next: nil, reason: .suspend)])
    #expect(grid.bridge.focus(grid.cards[0].id) == .unavailable)  // inactive host takes no input

    grid.bridge.resume()
    #expect(grid.bridge.focusedID == grid.cards[1].id)
    #expect(
        grid.changes.last
            == FocusChange(previous: nil, next: grid.cards[1].id, reason: .restoration)
    )
    await settle()
    #expect(grid.bridge.focusedID == grid.cards[1].id)
}

@Test @MainActor
func a05_resumeDoesNotRestoreACardThatWentAwayWhileSuspended() async {
    let grid = Grid()
    await grid.attach()
    grid.bridge.focus(grid.cards[1].id)
    grid.bridge.suspend()
    grid.cards[1].isEnabled = false
    grid.bridge.resume()
    // The last snapshot still lists the card as enabled — the engine restored it — but the
    // first publish after resume carries the disabled state and moves focus on.
    await settle()
    #expect(grid.bridge.focusedID == grid.cards[2].id)
    #expect(grid.changes.last?.reason == .invalidation)
}

@Test @MainActor
func a05_replacingTheRootClearsFocusAndScope() async {
    let grid = Grid()
    await grid.attach()
    grid.bridge.focus(grid.cards[0].id)
    grid.bridge.setFocusScope(grid.root.id)
    #expect(grid.bridge.focusScopeID == grid.root.id)

    let other = Node()
    #expect(grid.bridge.attach(root: other, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    #expect(grid.bridge.focusedID == nil)
    #expect(grid.bridge.focusScopeID == nil)
    await waitForCommits(grid.bridge, 1)
    #expect(grid.bridge.focus(grid.cards[0].id) == .unavailable)
}

@Test @MainActor
func a05_detachReleasesRootAndBridgeWithFocusAndScopeSet() async {
    weak var weakRoot: Node?
    weak var weakBridge: NodeHostBridge?
    weak var weakCard: ControlNode?
    do {
        let grid = Grid()
        await grid.attach()
        grid.bridge.focus(grid.cards[1].id)
        grid.bridge.setFocusScope(grid.root.id)
        weakRoot = grid.root
        weakBridge = grid.bridge
        weakCard = grid.cards[1]
        grid.bridge.detach()
        #expect(grid.bridge.focusedID == nil)
        #expect(grid.bridge.focusScopeID == nil)
        #expect(grid.bridge.semanticSnapshot == nil)
    }
    #expect(weakRoot == nil)
    #expect(weakBridge == nil)
    #expect(weakCard == nil)
}

// MARK: - A07: keys and accessibility actions through the bridge

@Test @MainActor
func a07_bridgeRoutesKeysAndRefusesThemWhileInactive() async {
    let grid = Grid()
    var activations: [ActivationSource] = []
    grid.cards[1].activation = { [weak card = grid.cards[1]] in
        if let source = card?.lastActivationSource { activations.append(source) }
    }
    #expect(grid.bridge.send(.keyDown, key: KeyData(key: .tab)) == .unhandled)  // before commit
    await grid.attach()
    #expect(grid.bridge.send(.keyDown, key: KeyData(key: .tab)) == .handled)
    #expect(grid.bridge.send(.keyDown, key: KeyData(key: .rightArrow)) == .handled)
    #expect(grid.bridge.focusedID == grid.cards[1].id)
    #expect(grid.bridge.send(.keyDown, key: KeyData(key: .returnKey)) == .handled)
    #expect(grid.cards[1].isPressed)
    #expect(grid.bridge.send(.keyUp, key: KeyData(key: .returnKey)) == .handled)
    #expect(activations == [.keyboard])

    grid.bridge.send(.keyDown, key: KeyData(key: .space))
    grid.bridge.suspend()  // cancels the open press through the focus transition
    #expect(!grid.cards[1].isPressed)
    #expect(grid.bridge.send(.keyUp, key: KeyData(key: .space)) == .unhandled)
    grid.bridge.resume()
    #expect(grid.bridge.focusedID == grid.cards[1].id)
    // Dispatched to the focused card, but no cycle is open: nothing activates.
    #expect(grid.bridge.send(.keyUp, key: KeyData(key: .space)) == .handled)
    #expect(activations == [.keyboard])
}

@Test @MainActor
func a07_bridgeAccessibilityActionValidatesAgainstThePublishedTreeAndTheLiveNode() async {
    let grid = Grid()
    var activations: [ActivationSource] = []
    for card in grid.cards {
        card.accessibility.label = "Card"
        card.activation = { [weak card] in
            if let source = card?.lastActivationSource { activations.append(source) }
        }
    }
    // No tree before the first commit.
    #expect(!grid.bridge.performAccessibilityAction(.activate, on: grid.cards[0].id))
    await grid.attach()
    grid.bridge.focus(grid.cards[2].id)

    #expect(grid.bridge.performAccessibilityAction(.activate, on: grid.cards[0].id))
    #expect(activations == [.accessibility])
    #expect(grid.bridge.focusedID == grid.cards[2].id)  // D45: AX activate never moves focus

    // Disabled live but not yet published, and published-disabled: both refused.
    grid.cards[0].isEnabled = false
    #expect(!grid.bridge.performAccessibilityAction(.activate, on: grid.cards[0].id))
    await settle()
    #expect(!grid.bridge.performAccessibilityAction(.activate, on: grid.cards[0].id))

    // Hidden from the tree (modal scope elsewhere) → refused; unknown action id → handler says no.
    grid.bridge.setFocusScope(grid.cards[2].id)
    #expect(!grid.bridge.performAccessibilityAction(.activate, on: grid.cards[1].id))
    grid.bridge.setFocusScope(nil)
    #expect(!grid.bridge.performAccessibilityAction(.custom("nope"), on: grid.cards[1].id))
    grid.cards[1].onAccessibilityAction = { $0 == .custom("share") }
    #expect(grid.bridge.performAccessibilityAction(.custom("share"), on: grid.cards[1].id))

    // A stale identity after a new attach — the old proxy's id — is refused.
    let staleID = grid.cards[1].id
    let other = Node()
    #expect(grid.bridge.attach(root: other, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    await waitForCommits(grid.bridge, 1)
    #expect(!grid.bridge.performAccessibilityAction(.activate, on: staleID))
    #expect(activations == [.accessibility])
}
