import Foundation
import TrellisCore
import TrellisRender

#if canImport(AppKit)
    import TrellisAppKit
#else
    import TrellisUIKit
#endif

// R06 §6.1: the one concrete perf fixture that proves `PerfRecorder`'s pipeline works end to
// end inside a real app process — the thing Bench's bare-`CALayer` harness cannot stand in for
// ("CLI Bench не выдаётся за замер UIKit scrolling"). `ScrollNode` does not exist yet (that is
// R07+), so this measures what already exists at scale through the real `TrellisHostView`
// attached to this app's actual window: attach-to-ready and resize-to-relayout, the same shape
// as Bench's own `text-list`/`wide` fixtures, but from inside `Playground/iOS`, `Playground/
// tvOS`, `Playground/macOS` rather than a standalone executable with no window.

/// Deterministic pseudo-random row-text lengths from `PerfLaunchConfiguration.seed` — the
/// reproducibility the plan's launch configuration promises actually changes something
/// observable, not just a recorded-but-unused number.
private struct PerfLCG {
    var state: UInt64
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(1, upperBound)))
    }
}

/// Runs the fixture and returns the finished report; does not write it anywhere — that is the
/// caller's job (a file for `xcrun simctl`/device pull, stdout for a quick manual check).
///
/// Ownership: `host` is borrowed for the run and detached before returning. Isolation:
/// MainActor throughout. Errors: none — a fixture that cannot commit contributes an empty
/// series rather than throwing, matching AGENTS.md's "незакрытые пункты называются
/// незакрытыми" (a report says so via zero counts, it does not crash the harness).
/// Cancellation: not applicable — the run is a bounded, synchronous-per-sample loop.
@MainActor
public func runPerfTextListFixture(
    host: TrellisHostView,
    configuration: PerfLaunchConfiguration
) async -> PerfReport {
    let environment = PerfEnvironment(sourceRevision: configuration.sourceRevision)
    var report = PerfReport(
        environment: environment,
        warmupIterations: configuration.warmupIterations,
        repeatIterations: configuration.repeatIterations
    )
    var fixture = PerfFixtureResult(
        name: "app-text-list-\(configuration.itemCount)",
        parameters: [
            "rows": configuration.itemCount,
            "viewportWidth": Int(configuration.viewportWidth),
            "viewportHeight": Int(configuration.viewportHeight),
            "seed": Int(configuration.seed % UInt64(Int.max)),
        ]
    )

    let root = Node()
    root.style.flexDirection = .column
    root.style.width = .points(configuration.viewportWidth)
    var rng = PerfLCG(state: configuration.seed)
    var labels: [TextNode] = []
    for index in 0..<configuration.itemCount {
        let padding = String(repeating: "· ", count: rng.next(6))
        let label = TextNode(text: "Row \(index) \(padding)— R06 perf harness synthetic content")
        root.addSubnode(label)
        labels.append(label)
    }

    let residentBefore = PerfMemory.residentMiB()
    var attach = PerfSamples()
    attach.add(perfElapsedMs { host.attach(root: root) })
    await waitForRenderReady(root: root, host: host)
    fixture.timingsMs["attach-to-ready"] = attach

    // Warm-up iterations run through the exact same path but are excluded from the recorded
    // series — the plan's own "warmup/repeats" distinction (§6.1), so first-call JIT/cache
    // effects do not skew the percentiles R15 later compares against. Measures request-to-
    // *commit*, not just the synchronous call that requests it: layout solves on
    // `LayoutScheduler`'s own worker and commits later on MainActor (same reason Bench's own
    // `resize-to-commit` fixture polls `statistics.committed` instead of timing the request
    // call alone, which would only measure how fast the request was enqueued).
    var resize = PerfSamples()
    for i in 0..<(configuration.warmupIterations + configuration.repeatIterations) {
        // `-10` guarantees the very first resize actually changes the width: an equal width
        // is a no-op that never commits (same convention as `Bench`'s own resize fixtures),
        // which would otherwise hang this loop forever on iteration 0.
        let width = configuration.viewportWidth - 10 - Double(i % 5) * 10
        let target = (host.hostBridge?.statistics.committed ?? 0) + 1
        let start = DispatchTime.now().uptimeNanoseconds
        host.frame.size.width = width
        #if canImport(AppKit)
            host.needsLayout = true
        #else
            host.setNeedsLayout()
        #endif
        // `Task.yield()`, not a manual `RunLoop.main.run(until:)` pump (unavailable from an
        // async context, and unnecessary here): unlike `Bench`'s standalone process, this app's
        // own `UIApplication`/`NSApplication` run loop is already spinning, so yielding lets
        // its MainActor work (the coordinator's flush, the commit callback) actually run.
        let deadline = start + UInt64(2_000 * 1_000_000)  // 2s bound — never hang the harness
        while (host.hostBridge?.statistics.committed ?? 0) < target {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                fixture.notes.append(
                    "resize-to-commit: iteration \(i) timed out waiting for commit"
                )
                break
            }
            await Task.yield()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if i >= configuration.warmupIterations { resize.add(elapsed) }
    }
    fixture.timingsMs["resize-to-commit"] = resize

    fixture.counters["nodes"] = configuration.itemCount + 1
    fixture.counters["resident-mib-before"] = Int(residentBefore)
    fixture.counters["resident-mib-after"] = Int(PerfMemory.residentMiB())
    fixture.counters["peak-resident-mib"] = Int(PerfMemory.peakResidentMiB())

    report.fixtures.append(fixture)
    host.detach()
    return report
}

