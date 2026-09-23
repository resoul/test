import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// T11 — Нагрузка. Bench (`Bench/Sources/TrellisBench/main.swift`, fixtures `text-list-1000`,
// `text-paragraph-narrow`, `text-burst-edits`, `text-resize-1000`) is evidence, not a gate
// (`Scripts/bench.py`'s own rule: "nothing here fails on a timing"). The acceptance criteria
// that must hold exactly — not just "look reasonable in a report" — are asserted here instead:
// one measurement per unique constraint, a current artifact for every visible text node after
// drain, and no recursion depth tied to tree depth in the measurer.

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<20_000 where bridge.committedCount < count { await Task.yield() }
}

@MainActor
private func waitForAllArtifacts(_ bridge: NodeHostBridge, _ ids: [NodeID]) async {
    for _ in 0..<40_000 where !ids.allSatisfy({ bridge.displayArtifact(for: $0) != nil }) {
        await Task.yield()
    }
}

/// Counts calls into a real `CoreTextRenderer`, from any thread the solver runs its measure
/// pass on (`LayoutScheduler`'s dedicated `Thread`, not MainActor) — a `NSLock` around a plain
/// `Int` rather than `@MainActor` isolation, since `TextRenderer.measure` must stay callable
/// off the main actor (the protocol itself is `Sendable`, not actor-isolated).
final class CountingTextRenderer: TextRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let inner = CoreTextRenderer()

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func measure(_ input: TextLayoutInput, constraint: SizeConstraint, context: LayoutContext)
        throws -> TextMetrics
    {
        lock.lock()
        count += 1
        lock.unlock()
        return try inner.measure(input, constraint: constraint, context: context)
    }
}

@Test @MainActor
func t11_oneThousandTextNodesAreEachMeasuredExactlyOnceForOneFlush() async {
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 320
    for index in 0..<1000 {
        let label = TextNode(text: "Row \(index) — a single line of list text")
        root.addSubnode(label)
    }
    let renderer = CountingTextRenderer()
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 40_000),
            scale: 2,
            textRenderer: renderer,
            localeIdentifier: "en"
        )
    )
    await waitForCommits(bridge, 1)

    // A flat, non-growing column: every `TextNode`'s height comes straight from its own
    // content (no `flexGrow`/`flexShrink` forcing a second exact-main-size pass, unlike
    // `test_contentMeasurer_growingBeyondNaturalSizeRemeasuresAtTheExactGrownConstraint`'s
    // deliberately-grown leaf) — the natural, common shape of a plain list. Each node has
    // exactly one unique `(node, constraint)` state, so `FlexMeasureCache` should let exactly
    // 1000 calls reach the real renderer: any number above that is redundant measurement work
    // repeated 1000× over, exactly the kind of bug this acceptance criterion exists to catch.
    #expect(renderer.callCount == 1000)

    // A second flush at the same size and content (a no-op paint request) must not re-measure
    // anything at all — zero additional calls, not "still exactly 1000 more".
    bridge.updateBounds(LayoutFrame(width: 320, height: 40_000), scale: 2)
    await Task.yield()
    #expect(renderer.callCount == 1000)
}

@Test @MainActor
func t11_afterDrainEveryVisibleTextNodeHasACurrentArtifact() async {
    let root = Node()
    root.style.flexDirection = .column
    root.style.width = 320
    var labels: [TextNode] = []
    for index in 0..<1000 {
        let label = TextNode(text: "Row \(index) — a single line of list text")
        root.addSubnode(label)
        labels.append(label)
    }
    let ids = labels.map(\.id)
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)

    #expect(
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 320, height: 40_000),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
    )
    await waitForCommits(bridge, 1)
    await waitForAllArtifacts(bridge, ids)

    #expect(ids.allSatisfy { bridge.displayArtifact(for: $0) != nil })
    #expect(bridge.displayStatistics.completed == 1000)
    #expect(bridge.displayStatistics.cancelled == 0)
}

