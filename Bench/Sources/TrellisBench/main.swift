import CoreGraphics
import CoreText
import Darwin
import Foundation
import QuartzCore
import TrellisCore
import TrellisRender

// MARK: - Measurement plumbing

/// Wall-clock samples in milliseconds with the two quantiles the plan asks for.
struct Samples: Encodable {
    var values: [Double] = []
    mutating func add(_ ms: Double) { values.append(ms) }
    var p50: Double { quantile(0.5) }
    var p95: Double { quantile(0.95) }
    var max: Double { values.max() ?? 0 }
    private func quantile(_ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))
        return sorted[index]
    }
    enum CodingKeys: String, CodingKey { case p50, p95, max, count }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(round3(p50), forKey: .p50)
        try container.encode(round3(p95), forKey: .p95)
        try container.encode(round3(max), forKey: .max)
        try container.encode(values.count, forKey: .count)
    }
}

func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

func elapsedMs(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// Pumps the main run loop until `condition` holds (or `timeoutMs` passes). MainActor tasks
/// — the coordinator's flush, the scheduler's result hop, a binding's deferred delivery —
/// are enqueued on the main dispatch queue, which the run loop drains; waiting this way
/// measures Trellis, not the concurrency runtime's yield cadence (an `async main` with
/// `Task.yield()` polling showed a flat ~10 ms per hop that is not Trellis's).
@MainActor
func pump(timeoutMs: Double = 10_000, until condition: () -> Bool) {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs * 1_000_000)
    while !condition() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.0002))
        if DispatchTime.now().uptimeNanoseconds > deadline {
            FileHandle.standardError.write(Data("WARNING: pump timed out\n".utf8))
            return
        }
    }
}

/// Resident set size of this process in MiB — the runtime/allocator view, which the plan
/// says not to expect back at the original byte; live-object checks use weak references.
func residentMiB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / 1_048_576
}

func peakResidentMiB() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Double(usage.ru_maxrss) / 1_048_576
}

struct FixtureResult: Encodable {
    let name: String
    var parameters: [String: Int]
    var timingsMs: [String: Samples] = [:]
    var counters: [String: Int] = [:]
    var memoryMiB: [String: Double] = [:]
    var notes: [String] = []
}

struct Report: Encodable {
    let date: String
    let host: String
    let os: String
    let configuration: String
    let logMode: String
    let iterations: Int
    var fixtures: [FixtureResult] = []
}

@MainActor
struct HostHarness {
    let layer = CALayer()
    let bridge: NodeHostBridge
    init() { bridge = NodeHostBridge(hostLayer: layer) }

    func waitForCommits(_ count: Int) {
        pump { bridge.statistics.committed >= count }
    }

    /// Lets every already-scheduled MainActor task (flush, delivery) run out.
    func settle() {
        for _ in 0..<5 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.0002)) }
    }
}

/// Deterministic pseudo-random sizes (fixed seed) so runs are comparable.
struct LCG {
    var state: UInt64
    mutating func next(_ upper: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(upper))
    }
}

// MARK: - Trees

@MainActor
func makeWideTree(count: Int, seed: UInt64 = 7) -> (root: Node, leaves: [Node]) {
    var rng = LCG(state: seed)
    let root = Node()
    root.style.flexDirection = .row
    root.style.flexWrap = .wrap
    root.style.gap = 2
    var leaves: [Node] = []
    for _ in 0..<count {
        let leaf = Node()
        leaf.style.width = .points(Double(8 + rng.next(24)))
        leaf.style.height = .points(Double(8 + rng.next(16)))
        leaf.appearance.background = .color(ThemeColor(red: 0.2, green: 0.5, blue: 0.9))
        root.addSubnode(leaf)
        leaves.append(leaf)
    }
    return (root, leaves)
}

/// `depth` nested columns, each with `siblings` fixed leaves beside the next level.
@MainActor
func makeDeepTree(depth: Int, siblings: Int) -> (root: Node, deepest: Node, count: Int) {
    let root = Node()
    root.style.flexDirection = .column
    root.style.padding = DirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
    var current = root
    var count = 1
    for _ in 0..<depth {
        for _ in 0..<siblings {
            let leaf = Node()
            leaf.style.width = 6
            leaf.style.height = 3
            current.addSubnode(leaf)
            count += 1
        }
        let next = Node()
        next.style.flexDirection = .column
        next.style.padding = DirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
        current.addSubnode(next)
        current = next
        count += 1
    }
    let deepest = Node()
    deepest.style.width = 6
    deepest.style.height = 3
    current.addSubnode(deepest)
    return (root, deepest, count + 1)
}

// MARK: - Fixtures

@MainActor
func fixtureDeepLocalEdit(iterations: Int) -> FixtureResult {
    let depth = 30
    let siblings = 8
    var result = FixtureResult(
        name: "deep-local-edit",
        parameters: ["depth": depth, "siblings": siblings]
    )
    let (root, deepest, count) = makeDeepTree(depth: depth, siblings: siblings)
    result.parameters["nodes"] = count
    let host = HostHarness()
    let bounds = LayoutFrame(width: 800, height: 2000)

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(root: root, bounds: bounds, scale: 2)
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach

    // Phase split, synchronously, on the same code path the coordinator uses.
    var snapshot = Samples(), solve = Samples(), apply = Samples()
    for _ in 0..<iterations {
        var input: LayoutInputSnapshot?
        snapshot.add(
            elapsedMs {
                input = root.makeLayoutInputSnapshot(
                    constraint: SizeConstraint(width: .exact(800), height: .exact(2000))
                )
            }
        )
        guard let input else { continue }
        var layout: LayoutResult?
        solve.add(
            elapsedMs {
                layout = try? FlexboxEngine.layoutContainer(
                    input: input,
                    frame: bounds,
                    roundingPolicy: PixelRoundingPolicy(scale: 2)
                )
            }
        )
        guard let layout else { continue }
        apply.add(elapsedMs { _ = root.applyLayoutResult(layout) })
    }
    result.timingsMs["phase-snapshot"] = snapshot
    result.timingsMs["phase-solve"] = solve
    result.timingsMs["phase-apply-frames"] = apply

    var edit = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        edit.add(
            elapsedMs {
                // Starts at 7: the leaf is built at 6, and an equal width is a no-op that never
                // commits (the pump would only time out).
                deepest.style.width = .points(Double(7 + (i % 5)))
                host.waitForCommits(target)
            }
        )
    }
    result.timingsMs["single-leaf-edit-to-commit"] = edit
    let stats = host.bridge.statistics
    result.counters = [
        "requested": stats.requested, "coalesced": stats.coalesced, "committed": stats.committed,
        "layers": host.bridge.materializedLayerCount,
    ]
    host.bridge.detach()
    return result
}