/// Entry point every `Playground/*/PlaygroundApp.swift` calls right after creating its window
/// and host. Returns `true` when `--perf-run` was present (the caller should skip its normal
/// scenario UI and let the `Task` below terminate the app once the report is written) and
/// `false` otherwise (normal scenario browsing continues unaffected — every existing launch
/// path is unchanged when the flag is absent).
///
/// Ownership: `host` is borrowed for the run. Isolation: MainActor. Errors: a write failure to
/// `--perf-output` is silently skipped — the report still prints to stdout so a caller watching
/// the process log is not left with nothing. Cancellation: not applicable; `terminate` runs
/// unconditionally once the fixture finishes.
@MainActor
@discardableResult
public func runPerfHarnessIfRequested(
    host: TrellisHostView,
    terminate: @escaping @MainActor () -> Void
) -> Bool {
    let configuration = PerfLaunchConfiguration()
    guard configuration.isRequested else { return false }
    Task { @MainActor in
        let report =
            configuration.scenario == "collections"
            ? await runPerfCollectionsFixture(host: host, configuration: configuration)
            : await runPerfTextListFixture(host: host, configuration: configuration)
        if let path = configuration.outputPath {
            let jsonURL = URL(fileURLWithPath: path)
            try? report.jsonData().write(to: jsonURL)
            let csvURL = jsonURL.deletingPathExtension().appendingPathExtension("csv")
            try? report.csvText().write(to: csvURL, atomically: true, encoding: .utf8)
            print("PERFHARNESS wrote \(jsonURL.path) and \(csvURL.path)")
        } else if let text = String(data: report.jsonData(), encoding: .utf8) {
            print("PERFHARNESS \(text)")
        }
        terminate()
    }
    return true
}

// MARK: - R12: collection containers (cold/warm scroll, reversal, open/close cycles)

private struct PerfRow: Sendable, Equatable {
    let text: String
}

/// Rows with a real `TextNode` of seeded length, so measurement and raster are part of every
/// newly materialized row.
@MainActor
private final class PerfRowProvider: ItemProvider {
    private(set) var made = 0

    func makeNode(for item: PerfRow, id: Int) -> Node {
        made += 1
        let row = Node()
        row.style.flexDirection = .column
        row.style.padding = DirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        row.addSubnode(TextNode(text: item.text))
        return row
    }

    func update(_ node: Node, with item: PerfRow, id: Int) {
        (node.subnodes.first as? TextNode)?.text = item.text
    }
}