@Test @MainActor
func t11_deepChainWithATextLeafCommitsWithoutStackOverflow() async {
    // Defect #45 (docs/defects.md): defect #22's "3000 уровней ок" bound only covers the
    // solve's own recursion, which is why it runs on a dedicated 16 MiB `Thread`
    // (`LayoutScheduler`). `RenderCoordinator.flush()` builds the input snapshot
    // (`Node.makeLayoutInputSnapshot`) and applies the result (`Node.applyLayoutResult`) — both
    // still recursive over tree depth — synchronously on the ordinary MainActor thread, which
    // does not get the enlarged stack. A probe (no `TextNode` involved at all) crashed the
    // whole test process (SIGSEGV) through the real `NodeHostBridge` pipeline between depth
    // 1500 (passed) and 1600 (crashed) on this machine/debug build — a materially lower ceiling
    // than #22's, and one this card cannot fix (it would mean making several MainActor-side
    // tree walks iterative, well beyond "Нагрузка"'s measurement scope). This test only checks
    // the acceptance this card actually owns — a `TextNode` leaf does not lower that ceiling
    // any further by adding its own extra recursion in the measurer — so it stays well under
    // the discovered boundary rather than re-probing it.
    let depth = 800
    let root = Node()
    root.style.flexDirection = .column
    var current = root
    for _ in 0..<depth {
        let next = Node()
        next.style.flexDirection = .column
        current.addSubnode(next)
        current = next
    }
    let label = TextNode(text: "Deep leaf")
    current.addSubnode(label)

    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)
    #expect(
        bridge.attach(
            root: root,
            bounds: LayoutFrame(width: 200, height: 200),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
    )
    await waitForCommits(bridge, 1)

    #expect(label.calculatedFrame != nil)
    #expect(bridge.statistics.committed == 1)
}

@Test @MainActor
func t11_rasterByteCountScalesWithCommittedPixelAreaNotWithAFixedPerNodeOverhead() async {
    // "Память растров линейна по площади" — checked at the unit this actually holds at:
    // `DisplayArtifact`'s own pixel dimensions are `ceil(size * scale)` by construction
    // (`DisplayArtifact.init`), so a column twice as wide must report roughly twice the byte
    // count for the same single line of text, not a size-independent constant.
    let hostLayer = CALayer()
    let narrowRoot = Node()
    narrowRoot.style.flexDirection = .column
    narrowRoot.style.width = 160
    let narrowLabel = TextNode(text: "Hi")
    narrowRoot.addSubnode(narrowLabel)
    let narrowBridge = NodeHostBridge(hostLayer: hostLayer)
    #expect(
        narrowBridge.attach(
            root: narrowRoot,
            bounds: LayoutFrame(width: 160, height: 200),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
    )
    await waitForCommits(narrowBridge, 1)
    await waitForAllArtifacts(narrowBridge, [narrowLabel.id])
    let narrowArtifact = narrowBridge.displayArtifact(for: narrowLabel.id)!
    narrowBridge.detach()

    let wideHostLayer = CALayer()
    let wideRoot = Node()
    wideRoot.style.flexDirection = .column
    wideRoot.style.width = 320
    let wideLabel = TextNode(text: "Hi")
    wideRoot.addSubnode(wideLabel)
    let wideBridge = NodeHostBridge(hostLayer: wideHostLayer)
    #expect(
        wideBridge.attach(
            root: wideRoot,
            bounds: LayoutFrame(width: 320, height: 200),
            scale: 2,
            textRenderer: CoreTextRenderer(),
            localeIdentifier: "en"
        )
    )
    await waitForCommits(wideBridge, 1)
    await waitForAllArtifacts(wideBridge, [wideLabel.id])
    let wideArtifact = wideBridge.displayArtifact(for: wideLabel.id)!
    wideBridge.detach()

    let narrowBytes = narrowArtifact.pixelWidth * narrowArtifact.pixelHeight * 4
    let wideBytes = wideArtifact.pixelWidth * wideArtifact.pixelHeight * 4
    #expect(wideArtifact.pixelWidth == narrowArtifact.pixelWidth * 2)
    #expect(wideBytes == narrowBytes * 2)
}