@MainActor
func fixtureWide(count: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(name: "wide-\(count)", parameters: ["nodes": count + 1])
    let (root, leaves) = makeWideTree(count: count)
    let host = HostHarness()
    let before = residentMiB()

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: 600, height: 4000),
                scale: 2
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach

    var resize = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        resize.add(
            elapsedMs {
                host.bridge.updateBounds(
                    LayoutFrame(width: Double(400 + (i % 10) * 40), height: 4000),
                    scale: 2
                )
                host.waitForCommits(target)
            }
        )
    }
    result.timingsMs["resize-to-commit"] = resize

    // A burst of 60 bounds updates in one turn must be one request.
    let requestedBefore = host.bridge.statistics.requested
    let committedBefore = host.bridge.statistics.committed
    var burst = Samples()
    burst.add(
        elapsedMs {
            for i in 0..<60 {
                host.bridge.updateBounds(
                    LayoutFrame(width: Double(300 + i), height: 4000),
                    scale: 2
                )
            }
            host.waitForCommits(committedBefore + 1)
        }
    )
    host.settle()
    result.timingsMs["resize-burst-60-to-commit"] = burst
    result.counters["resize-burst-requests"] = host.bridge.statistics.requested - requestedBefore

    // Paint-only on every node (defect #10 measurement): no solve, tree-wide re-apply.
    var paint = Samples()
    for i in 0..<iterations {
        let coalescedBefore = host.bridge.statistics.coalesced
        paint.add(
            elapsedMs {
                let tint = ThemeColor(red: 0.1 * Double(i % 10), green: 0.5, blue: 0.5)
                for leaf in leaves { leaf.appearance.background = .color(tint) }
                pump { host.bridge.statistics.coalesced > coalescedBefore }
            }
        )
    }
    result.timingsMs["paint-only-all-nodes"] = paint

    var geometry = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        geometry.add(
            elapsedMs {
                for leaf in leaves { leaf.style.height = .points(Double(8 + (i % 4))) }
                host.waitForCommits(target)
            }
        )
    }
    result.timingsMs["geometry-all-nodes-to-commit"] = geometry

    let stats = host.bridge.statistics
    result.counters["requested"] = stats.requested
    result.counters["coalesced"] = stats.coalesced
    result.counters["committed"] = stats.committed
    result.counters["stale"] = stats.stale
    result.counters["layers"] = host.bridge.materializedLayerCount
    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-mounted"] = round3(residentMiB())
    host.bridge.detach()
    result.memoryMiB["resident-detached"] = round3(residentMiB())
    return result
}

@MainActor
func fixtureAttachDetach(count: Int, cycles: Int) -> FixtureResult {
    var result = FixtureResult(
        name: "attach-detach",
        parameters: ["nodes": count + 1, "cycles": cycles]
    )
    let host = HostHarness()
    var cycle = Samples()
    weak var lastRoot: Node?
    let before = residentMiB()
    for _ in 0..<cycles {
        let (root, _) = makeWideTree(count: count)
        lastRoot = root
        cycle.add(
            elapsedMs {
                _ = host.bridge.attach(
                    root: root,
                    bounds: LayoutFrame(width: 600, height: 4000),
                    scale: 2
                )
                host.waitForCommits(1)
                host.bridge.detach()
            }
        )
        if host.bridge.materializedLayerCount != 0 || !(host.layer.sublayers?.isEmpty ?? true) {
            result.notes.append("layers left behind after detach")
        }
    }
    result.timingsMs["attach-commit-detach"] = cycle
    host.settle()
    result.counters["live-root-after-release"] = lastRoot == nil ? 0 : 1
    result.counters["layers-after"] = host.bridge.materializedLayerCount
    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-after"] = round3(residentMiB())
    result.memoryMiB["peak"] = round3(peakResidentMiB())
    return result
}

@MainActor
func fixtureStateBurst(count: Int, sends: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(
        name: "state-burst",
        parameters: ["nodes": count + 1, "sends": sends]
    )
    let (root, leaves) = makeWideTree(count: count)
    let host = HostHarness()
    _ = host.bridge.attach(root: root, bounds: LayoutFrame(width: 600, height: 4000), scale: 2)
    host.waitForCommits(1)

    let subject = StateSubject(0)
    var updates = 0
    host.bridge.bindState(subject) { value in
        updates += 1
        // `% 7` so every burst's last value (a multiple of 1000) lands on a new height —
        // an equal height is a no-op at the node and, correctly, produces no commit at all.
        for leaf in leaves { leaf.style.height = .points(Double(8 + value % 7)) }
    }
    host.settle()
    let updatesAfterBind = updates

    var burst = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        burst.add(
            elapsedMs {
                for k in 1...sends { subject.send(i * sends + k) }
                host.waitForCommits(target)
            }
        )
        host.settle()
    }
    result.timingsMs["burst-to-commit"] = burst
    result.counters["updates-delivered"] = updates - updatesAfterBind
    result.counters["updates-expected"] = iterations
    result.counters["committed"] = host.bridge.statistics.committed
    result.counters["requested"] = host.bridge.statistics.requested
    host.bridge.cancelAllBindings()
    host.bridge.detach()
    return result
}

@MainActor
func fixtureTwoHosts(count: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(name: "two-hosts", parameters: ["nodes-per-host": count + 1])
    let a = HostHarness(), b = HostHarness()
    let (rootA, leavesA) = makeWideTree(count: count, seed: 1)
    let (rootB, leavesB) = makeWideTree(count: count, seed: 2)
    _ = a.bridge.attach(root: rootA, bounds: LayoutFrame(width: 600, height: 4000), scale: 2)
    _ = b.bridge.attach(root: rootB, bounds: LayoutFrame(width: 600, height: 4000), scale: 2)
    a.waitForCommits(1)
    b.waitForCommits(1)

    var both = Samples()
    for i in 0..<iterations {
        let targetA = a.bridge.statistics.committed + 1
        let targetB = b.bridge.statistics.committed + 1
        both.add(
            elapsedMs {
                for (x, y) in zip(leavesA, leavesB) {
                    x.style.height = .points(Double(8 + i % 3))
                    y.style.height = .points(Double(9 + i % 3))
                }
                a.waitForCommits(targetA)
                b.waitForCommits(targetB)
            }
        )
    }
    result.timingsMs["both-hosts-update-to-commit"] = both
    result.counters["a-committed"] = a.bridge.statistics.committed
    result.counters["b-committed"] = b.bridge.statistics.committed
    result.counters["a-stale"] = a.bridge.statistics.stale
    result.counters["b-stale"] = b.bridge.statistics.stale
    a.bridge.detach()
    b.bridge.detach()
    return result
}

