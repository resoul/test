import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

/// Lets any flush the resolver's own invalidations might have scheduled run to completion, so
/// a test can assert that none produced a commit.
@MainActor
private func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

/// A self-arranging tile placed by `Card`: resolving it requires the parent's placement to
/// already be in effect (D12/D13 pre-order).
@MainActor
private final class Tile: Node {
    let line = Node()
    private(set) var arrangeCalls = 0
    override func arrangeSubnodes() -> (any Arrangement)? {
        arrangeCalls += 1
        return Column(spacing: 4) { Leaf(line).size(height: .points(10)) }
    }
}

@MainActor
private final class Card: Node {
    let title = Node()
    let tile = Tile()
    var showTitle = true
    var duplicateTitle = false
    private(set) var arrangeCalls = 0
    override func arrangeSubnodes() -> (any Arrangement)? {
        arrangeCalls += 1
        return Row(spacing: 8) {
            if showTitle { Leaf(title).size(width: .points(40), height: .points(20)) }
            if duplicateTitle { Leaf(title) }
            Column { Leaf(tile).grow(1) }
        }
    }
}

/// Keeps the host layer alive for the bridge, which only holds it weakly.
@MainActor
private final class Host {
    let layer = CALayer()
    let bridge: NodeHostBridge
    init() { bridge = NodeHostBridge(hostLayer: layer) }
}

@MainActor
private func mount(_ card: Card) async -> Host {
    let root = Node()
    root.style.flexDirection = .column
    root.addSubnode(card)
    let host = Host()
    #expect(host.bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))
    await waitForCommits(host.bridge, 1)
    return host
}

@Test
@MainActor
func test_autoResolve_firstFlushResolvesEveryOwnerInPreOrderWithoutManualCalls() async throws {
    let card = Card()
    // Nothing is resolved before a host is attached.
    #expect(card.subnodes.isEmpty)
    #expect(card.needsArrangementResolve)

    let host = await mount(card)
    let bridge = host.bridge
    await settle()

    #expect(card.arrangeCalls == 1)
    #expect(card.tile.arrangeCalls == 1)
    #expect(card.childrenAreArrangementManaged)
    #expect(card.subnodes.first === card.title)
    let wrapper = try #require(card.subnodes.last)
    #expect(wrapper.isArrangementWrapper)
    #expect(wrapper.subnodes.first === card.tile)
    // The tile kept its parent's placement and applied its own container (D12).
    #expect(card.tile.arrangementEffectiveStyle?.flexGrow == 1)
    #expect(card.tile.arrangementEffectiveStyle?.flexDirection == .column)
    #expect(card.tile.line.calculatedFrame?.height == 10)
    // The resolve happened inside the first flush: one commit, not a resolve-then-commit pair.
    #expect(bridge.committedCount == 1)
    #expect(!card.needsArrangementResolve)
    #expect(!card.tile.needsArrangementResolve)
}

@Test
@MainActor
func test_autoResolve_unchangedTreeAndEnvironmentChangesNeverReResolve() async throws {
    let card = Card()
    let host = await mount(card)
    let bridge = host.bridge
    await settle()
    #expect(card.arrangeCalls == 1)
    let wrapper = try #require(card.subnodes.last)

    // A geometry-only change flushes and commits, but re-runs no Arrangement.
    card.title.style.width = 50
    await waitForCommits(bridge, 2)
    await settle()
    #expect(card.arrangeCalls == 1)
    #expect(card.tile.arrangeCalls == 1)

    // Environment changes are not a trigger either (D03/D13).
    bridge.updateSafeArea(DirectionalEdgeInsets(top: 20))
    bridge.updateLayoutDirection(.rightToLeft)
    await waitForCommits(bridge, 3)
    await settle()
    #expect(card.arrangeCalls == 1)
    #expect(card.tile.arrangeCalls == 1)
    #expect(card.subnodes.last === wrapper)
    #expect(wrapper.childrenAreArrangementManaged)
}

@Test
@MainActor
func test_autoResolve_markArrangementDirtyReResolvesOnlyThatOwnerOnNextFlush() async throws {
    let card = Card()
    let host = await mount(card)
    let bridge = host.bridge
    await settle()
    let commitsBefore = bridge.committedCount

    card.showTitle = false
    // Nothing happens synchronously — the tree is untouched until the next flush.
    #expect(card.subnodes.first === card.title)
    card.markArrangementDirty()
    #expect(card.needsArrangementResolve)
    #expect(card.subnodes.first === card.title)

    await waitForCommits(bridge, commitsBefore + 1)
    await settle()
    #expect(card.arrangeCalls == 2)
    #expect(card.tile.arrangeCalls == 1)
    #expect(card.subnodes.count == 1)
    #expect(card.title.supernode == nil)
    #expect(card.title.arrangementEffectiveStyle == nil)
    // Exactly one commit for the whole change.
    #expect(bridge.committedCount == commitsBefore + 1)
}

@Test
@MainActor
func test_autoResolve_rejectedProposalIsDiagnosedOnceNotEveryFlush() async throws {
    let card = Card()
    card.duplicateTitle = true
    let host = await mount(card)
    let bridge = host.bridge
    await settle()

    // Rejected: the tree stayed manual, the flag is cleared, later flushes do not retry.
    #expect(card.arrangeCalls == 1)
    #expect(!card.childrenAreArrangementManaged)
    #expect(!card.needsArrangementResolve)
    card.style.padding = DirectionalEdgeInsets(top: 4)
    await waitForCommits(bridge, 2)
    await settle()
    #expect(card.arrangeCalls == 1)

    // Fixing the description and marking dirty resolves on the next flush.
    card.duplicateTitle = false
    card.markArrangementDirty()
    await waitForCommits(bridge, 3)
    await settle()
    #expect(card.arrangeCalls == 2)
    #expect(card.childrenAreArrangementManaged)
}

@Test
@MainActor
func test_autoResolve_wrappersAreNeverResolvedAndNodesAddedLaterAreDiscovered() async throws {
    let card = Card()
    let host = await mount(card)
    let bridge = host.bridge
    await settle()
    let wrapper = try #require(card.subnodes.last)
    #expect(!wrapper.needsArrangementResolve || wrapper.isArrangementWrapper)
    #expect(!wrapper.resolveArrangement())
    #expect(wrapper.childrenAreArrangementManaged)
    #expect(wrapper.subnodes.first === card.tile)

    // A second owner added to the manual part of the tree is picked up by the next flush.
    let late = Card()
    let root = try #require(card.supernode)
    root.addSubnode(late)
    await waitForCommits(bridge, 2)
    await settle()
    #expect(late.arrangeCalls == 1)
    #expect(late.tile.arrangeCalls == 1)
    #expect(late.childrenAreArrangementManaged)
}
