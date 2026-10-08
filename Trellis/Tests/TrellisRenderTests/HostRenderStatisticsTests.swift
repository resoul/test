import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

/// C31: the counters a measurement run records must be deterministic for a synchronous
/// burst — these tests pin the numbers so a regression in coalescing shows up as a failed
/// assertion, not as a slower benchmark.
@MainActor
private final class Host {
    let layer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let leaves: [Node]

    init(width: Int) {
        bridge = NodeHostBridge(hostLayer: layer)
        root.style.flexDirection = .row
        root.style.flexWrap = .wrap
        leaves = (0..<width).map { _ in
            let leaf = Node()
            leaf.style.width = 10
            leaf.style.height = 10
            return leaf
        }
        for leaf in leaves { root.addSubnode(leaf) }
    }

    func attach() -> Bool {
        bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 200), scale: 2)
    }

    func waitForCommits(_ count: Int) async {
        for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
    }

    func settle() async {
        for _ in 0..<300 { await Task.yield() }
    }
}

@Test @MainActor
func test_statistics_hundredSynchronousStyleWritesAreOneRequestAndOneCommit() async {
    let host = Host(width: 100)
    #expect(host.attach())
    await host.waitForCommits(1)
    await host.settle()
    #expect(
        host.bridge.statistics
            == HostRenderStatistics(
                requested: 1,
                coalesced: 0,
                stale: 0,
                committed: 1,
                retries: 0,
                cancelled: 0
            )
    )
    #expect(host.bridge.materializedLayerCount == 101)

    for leaf in host.leaves { leaf.style.width = 12 }
    await host.waitForCommits(2)
    await host.settle()
    #expect(host.bridge.statistics.requested == 2)
    #expect(host.bridge.statistics.committed == 2)
    #expect(host.bridge.statistics.coalesced == 0)
}

@Test @MainActor
func test_statistics_appearanceOnlyBurstIsOneCoalescedFlushAndNoRequest() async {
    let host = Host(width: 100)
    #expect(host.attach())
    await host.waitForCommits(1)
    await host.settle()

    for leaf in host.leaves {
        leaf.appearance.background = .color(ThemeColor(red: 0.5, green: 0.2, blue: 0.1))
    }
    await host.settle()
    #expect(
        host.bridge.statistics
            == HostRenderStatistics(
                requested: 1,
                coalesced: 1,
                stale: 0,
                committed: 1,
                retries: 0,
                cancelled: 0
            )
    )
}

@Test @MainActor
func test_statistics_equalWritesAndUnchangedBoundsRequestNothing() async {
    let host = Host(width: 10)
    #expect(host.attach())
    await host.waitForCommits(1)
    await host.settle()

    for leaf in host.leaves { leaf.style.width = 10 }  // equal → no-op at the node
    host.bridge.updateBounds(LayoutFrame(width: 200, height: 200), scale: 2)  // same host state
    await host.settle()
    #expect(host.bridge.statistics.requested == 1)
    #expect(host.bridge.statistics.committed == 1)
}

@Test @MainActor
func test_statistics_twoHostsUpdatedTogetherEachCommitOnce() async {
    let a = Host(width: 50)
    let b = Host(width: 50)
    #expect(a.attach())
    #expect(b.attach())
    await a.waitForCommits(1)
    await b.waitForCommits(1)
    await a.settle()

    for (x, y) in zip(a.leaves, b.leaves) {
        x.style.width = 11
        y.style.width = 11
    }
    await a.waitForCommits(2)
    await b.waitForCommits(2)
    await a.settle()
    #expect(a.bridge.statistics.committed == 2)
    #expect(b.bridge.statistics.committed == 2)
    #expect(a.bridge.statistics.requested == 2)
    #expect(b.bridge.statistics.requested == 2)
    #expect(a.bridge.materializedLayerCount == 51)
    #expect(b.bridge.materializedLayerCount == 51)
}

@Test @MainActor
func test_statistics_repeatedAttachDetachLeavesNoLayersAndResetsCounters() async {
    let host = Host(width: 20)
    for round in 1...5 {
        #expect(host.attach())
        await host.waitForCommits(1)
        await host.settle()
        #expect(host.bridge.statistics.committed == 1, "round \(round)")
        #expect(host.bridge.materializedLayerCount == 21)
        host.bridge.detach()
        #expect(host.bridge.materializedLayerCount == 0)
        #expect(host.layer.sublayers?.isEmpty ?? true)
        #expect(host.bridge.statistics.committed == 0)
    }
}