@MainActor
func fixtureCancelLatency(iterations: Int) -> FixtureResult {
    // TRELLIS_BENCH_DEPTH lets a depth-limit scan run this fixture alone at a chosen depth in
    // its own process (C26): a stack overflow in the solver kills the process, so the scan
    // is a loop of processes, not a loop in here.
    // 1500 by default: after defects #14/#23 a 200-deep chain solves in ~1 ms, too fast for a
    // cancel to land mid-solve — the latency measurement needs a solve of tens of ms.
    let depth = Int(ProcessInfo.processInfo.environment["TRELLIS_BENCH_DEPTH"] ?? "") ?? 1500
    var result = FixtureResult(
        name: "cancel-latency",
        parameters: ["deep-depth": depth, "wide-items": 5000]
    )
    let (deepRoot, _, deepCount) = makeDeepTree(depth: depth, siblings: 4)
    let (wideRoot, _) = makeWideTree(count: 5000)
    wideRoot.style.flexWrap = .noWrap
    result.parameters["deep-nodes"] = deepCount

    // Tall enough that the chain never overflows: an overflowing chain shrinks at every
    // level and re-measures exponentially (defect #22) — a separate limit from the stack.
    for (label, root, frame) in [
        ("deep", deepRoot, LayoutFrame(width: 800, height: Double(max(4000, depth * 20)))),
        ("wide-single-line", wideRoot, LayoutFrame(width: 200_000, height: 100)),
    ] {
        let input = root.makeLayoutInputSnapshot(
            constraint: SizeConstraint(width: .exact(frame.width), height: .exact(frame.height))
        )
        var solve = Samples()
        for _ in 0..<iterations {
            solve.add(
                elapsedMs { _ = try? FlexboxEngine.layoutContainer(input: input, frame: frame) }
            )
        }
        result.timingsMs["\(label)-solve-uncancelled"] = solve

        var latency = Samples()
        for _ in 0..<iterations {
            var finishedAt: UInt64 = 0
            let scheduler = LayoutScheduler(
                hostID: 99,
                onResult: { _ in },
                onWorkerFinished: { _ in
                    finishedAt = DispatchTime.now().uptimeNanoseconds
                }
            )
            scheduler.request(input: input, frame: frame)
            // Let the worker actually start before cancelling.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.0005))
            let cancelAt = DispatchTime.now().uptimeNanoseconds
            scheduler.cancel()
            pump { finishedAt != 0 }
            if finishedAt >= cancelAt {
                latency.add(Double(finishedAt - cancelAt) / 1_000_000)
            } else {
                result.counters["\(label)-finished-before-cancel", default: 0] += 1
            }
            scheduler.dispose()
        }
        result.timingsMs["\(label)-cancel-to-worker-exit"] = latency
    }
    return result
}

// MARK: - Defect #24: constraint-dependent basis on overflowing chains

/// How every level of a `makeDeepTree` chain relates to the space it gets (defect #24).
enum ChainMode: String, CaseIterable {
    /// Frame tall enough for the whole chain — the reference case of ADR 0008.
    case fits
    /// Frame shorter than the content: the nested column shrinks at every level.
    case shrink
    /// Frame taller than the content and `flexGrow = 1` on every nested column.
    case grow
    /// Shorter frame and the nesting axis alternates row/column, so a level's main axis is
    /// its parent's cross axis.
    case shrinkAlternating
}

/// The deep chain of `makeDeepTree` under one `ChainMode`; the frame the fixture lays it out
/// in is chosen from the chain's natural height (`14 × depth + 5` with the 1pt padding).
@MainActor
func makeChain(depth: Int, mode: ChainMode) -> (root: Node, count: Int, frame: LayoutFrame) {
    let (root, _, count) = makeDeepTree(depth: depth, siblings: 4)
    let natural = Double(14 * depth + 5)
    var current: Node? = root
    var level = 0
    while let node = current {
        let nested = node.subnodes.last { !$0.subnodes.isEmpty }
        switch mode {
        case .fits, .shrink: break
        case .grow: nested?.style.flexGrow = 1
        case .shrinkAlternating: node.style.flexDirection = level % 2 == 0 ? .column : .row
        }
        current = nested
        level += 1
    }
    let height: Double
    switch mode {
    case .fits: height = natural + 100
    case .shrink, .shrinkAlternating: height = (natural / 2).rounded()
    case .grow: height = natural * 2
    }
    return (root, count, LayoutFrame(width: 800, height: height))
}

/// Solves one chain of each mode at every depth in `TRELLIS_BENCH_CHAIN_DEPTHS` (default
/// `8,12,16,20`) and records the measurement-cache counters next to the time: how many
/// `(node, constraint)` states the pass visited, how many it answered from the cache and the
/// largest fan-out for one node. This is the reproduction for defect #24 — the numbers, not
/// the seconds, are the evidence: a state count doubling with each step of depth is the
/// constraint-dependent basis, whatever the machine. Heavy depths belong in their own
/// process with an external timeout (`TRELLIS_BENCH_ONLY=overflow-chain`).
@MainActor
func fixtureOverflowChain() -> FixtureResult {
    let depths = (ProcessInfo.processInfo.environment["TRELLIS_BENCH_CHAIN_DEPTHS"] ?? "8,12,16,20")
        .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let modes = (ProcessInfo.processInfo.environment["TRELLIS_BENCH_CHAIN_MODES"] ?? "")
        .split(separator: ",").compactMap { ChainMode(rawValue: String($0)) }
    var result = FixtureResult(name: "overflow-chain", parameters: ["siblings": 4])
    for mode in modes.isEmpty ? ChainMode.allCases : modes {
        for depth in depths {
            let (root, count, frame) = makeChain(depth: depth, mode: mode)
            let input = root.makeLayoutInputSnapshot(
                constraint: SizeConstraint(width: .exact(frame.width), height: .exact(frame.height))
            )
            var cache = FlexMeasureCache()
            var samples = Samples()
            samples.add(
                elapsedMs {
                    _ = try? FlexboxEngine.layoutContainer(
                        input: input,
                        frame: frame,
                        cache: &cache
                    )
                }
            )
            let label = "\(mode.rawValue)-d\(depth)"
            let stats = cache.statistics
            result.timingsMs["\(label)-solve"] = samples
            result.counters["\(label)-nodes"] = count
            result.counters["\(label)-states"] = stats.entries
            result.counters["\(label)-lookups"] = stats.lookups
            result.counters["\(label)-hits"] = stats.hits
            result.counters["\(label)-max-per-node"] = stats.maxEntriesPerNode
        }
    }
    return result
}