/// A mounted container seen through closures, so list, grid and table share one driver.
@MainActor
private struct PerfContainer {
    let node: Node
    let scrollNode: ScrollNode
    let provider: PerfRowProvider
    let materialized: () -> Int
    let visibleIDs: () -> [Int]
    let isLaidOut: (Int) -> Bool
    let totalExtent: () -> Double
}

@MainActor
private func makePerfContainer(
    _ kind: String,
    items: [CollectionItem<Int, PerfRow>],
    viewport: (width: Double, height: Double)
) -> PerfContainer {
    var style = LayoutStyle()
    style.width = .points(viewport.width)
    style.height = .points(viewport.height)
    let source = StateSubject(CollectionSnapshot(dataKey: "perf", revision: 1, items: items))
    let provider = PerfRowProvider()
    switch kind {
    case "grid":
        let grid = GridNode(
            source: source,
            provider: provider,
            layout: GridLayout(columns: .adaptive(minimumWidth: 160), columnSpacing: 8),
            rowSpacing: 8,
            estimatedRowHeight: 60,
            style: style
        )
        return PerfContainer(
            node: grid,
            scrollNode: grid.scrollNode,
            provider: provider,
            materialized: { grid.window.materializedIDs.count },
            visibleIDs: { grid.window.visibleIDs },
            isLaidOut: { grid.window.node(for: $0)?.calculatedFrame != nil },
            totalExtent: { grid.window.extents.totalExtent }
        )
    case "table":
        let table = TableNode(source: source, provider: provider, style: style)
        return PerfContainer(
            node: table,
            scrollNode: table.scrollNode,
            provider: provider,
            materialized: { table.window.materializedIDs.count },
            visibleIDs: { table.window.visibleIDs },
            isLaidOut: { table.window.node(for: $0)?.calculatedFrame != nil },
            totalExtent: { table.window.extents.totalExtent }
        )
    default:
        let list = ListNode(source: source, provider: provider, style: style)
        return PerfContainer(
            node: list,
            scrollNode: list.scrollNode,
            provider: provider,
            materialized: { list.window.materializedIDs.count },
            visibleIDs: { list.window.visibleIDs },
            isLaidOut: { list.window.node(for: $0)?.calculatedFrame != nil },
            totalExtent: { list.window.extents.totalExtent }
        )
    }
}

/// Waits until every visible item has a committed frame and display is ready; `false` after
/// `timeoutMs`.
@MainActor
private func waitForVisibleRows(
    _ container: PerfContainer,
    host: TrellisHostView,
    afterCommit target: Int,
    timeoutMs: UInt64 = 2_000
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let committed = host.hostBridge?.statistics.committed ?? 0
        let visible = container.visibleIDs()
        if committed >= target, !visible.isEmpty, visible.allSatisfy(container.isLaidOut),
            host.sceneReadiness?.displayReady ?? true
        {
            return true
        }
        await Task.yield()
    }
    return false
}

