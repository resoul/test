import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

/// C26: the counter-level facts a load run must hold. Timings live in the bench, not here.
@MainActor
private func makeDeepTree(depth: Int, siblings: Int) -> (root: Node, leaf: Node) {
    let root = Node()
    root.style.flexDirection = .column
    var current = root
    for _ in 0..<depth {
        for _ in 0..<siblings {
            let leaf = Node()
            leaf.style.width = 6
            leaf.style.height = 3
            current.addSubnode(leaf)
        }
        let next = Node()
        next.style.flexDirection = .column
        next.style.padding = DirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
        current.addSubnode(next)
        current = next
    }
    let leaf = Node()
    leaf.style.width = 6
    leaf.style.height = 3
    current.addSubnode(leaf)
    return (root, leaf)
}

@Test @MainActor
func test_load_burstDuringLayoutCancelsInFlightWorkAndCommitsTheLastState() async throws {
    // A tree big enough that a solve is in flight when the next mutation lands (and deep
    // enough to have overflowed the old 512 KiB solver stack — defect #22).
    let (root, leaf) = makeDeepTree(depth: 100, siblings: 4)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 800, height: 4000), scale: 1))
    for _ in 0..<50_000 where bridge.committedCount < 1 { await Task.yield() }

    var width = 6.0
    for _ in 0..<30 {
        width += 1
        leaf.style.width = .points(width)
        // Let the flush submit the request, so the next write lands mid-solve.
        let requested = bridge.statistics.requested
        for _ in 0..<1_000 where bridge.statistics.requested == requested { await Task.yield() }
    }
    for _ in 0..<200_000 where leaf.calculatedFrame?.width != width { await Task.yield() }
    for _ in 0..<200 { await Task.yield() }

    let stats = bridge.statistics
    #expect(leaf.calculatedFrame?.width == width)
    #expect(stats.cancelled >= 1)  // some solves were superseded mid-flight
    #expect(stats.retries == 0)  // never the retry path — cancellation is not a failure
    #expect(stats.stale <= stats.cancelled)
    #expect(stats.committed <= stats.requested)
}

@Test @MainActor
func test_load_steadyTreeReusesEveryLayerAcrossCommits() async {
    let (root, leaf) = makeDeepTree(depth: 20, siblings: 4)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 800, height: 4000), scale: 2))
    for _ in 0..<50_000 where bridge.committedCount < 1 { await Task.yield() }
    let created = bridge.createdLayerTotal
    #expect(created == bridge.materializedLayerCount)

    for i in 1...20 {
        leaf.style.width = .points(Double(6 + i))
        for _ in 0..<50_000 where bridge.committedCount < 1 + i { await Task.yield() }
    }
    #expect(bridge.committedCount == 21)
    #expect(bridge.createdLayerTotal == created)  // reuse, no churn
    #expect(bridge.materializedLayerCount == created)
}

@Test @MainActor
func test_teardown_repeatedAttachDetachReleasesEverything() async {
    weak var weakBridge: NodeHostBridge?
    weak var weakRoot: Node?
    weak var weakHostLayer: CALayer?
    var layersAfterEachDetach: [Int] = []
    do {
        let host = CALayer()
        weakHostLayer = host
        let bridge = NodeHostBridge(hostLayer: host)
        weakBridge = bridge
        for round in 0..<10 {
            let (root, leaf) = makeDeepTree(depth: 10, siblings: 10)
            weakRoot = root
            #expect(
                bridge.attach(root: root, bounds: LayoutFrame(width: 800, height: 4000), scale: 2)
            )
            for _ in 0..<50_000 where bridge.committedCount < 1 { await Task.yield() }
            leaf.style.width = .points(Double(7 + round))
            for _ in 0..<50_000 where bridge.committedCount < 2 { await Task.yield() }
            bridge.detach()
            layersAfterEachDetach.append(bridge.materializedLayerCount)
            #expect(host.sublayers?.isEmpty ?? true)
        }
        // The bridge's created-layer total grows per mount (fresh trees), but nothing stays.
        #expect(layersAfterEachDetach.allSatisfy { $0 == 0 })
    }
    for _ in 0..<200 { await Task.yield() }
    #expect(weakRoot == nil)
    #expect(weakBridge == nil)
    #expect(weakHostLayer == nil)
}