// MARK: - C30: layout-only wrappers

/// A card with three implicit wrappers (`Column { Row { Column { … }; … } }`) — the S19-like
/// shape the C30 experiment targets — painted itself, so wrappers have a painting ancestor.
@MainActor
final class WrapperCard: Node {
    let a = Node(), b = Node(), c = Node(), d = Node()
    override init(
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        super.init(style: style, appearance: appearance, environment: environment)
        self.style.width = 200
        self.appearance.background = .color(ThemeColor(red: 0.2, green: 0.2, blue: 0.3))
        for leaf in [a, b, c, d] {
            leaf.style.width = 24
            leaf.style.height = 12
            leaf.appearance.background = .color(ThemeColor(red: 0.6, green: 0.6, blue: 0.9))
        }
    }
    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 4,
            padding: DirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        ) {
            Row(spacing: 4) {
                Column(spacing: 2) {
                    Leaf(a); Leaf(b)
                }
                Leaf(c)
            }
            Row(spacing: 4) { Leaf(d).grow(1) }
        }
    }
}

@MainActor
func fixtureWrappers(cards: Int, skip: Bool, iterations: Int) -> FixtureResult {
    var result = FixtureResult(
        name: skip ? "wrappers-without-layers" : "wrappers-with-layers",
        parameters: ["cards": cards]
    )
    let root = Node()
    root.style.flexDirection = .row
    root.style.flexWrap = .wrap
    root.style.gap = 4
    var cardsList: [WrapperCard] = []
    for _ in 0..<cards {
        let card = WrapperCard()
        root.addSubnode(card)
        cardsList.append(card)
    }
    let host = HostHarness()
    host.bridge.skipsLayoutOnlyWrappers = skip
    let before = residentMiB()
    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: 1200, height: 8000),
                scale: 2
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach

    var geometry = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        geometry.add(
            elapsedMs {
                for card in cardsList { card.a.style.height = .points(Double(12 + (i % 3) + 1)) }
                host.waitForCommits(target)
            }
        )
    }
    result.timingsMs["geometry-all-cards-to-commit"] = geometry

    // Commit alone: snapshot + solve + apply + renderer, synchronously, to isolate the
    // renderer's share from the async pipeline.
    var render = Samples()
    let renderer = LayerRenderer()
    renderer.skipsLayoutOnlyWrappers = skip
    let hostLayer = CALayer()
    let request = HostRenderRequest(
        hostID: 42,
        generation: 1,
        treeIdentity: root.id,
        contentRevision: 0,
        environmentRevision: 0,
        bounds: LayoutFrame(width: 1200, height: 8000),
        scale: 2,
        direction: .leftToRight
    )
    renderer.applyCommitted(root: root, on: hostLayer, request: request)  // materialize once
    for _ in 0..<iterations {
        render.add(
            elapsedMs { renderer.applyCommitted(root: root, on: hostLayer, request: request) }
        )
    }
    result.timingsMs["renderer-apply-committed"] = render
    renderer.unmount()

    result.counters["layers"] = host.bridge.materializedLayerCount
    result.counters["nodes"] = 1 + cards * 8
    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-mounted"] = round3(residentMiB())
    host.bridge.detach()
    return result
}

/// A12: 1000 focusable, labelled controls — semantic publish per commit, metadata-only
/// republish for a label burst, sequential and directional focus moves, modal open/close.
/// Counters say what the plan asks to be exact (one publish per burst, no solve, snapshot
/// sizes); timings are evidence for the budget table.
@MainActor
func fixtureSemantics(count: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(name: "semantics-\(count)", parameters: ["controls": count])
    let root = Node()
    root.style {
        $0.flexDirection = .row; $0.flexWrap = .wrap; $0.gap = 4
    }
    var controls: [ControlNode] = []
    for index in 0..<count {
        let control = ControlNode()
        control.style {
            $0.width = 40; $0.height = 24
        }
        control.accessibility.label = "Card \(index)"
        root.addSubnode(control)
        controls.append(control)
    }
    let modalRoot = Node()
    modalRoot.style {
        $0.width = 200; $0.height = 60; $0.flexDirection = .row
    }
    for _ in 0..<2 {
        let button = ControlNode()
        button.style {
            $0.width = 60; $0.height = 40
        }
        button.accessibility.label = "Dialog button"
        modalRoot.addSubnode(button)
    }
    root.addSubnode(modalRoot)
    let host = HostHarness()
    let before = residentMiB()

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: 900, height: 4000),
                scale: 2
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-publish"] = attach
    result.counters["snapshot-records"] = host.bridge.semanticSnapshot?.count ?? -1
    result.counters["tree-leaves"] = host.bridge.accessibilityTree?.readingOrder.count ?? -1

    // Label burst on every control: one metadata-only publish, zero layout requests.
    var burst = Samples()
    for i in 0..<iterations {
        let publishesBefore = host.bridge.metadataOnlyPublishCount
        burst.add(
            elapsedMs {
                for (index, control) in controls.enumerated() {
                    control.accessibility.value = "\(i)-\(index)"
                }
                pump { host.bridge.metadataOnlyPublishCount > publishesBefore }
            }
        )
    }
    result.timingsMs["label-burst-all-to-publish"] = burst
    result.counters["metadata-only-publishes"] = host.bridge.metadataOnlyPublishCount
    result.counters["requested-after-bursts"] = host.bridge.statistics.requested

    // Sequential moves over every candidate, then directional moves.
    var tab = Samples()
    tab.add(
        elapsedMs {
            for _ in 0..<count { _ = host.bridge.moveFocus(.next) }
        }
    )
    result.timingsMs["tab-\(count)-moves"] = tab
    var arrows = Samples()
    for _ in 0..<iterations {
        arrows.add(
            elapsedMs {
                _ = host.bridge.moveFocus(.down)
                _ = host.bridge.moveFocus(.up)
            }
        )
    }
    result.timingsMs["arrow-move-pair"] = arrows

    // Geometry commit with focus set: the engine re-validates, the tree rebuilds.
    var geometry = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        geometry.add(
            elapsedMs {
                for control in controls { control.style.height = .points(Double(25 + (i % 3))) }
                host.waitForCommits(target)
            }
        )
    }
    result.timingsMs["geometry-all-to-commit-with-semantics"] = geometry

    // Modal scope open/close: tree confined and restored, focus restored.
    var modal = Samples()
    for _ in 0..<iterations {
        modal.add(
            elapsedMs {
                host.bridge.setFocusScope(modalRoot.id)
                host.bridge.setFocusScope(nil)
            }
        )
    }
    result.timingsMs["modal-open-close"] = modal

    result.counters["semantic-publishes"] = host.bridge.semanticPublishCount
    result.counters["committed"] = host.bridge.statistics.committed
    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-mounted"] = round3(residentMiB())
    host.bridge.detach()
    result.memoryMiB["resident-detached"] = round3(residentMiB())
    return result
}