/// R12 fixture (`--perf-scenario collections`): ListNode, GridNode and TableNode over
/// `itemCount` models with real text rows. Per container: cold open (first attach to visible
/// rows committed), a cold and a warm scroll pass of 40 forward steps of 0.75 viewport and 20
/// reversed steps (command → the commit showing the new visible rows), then `repeatIterations`
/// × 5 open/close cycles of a fresh container with memory and live-node counters. Timings are
/// request-to-commit on this host; frame drops need an Instruments trace (§6).
@MainActor
public func runPerfCollectionsFixture(
    host: TrellisHostView,
    configuration: PerfLaunchConfiguration
) async -> PerfReport {
    var report = PerfReport(
        environment: PerfEnvironment(sourceRevision: configuration.sourceRevision),
        warmupIterations: configuration.warmupIterations,
        repeatIterations: configuration.repeatIterations
    )
    var rng = PerfLCG(state: configuration.seed)
    let items = (0..<configuration.itemCount).map { index in
        let words = String(repeating: "lorem ipsum ", count: 1 + rng.next(8))
        return CollectionItem(id: index, value: PerfRow(text: "Row \(index) \(words)"))
    }
    let viewport = (width: configuration.viewportWidth, height: configuration.viewportHeight)

    for kind in ["list", "grid", "table"] {
        var fixture = PerfFixtureResult(
            name: "app-collections-\(kind)-\(configuration.itemCount)",
            parameters: [
                "items": configuration.itemCount,
                "viewportWidth": Int(viewport.width),
                "viewportHeight": Int(viewport.height),
                "seed": Int(configuration.seed % UInt64(Int.max)),
            ]
        )
        let root = Node()
        root.style.flexDirection = .column
        let container = makePerfContainer(kind, items: items, viewport: viewport)
        root.addSubnode(container.node)

        var open = PerfSamples()
        let target = (host.hostBridge?.statistics.committed ?? 0) + 1
        let start = DispatchTime.now().uptimeNanoseconds
        host.attach(root: root)
        if !(await waitForVisibleRows(container, host: host, afterCommit: target)) {
            fixture.notes.append("cold-open: timed out")
        }
        open.add(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        fixture.timingsMs["cold-open-to-visible"] = open

        var maximumLive = container.materialized()
        for pass in ["cold", "warm"] {
            var forward = PerfSamples()
            var reverse = PerfSamples()
            var offset = 0.0
            for step in 0..<60 {
                let backward = step >= 40
                let limit = max(0, container.totalExtent() - viewport.height)
                offset = min(limit, max(0, offset + (backward ? -0.75 : 0.75) * viewport.height))
                let target = (host.hostBridge?.statistics.committed ?? 0) + 1
                let begin = DispatchTime.now().uptimeNanoseconds
                host.hostBridge?.scroll(
                    .to(LayoutPoint(x: 0, y: offset), animated: false),
                    on: container.scrollNode,
                    completion: nil
                )
                if !(await waitForVisibleRows(container, host: host, afterCommit: target)) {
                    fixture.notes.append("\(pass) step \(step): timed out")
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
                if backward { reverse.add(elapsed) } else { forward.add(elapsed) }
                maximumLive = max(maximumLive, container.materialized())
            }
            fixture.timingsMs["\(pass)-scroll-step-to-commit"] = forward
            fixture.timingsMs["\(pass)-reversal-step-to-commit"] = reverse
        }
        fixture.counters["max-live-items"] = maximumLive
        fixture.counters["items-made"] = container.provider.made
        host.detach()
        root.dispose()

        // Open/close cycles: a fresh container each time, like reopening a screen.
        let cycles = max(1, configuration.repeatIterations * 5)
        let residentBefore = PerfMemory.residentMiB()
        var reopen = PerfSamples()
        var leakedLive = 0
        for _ in 0..<cycles {
            let root = Node()
            root.style.flexDirection = .column
            let container = makePerfContainer(kind, items: items, viewport: viewport)
            root.addSubnode(container.node)
            let target = (host.hostBridge?.statistics.committed ?? 0) + 1
            let start = DispatchTime.now().uptimeNanoseconds
            host.attach(root: root)
            _ = await waitForVisibleRows(container, host: host, afterCommit: target)
            reopen.add(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            host.detach()
            leakedLive = max(leakedLive, host.hostBridge?.materializationBudget.liveNodeCount ?? 0)
            root.dispose()
        }
        fixture.timingsMs["warm-open-to-visible"] = reopen
        fixture.counters["open-close-cycles"] = cycles
        fixture.counters["live-items-after-close"] = leakedLive
        fixture.counters["bindings-after-close"] = host.hostBridge?.bindingCount ?? -1
        fixture.counters["resident-mib-before-cycles"] = Int(residentBefore)
        fixture.counters["resident-mib-after-cycles"] = Int(PerfMemory.residentMiB())
        fixture.counters["peak-resident-mib"] = Int(PerfMemory.peakResidentMiB())
        report.fixtures.append(fixture)
    }
    return report
}