// MARK: - T11: text load through the real host pipeline (measure + raster + memory)

/// Waits until every id in `ids` has a committed `DisplayArtifact` — the production drain
/// this card's acceptance calls "after drain, every visible text node has a current artifact".
@MainActor
func waitForAllArtifacts(_ host: HostHarness, _ ids: [NodeID], timeoutMs: Double = 20_000) {
    pump(timeoutMs: timeoutMs) { ids.allSatisfy { host.bridge.displayArtifact(for: $0) != nil } }
}

/// A column of `count` single-line `TextNode`s — the "1000-row list" shape T11 asks for.
/// Attached with a real `CoreTextRenderer` for measurement (T09), matching what a real host
/// does — `DisplayScheduler`'s own rasterizer already defaults to `CoreTextRenderer`
/// regardless, so only measurement would otherwise silently stay on the headless fallback.
@MainActor
func fixtureTextList(count: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(name: "text-list-\(count)", parameters: ["rows": count])
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 320
    var labels: [TextNode] = []
    for index in 0..<count {
        let label = TextNode(text: "Row \(index) — a single line of list text")
        root.addSubnode(label)
        labels.append(label)
    }
    let ids = labels.map(\.id)
    let host = HostHarness()
    let before = residentMiB()

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: 320, height: 40_000),
                scale: 2,
                textRenderer: CoreTextRenderer(),
                localeIdentifier: "en"
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach
    let afterCommit = residentMiB()

    var drain = Samples()
    drain.add(elapsedMs { waitForAllArtifacts(host, ids) })
    result.timingsMs["drain-all-artifacts"] = drain
    let afterDrain = residentMiB()

    // Cost of touching a single row deep in an otherwise-settled 1000-row list — the "live
    // update in a list" shape, distinct from `text-burst-edits`' "every row changes at once".
    var singleEdit = Samples()
    for i in 0..<iterations {
        let target = labels[i % count]
        let completedBefore = host.bridge.displayStatistics.completed
        singleEdit.add(
            elapsedMs {
                target.text = "Row \(i % count) updated at pass \(i)"
                pump { host.bridge.displayStatistics.completed > completedBefore }
            }
        )
    }
    result.timingsMs["single-row-edit-to-artifact"] = singleEdit

    result.counters["with-artifact-after-drain"] =
        ids.filter {
            host.bridge.displayArtifact(for: $0) != nil
        }.count
    let stats = host.bridge.displayStatistics
    result.counters["display-scheduled"] = stats.scheduled
    result.counters["display-completed"] = stats.completed
    result.counters["display-cancelled"] = stats.cancelled
    result.counters["display-dropped"] = stats.dropped
    result.counters["display-stale"] = stats.stale
    result.counters["layers"] = host.bridge.materializedLayerCount

    // D54/T02 §3.1 follow-up: raster memory should grow with committed bitmap area, not with
    // node count independent of it — a fixed-size row list is the "less degenerate scenario"
    // T02 asked T11 to re-measure on (all 1000 artifacts held live at once in the production
    // committed table, not a standalone array).
    let totalPixelBytes = ids.reduce(0) { sum, id in
        guard let artifact = host.bridge.displayArtifact(for: id) else { return sum }
        return sum + artifact.pixelWidth * artifact.pixelHeight * 4
    }
    result.counters["estimated-raster-bytes-rgba"] = totalPixelBytes
    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-after-first-commit"] = round3(afterCommit)
    result.memoryMiB["resident-after-drain"] = round3(afterDrain)
    host.bridge.detach()
    result.memoryMiB["resident-detached"] = round3(residentMiB())
    return result
}

/// One `TextNode` with a long paragraph wrapping in a narrow column — the "5000-character
/// paragraph in a narrow column" shape, the opposite stress from `text-list`: one node, many
/// wrapped lines, instead of many nodes with one line each.
@MainActor
func fixtureTextParagraphNarrow(characters: Int, columnWidth: Double, iterations: Int)
    -> FixtureResult
{
    var result = FixtureResult(
        name: "text-paragraph-narrow",
        parameters: ["characters": characters, "columnWidth": Int(columnWidth)]
    )
    let word = "Trellis "
    let text = String(repeating: word, count: characters / word.count + 1).prefix(characters)
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = .points(columnWidth)
    let label = TextNode(text: String(text))
    root.addSubnode(label)
    let host = HostHarness()

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: columnWidth, height: 40_000),
                scale: 2,
                textRenderer: CoreTextRenderer(),
                localeIdentifier: "en"
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach

    var artifact = Samples()
    artifact.add(elapsedMs { waitForAllArtifacts(host, [label.id]) })
    result.timingsMs["time-to-artifact"] = artifact

    result.counters["measured-height-points"] = Int(label.calculatedFrame?.height ?? -1)
    if let art = host.bridge.displayArtifact(for: label.id) {
        result.counters["raster-pixel-width"] = art.pixelWidth
        result.counters["raster-pixel-height"] = art.pixelHeight
        result.counters["estimated-raster-bytes-rgba"] = art.pixelWidth * art.pixelHeight * 4
    }
    host.bridge.detach()
    return result
}

/// A burst of text changes on many nodes in one turn — coalescing (D53) must turn `count`
/// edits into at most one raster job per node, never one job per edit.
@MainActor
func fixtureTextBurstEdits(count: Int, edits: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(
        name: "text-burst-edits",
        parameters: ["rows": count, "edits-per-row": edits]
    )
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 320
    var labels: [TextNode] = []
    for index in 0..<count {
        let label = TextNode(text: "Row \(index)")
        root.addSubnode(label)
        labels.append(label)
    }
    let ids = labels.map(\.id)
    let host = HostHarness()
    _ = host.bridge.attach(
        root: root,
        bounds: LayoutFrame(width: 320, height: 40_000),
        scale: 2,
        textRenderer: CoreTextRenderer(),
        localeIdentifier: "en"
    )
    host.waitForCommits(1)
    waitForAllArtifacts(host, ids)

    // `waitForAllArtifacts` only checks *existence*, which is already true from the initial
    // drain above before the first edit — checking `completed` count instead is the only way
    // to wait for *this* pass's rasters, not the stale ones already sitting there from before.
    var burst = Samples()
    for pass in 0..<iterations {
        let completedBefore = host.bridge.displayStatistics.completed
        burst.add(
            elapsedMs {
                for round in 0..<edits {
                    for (index, label) in labels.enumerated() {
                        label.text = "Row \(index) edit \(pass)-\(round)"
                    }
                }
                pump { host.bridge.displayStatistics.completed >= completedBefore + count }
            }
        )
    }
    result.timingsMs["burst-to-fully-drained"] = burst

    let stats = host.bridge.displayStatistics
    result.counters["display-scheduled"] = stats.scheduled
    result.counters["display-completed"] = stats.completed
    result.counters["display-dropped"] = stats.dropped
    // If coalescing (D53) held, far fewer jobs completed than the raw edit count — never one
    // committed raster per edit.
    result.counters["raw-edits"] = count * edits * iterations
    host.bridge.detach()
    return result
}

/// 1000 texts mounted, then a resize burst — D65's "resize keeps the old bitmap, clipped, not
/// re-rasterized" contract must hold at this node count, not just for one node
/// (`t07_pureResizeNeverClearsTheBitmapEvenBeforeTheNewOneArrives`).
@MainActor
func fixtureTextResize(count: Int, iterations: Int) -> FixtureResult {
    var result = FixtureResult(name: "text-resize-\(count)", parameters: ["rows": count])
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 320
    var labels: [TextNode] = []
    for index in 0..<count {
        let label = TextNode(text: "Row \(index) — a single line of list text")
        root.addSubnode(label)
        labels.append(label)
    }
    let ids = labels.map(\.id)
    let host = HostHarness()
    _ = host.bridge.attach(
        root: root,
        bounds: LayoutFrame(width: 320, height: 40_000),
        scale: 2,
        textRenderer: CoreTextRenderer(),
        localeIdentifier: "en"
    )
    host.waitForCommits(1)
    waitForAllArtifacts(host, ids)
    let completedBeforeResize = host.bridge.displayStatistics.completed

    var resize = Samples()
    for i in 0..<iterations {
        let target = host.bridge.statistics.committed + 1
        resize.add(
            elapsedMs {
                host.bridge.updateBounds(
                    LayoutFrame(width: Double(280 + (i % 6) * 20), height: 40_000),
                    scale: 2
                )
                host.waitForCommits(target)
            }
        )
    }
    result.timingsMs["resize-all-to-commit"] = resize
    // Width-only resize is still a layout pass (line wrap can change), so new raster jobs are
    // legitimate here — this counter is evidence for the report, not a pass/fail gate; the
    // no-crossfade/keep-old-bitmap invariant itself is `t07`'s job at unit scale.
    result.counters["display-completed-after-resizes"] =
        host.bridge.displayStatistics.completed - completedBeforeResize
    result.counters["committed"] = host.bridge.statistics.committed
    host.bridge.detach()
    return result
}

// MARK: - M08: 1000 layers + text under a real explicit animation (M02/T11 budget check)

/// `count` small cards (a colored background layer + one `TextNode` each — "1000 layers +
/// text", not 1000 bare text nodes like `text-list-1000`), then a real `Node.animate(.smooth)`
/// commit that recolors every card under one list-scope transition (D62) — the S27/S28 scene
/// shape at bench scale. Checks the M02/T11 budget still holds once a commit carries real
/// `AnimationIntent`s and `LayerAnimator` retargets/creates a `CABasicAnimation` per changed
/// property, not just a plain flush.
///
/// `idle-after-animation-settles` polls `NodeHostBridge.sceneReadiness` (M07, D69) rather than a
/// fixed delay — and, unlike the same check inside `swift test` (m02-animation-prototype.md
/// §1.4 found CA's own completion callback never reaches an XCTest-hosted process), Bench is a
/// plain standalone executable: a bounded, non-timing-out result here is itself production
/// evidence that `LayerAnimator.completeIfCurrent` really is reached through a real
/// `CATransaction` completion block outside XCTest, closing the "Playground/manual evidence"
/// half of that open item for at least one real (non-UI-test) host process.
@MainActor
func fixtureAnimatedTextList(
    count: Int,
    iterations: Int,
    timing: Animation = .smooth,
    nameSuffix: String = ""
) -> FixtureResult {
    var result = FixtureResult(
        name: "animated-text-list-\(count)\(nameSuffix)",
        parameters: ["rows": count]
    )
    let dim = ThemeColor(red: 0.12, green: 0.15, blue: 0.22)
    let lit = ThemeColor(red: 0.16, green: 0.32, blue: 0.42)
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 320
    var cards: [Node] = []
    var labels: [TextNode] = []
    for index in 0..<count {
        let card = Node(appearance: VisualStyle(background: .color(dim), cornerRadius: 4))
        card.style.flexDirection = .column
        card.style.padding = DirectionalEdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
        let label = TextNode(text: "Row \(index) — a single line of list text")
        card.addSubnode(label)
        root.addSubnode(card)
        cards.append(card)
        labels.append(label)
    }
    let ids = labels.map(\.id)
    let host = HostHarness()
    let before = residentMiB()

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: 320, height: 40_000),
                scale: 2,
                textRenderer: CoreTextRenderer(),
                localeIdentifier: "en"
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach

    var drain = Samples()
    drain.add(elapsedMs { waitForAllArtifacts(host, ids) })
    result.timingsMs["drain-all-artifacts"] = drain
    let afterDrain = residentMiB()
    result.counters["layers-after-drain"] = host.bridge.materializedLayerCount

    var isLit = false
    var animateCommit = Samples()
    var idleAfter = Samples()
    for _ in 0..<iterations {
        isLit.toggle()
        let color = isLit ? lit : dim
        // A pure `appearance.background` change is a paint-only flush (C09/C29) — it bumps
        // `coalesced`, never `committed` (that counter is geometry-commit only) — so this waits
        // on either counter moving, the same pattern `AnimationCommitLayerTests.swift`'s
        // `waitForPaintOnlyOrCommit` uses for exactly this reason.
        let committedBefore = host.bridge.statistics.committed
        let coalescedBefore = host.bridge.statistics.coalesced
        animateCommit.add(
            elapsedMs {
                // D62: `root` is the shared scope owner of every card — one transition covers
                // all `count` background changes, the same "list.animate" shape S27/S28 use
                // live, at 1000-row scale instead of 3.
                root.animate(timing) {
                    for card in cards { card.appearance.background = .color(color) }
                }
                pump {
                    host.bridge.statistics.committed > committedBefore
                        || host.bridge.statistics.coalesced > coalescedBefore
                }
            }
        )
        idleAfter.add(
            elapsedMs { pump(timeoutMs: 2_000) { host.bridge.sceneReadiness?.isReady == true } }
        )
    }
    result.timingsMs["animated-commit-full-list"] = animateCommit
    result.timingsMs["idle-after-animation-settles"] = idleAfter
    result.counters["scene-ready-after-last-animation"] =
        (host.bridge.sceneReadiness?.isReady == true) ? 1 : 0

    let hostStats = host.bridge.statistics
    result.counters["layout-requested"] = hostStats.requested
    result.counters["layout-coalesced"] = hostStats.coalesced
    result.counters["layout-committed"] = hostStats.committed
    result.counters["layout-retries"] = hostStats.retries
    let displayStats = host.bridge.displayStatistics
    result.counters["display-scheduled"] = displayStats.scheduled
    result.counters["display-completed"] = displayStats.completed
    result.counters["display-cancelled"] = displayStats.cancelled
    result.counters["display-dropped"] = displayStats.dropped
    result.counters["animated-properties-per-commit"] = count

    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-after-drain"] = round3(afterDrain)
    result.memoryMiB["resident-after-animations"] = round3(residentMiB())
    host.bridge.detach()
    result.memoryMiB["resident-detached"] = round3(residentMiB())
    return result
}

// MARK: - M14: composite transition (D70–D74, result B) prepare/arm/cleanup cost

/// M14's own measurement fixture (`docs/implementation-plan-5.md` §6: "замеры подготовки,
/// commit, peak bitmap/layer memory, cleanup" — required even though M10's own report never
/// fixed a numeric budget to compare against, see `docs/validation/m10-transition-contract.md`'s
/// acceptance section and `docs/validation/m14-close-result-b.md`'s honest note about that gap).
///
/// Measures only what `NodeHostBridge`'s *public* API exposes synchronously — `presentTransition`
/// resolves roles and arms the overlay/title-raster layers entirely within the call itself
/// (`buildTransitionVisuals`, `NodeHostBridge.swift`), so "prepare" and "commit" (geometry/raster
/// materialization) are both real synchronous costs, not proxies. What this fixture does *not*
/// measure: the real wall-clock time from `presentTransition` to the session reaching
/// `.presented` (an actual `CABasicAnimation` completion) — M02's and M10's own reports both
/// document that this toolchain's `CATransaction` completion callbacks require a real, already
/// on-screen, warmed-up window (`Tests/TrellisRenderTests/AnimationPrototypeTests.swift`'s/
/// `TransitionOverlayPrototypeTests.swift`'s own `WindowHost`), which `Bench`'s `HostHarness`
/// (a bare `CALayer`, no window) does not have — repeating that limitation here rather than
/// inventing a number. Cycles alternate `presentTransition`/`closeTransition` on the *same*
/// session (D72's retarget path — no second copy of layers is created, `materializedLayerCount`
/// after the loop confirms it), then one final `detach()` measures real cleanup.
@MainActor
func fixtureTransitionOpenClose(cycles: Int) -> FixtureResult {
    var result = FixtureResult(name: "transition-open-close", parameters: ["cycles": cycles])
    let host = HostHarness()

    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 390

    let card = Node()
    card.style.width = 300
    card.style.height = 120
    let cardTitle = TextNode(text: "Weekly digest — a bench fixture card")
    card.addSubnode(cardTitle)
    cardTitle.style.width = 260
    cardTitle.style.height = 40

    let page = Node()
    page.style.width = 390
    page.style.height = 700
    let pageTitle = TextNode(
        text: "Weekly digest — the full bench fixture story, with plenty more room to read"
    )
    page.addSubnode(pageTitle)
    pageTitle.style.width = 350
    pageTitle.style.height = 80

    root.addSubnode(card)
    root.addSubnode(page)

    let before = residentMiB()

    var attach = Samples()
    attach.add(
        elapsedMs {
            _ = host.bridge.attach(
                root: root,
                bounds: LayoutFrame(width: 390, height: 900),
                scale: 2,
                textRenderer: CoreTextRenderer(),
                localeIdentifier: "en"
            )
            host.waitForCommits(1)
        }
    )
    result.timingsMs["attach-to-first-commit"] = attach
    waitForAllArtifacts(host, [cardTitle.id, pageTitle.id])
    let afterDrain = residentMiB()

    let request = NodeHostBridge.TransitionRequest(
        source: card.id,
        destinationRoot: page.id,
        roles: [
            .init(role: .hero, source: card.id, destination: page.id),
            .init(role: .title, source: cardTitle.id, destination: pageTitle.id),
        ],
        duration: .milliseconds(320)
    )

    var prepareAndArm = Samples()
    var closeArm = Samples()
    for _ in 0..<cycles {
        prepareAndArm.add(elapsedMs { _ = host.bridge.presentTransition(request) })
        closeArm.add(elapsedMs { _ = host.bridge.closeTransition() })
    }
    result.timingsMs["present-prepare-and-arm"] = prepareAndArm
    result.timingsMs["close-arm"] = closeArm
    result.counters["layers-during-open-session"] = host.bridge.materializedLayerCount
    let residentDuringSession = residentMiB()

    host.bridge.detach()
    result.counters["layers-after-detach"] = host.bridge.materializedLayerCount

    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-after-drain"] = round3(afterDrain)
    result.memoryMiB["resident-during-open-session"] = round3(residentDuringSession)
    result.memoryMiB["resident-after-detach-cleanup"] = round3(residentMiB())
    result.notes.append(
        "measures synchronous prepare/arm/cleanup cost only, via public API (presentTransition/"
            + "closeTransition/detach); real animation-completion wall-clock (prepare-to-.presented) "
            + "could not be measured headlessly on this toolchain — see docs/validation/"
            + "m14-close-result-b.md"
    )
    return result
}

// MARK: - T02: text raster prototype cost (CoreText → CGImage, D54 candidates)

/// Same minimal raster path as `Tests/TrellisRenderTests/TextRasterPrototypeTests.swift`
/// (T02 prototype, not the T05 production path). Kept standalone here — Bench does not
/// depend on TrellisRenderTests — to measure cost, not to duplicate the API sketch.
func rasterLineForBench(_ text: String, pointSize: CGFloat, scale: CGFloat) -> CGImage {
    let font =
        CTFontCreateUIFontForLanguage(.system, pointSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    let attributed = NSAttributedString(
        string: text,
        attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let size = CGSize(width: width, height: ascent + descent + leading)
    let pixelWidth = max(1, Int((size.width * scale).rounded(.up)))
    let pixelHeight = max(1, Int((size.height * scale).rounded(.up)))
    let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(x: 0, y: descent)
    CTLineDraw(line, context)
    return context.makeImage()!
}

@MainActor
func fixtureTextRaster1000(iterations: Int) -> FixtureResult {
    let lineCount = 1000
    let texts = (0..<lineCount).map { "Row \($0) of the list — Trellis text raster bench" }
    var result = FixtureResult(name: "text-raster-1000", parameters: ["lines": lineCount])

    var rasterizeSamples = Samples()
    var lastBatch: [CGImage] = []
    for _ in 0..<iterations {
        rasterizeSamples.add(
            elapsedMs {
                lastBatch = texts.map { rasterLineForBench($0, pointSize: 15, scale: 2) }
            }
        )
    }
    result.timingsMs["rasterize-1000-lines"] = rasterizeSamples

    // D54 candidate B cost: copying each CGImage's backing store into Data, the extra
    // work the Data-based artifact pays that a direct-CGImage artifact would not (T02
    // confirmed CGImage crosses a `Task.detached` boundary cleanly on the pinned SDK —
    // see docs/validation/t02-raster-prototype.md — so this copy is optional, not required).
    var copySamples = Samples()
    var lastCopies: [Data] = []
    for _ in 0..<iterations {
        copySamples.add(
            elapsedMs {
                lastCopies = lastBatch.map { image -> Data in
                    guard let data = image.dataProvider?.data else { return Data() }
                    return data as Data
                }
            }
        )
    }
    result.timingsMs["copy-1000-to-data"] = copySamples
    result.counters["bytes-per-copy-sample"] = lastCopies.first?.count ?? 0

    let before = residentMiB()
    var heldImages: [CGImage]? = texts.map { rasterLineForBench($0, pointSize: 15, scale: 2) }
    let holdingImages = residentMiB()
    heldImages = nil
    _ = heldImages

    var heldData: [Data]? = texts.map { text in
        let image = rasterLineForBench(text, pointSize: 15, scale: 2)
        return (image.dataProvider?.data).map { $0 as Data } ?? Data()
    }
    let holdingData = residentMiB()
    heldData = nil
    _ = heldData

    result.memoryMiB["resident-before"] = round3(before)
    result.memoryMiB["resident-holding-1000-cgimage"] = round3(holdingImages)
    result.memoryMiB["resident-holding-1000-data-copies"] = round3(holdingData)
    result.notes.append(
        "resident deltas are sequential in one process (allocator noise, not GC-precise); "
            + "compare deltas against resident-before, not absolute values"
    )
    return result
}

// MARK: - Main

@main
struct TrellisBench {
    @MainActor
    static func main() {
        let iterations =
            Int(ProcessInfo.processInfo.environment["TRELLIS_BENCH_ITERATIONS"] ?? "") ?? 20
        let formatter = ISO8601DateFormatter()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var report = Report(
            date: formatter.string(from: Date()),
            host: Host.current().localizedName ?? "unknown",
            os: os,
            configuration: ProcessInfo.processInfo.environment["TRELLIS_BENCH_CONFIGURATION"]
                ?? "unknown",
            logMode: ProcessInfo.processInfo.environment["TRELLIS_LOG"] ?? "(unset)",
            iterations: iterations
        )
        let only = ProcessInfo.processInfo.environment["TRELLIS_BENCH_ONLY"]
        func wants(_ name: String) -> Bool { only == nil || only == name }
        if wants("deep-local-edit") {
            report.fixtures.append(fixtureDeepLocalEdit(iterations: iterations))
        }
        if wants("wide-100") {
            report.fixtures.append(fixtureWide(count: 100, iterations: iterations))
        }
        if wants("wide-1000") {
            report.fixtures.append(fixtureWide(count: 1000, iterations: iterations))
        }
        if wants("attach-detach") {
            report.fixtures.append(fixtureAttachDetach(count: 1000, cycles: iterations))
        }
        if wants("state-burst") {
            report.fixtures.append(
                fixtureStateBurst(count: 1000, sends: 1000, iterations: iterations)
            )
        }
        if wants("two-hosts") {
            report.fixtures.append(fixtureTwoHosts(count: 500, iterations: iterations))
        }
        if wants("cancel-latency") {
            report.fixtures.append(fixtureCancelLatency(iterations: max(5, iterations / 4)))
        }
        if wants("overflow-chain") { report.fixtures.append(fixtureOverflowChain()) }
        if wants("semantics-1000") {
            report.fixtures.append(fixtureSemantics(count: 1000, iterations: iterations))
        }
        if wants("text-raster-1000") {
            report.fixtures.append(fixtureTextRaster1000(iterations: max(3, iterations / 4)))
        }
        if wants("text-list-1000") {
            report.fixtures.append(fixtureTextList(count: 1000, iterations: iterations))
        }
        if wants("text-paragraph-narrow") {
            report.fixtures.append(
                fixtureTextParagraphNarrow(
                    characters: 5000,
                    columnWidth: 160,
                    iterations: iterations
                )
            )
        }
        if wants("text-burst-edits") {
            report.fixtures.append(
                fixtureTextBurstEdits(count: 200, edits: 3, iterations: max(3, iterations / 4))
            )
        }
        if wants("text-resize-1000") {
            report.fixtures.append(fixtureTextResize(count: 1000, iterations: iterations))
        }
        if wants("animated-text-list-1000") {
            report.fixtures.append(
                fixtureAnimatedTextList(count: 1000, iterations: max(3, iterations / 4))
            )
        }
        // M09: same shape, `.snappy` (a real CASpringAnimation) instead of `.smooth` — checks
        // spring construction/settling-duration lookup costs no more than an eased eased curve
        // at 1000-node scale, not just at the single-node scale LayerAnimatorTests exercises.
        if wants("animated-text-list-1000-spring") {
            report.fixtures.append(
                fixtureAnimatedTextList(
                    count: 1000,
                    iterations: max(3, iterations / 4),
                    timing: .snappy,
                    nameSuffix: "-spring"
                )
            )
        }
        // Memory for the two variants is only comparable in separate processes: pass
        // TRELLIS_BENCH_WRAPPERS=with|without to run one alone.
        let variant = ProcessInfo.processInfo.environment["TRELLIS_BENCH_WRAPPERS"]
        if wants("wrappers"), variant != "without" {
            report.fixtures.append(fixtureWrappers(cards: 300, skip: false, iterations: iterations))
        }
        if wants("wrappers"), variant != "with" {
            report.fixtures.append(fixtureWrappers(cards: 300, skip: true, iterations: iterations))
        }
        if wants("transition-open-close") {
            report.fixtures.append(fixtureTransitionOpenClose(cycles: max(10, iterations)))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        // With TRELLIS_LOG on, the log shares stdout; the report then goes to a file.
        if let path = ProcessInfo.processInfo.environment["TRELLIS_BENCH_OUTPUT"] {
            try? data.write(to: URL(fileURLWithPath: path))
        } else if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
