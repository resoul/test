import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// Defects #11 (labels independent of NodeID for reference screenshots) and #12 (labels that
// are shown never overlap or leave the canvas).

@MainActor
private func waitForCommits(_ bridge: NodeHostBridge, _ count: Int) async {
    for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
}

private struct ShownLabel {
    let text: String
    /// In root coordinates.
    let frame: CGRect
}

@MainActor
private func overlayLabels(on host: CALayer) -> (outlines: Int, shown: [ShownLabel]) {
    let outlines = (host.sublayers ?? [])
        .filter { $0.name == "trellis.debug-overlay" }
        .flatMap { $0.sublayers ?? [] }
        .filter { $0.name == "trellis.debug-outline" }
    var shown: [ShownLabel] = []
    for outline in outlines {
        for case let label as CATextLayer in outline.sublayers ?? [] where !label.isHidden {
            shown.append(
                ShownLabel(
                    text: label.string as? String ?? "",
                    frame: label.frame.offsetBy(dx: outline.frame.minX, dy: outline.frame.minY)
                )
            )
        }
    }
    return (outlines.count, shown)
}

private func noneOverlap(_ labels: [ShownLabel]) -> Bool {
    for (index, label) in labels.enumerated() {
        for other in labels[(index + 1)...] where label.frame.intersects(other.frame) {
            return false
        }
    }
    return true
}

/// A row of `count` narrow, tall siblings — the S19 shape where labels overlapped.
@MainActor
private func makeNarrowRow(count: Int, width: Double = 12) -> Node {
    let root = Node()
    root.style.flexDirection = .row
    for _ in 0..<count {
        let leaf = Node()
        leaf.style.width = .points(width)
        leaf.style.height = 60
        root.addSubnode(leaf)
    }
    return root
}

@Test(arguments: [1.0, 2.0])
@MainActor
func test_debugOverlay_shownLabelsNeverOverlapNorLeaveTheCanvas(scale: Double) async throws {
    let root = makeNarrowRow(count: 8)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    // .treeOrder keeps every label's text at a fixed short width ("n1".."n9"); .runtimeID
    // (the default) embeds the process-global NodeID counter, whose digit count grows with
    // every node any test in the process has ever created, making the fixed-canvas fit
    // assertions below order-dependent (defect #29) rather than a property of this layout.
    bridge.debugOverlayLabelStyle = .treeOrder
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 80), scale: scale))
    await waitForCommits(bridge, 1)
    bridge.isDebugOverlayEnabled = true

    let (outlines, shown) = overlayLabels(on: host)
    #expect(outlines == 9)
    #expect(noneOverlap(shown))
    let canvas = CGRect(x: 0, y: 0, width: 200, height: 80)
    #expect(shown.allSatisfy { canvas.contains($0.frame) })
    // Adjacent 12 pt siblings at one depth take successive rows down their 60 pt outlines,
    // so all eight fit with their full text; the root's label moves to a free corner.
    #expect(shown.count == 9)
    #expect(shown.filter { $0.text.contains("12×60") }.count == 8)
    #expect(shown.contains { $0.text == "n1 200×80" })
}

@Test
@MainActor
func test_debugOverlay_hidesTextWithoutRoomButKeepsTheOutline() async throws {
    // 20 siblings in a 90×30 host: not every label can be shown.
    let root = makeNarrowRow(count: 20, width: 4)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 90, height: 30), scale: 2))
    await waitForCommits(bridge, 1)
    bridge.isDebugOverlayEnabled = true

    let (outlines, shown) = overlayLabels(on: host)
    #expect(outlines == 21)
    #expect(shown.count < 21)
    #expect(!shown.isEmpty)
    #expect(noneOverlap(shown))
    #expect(shown.allSatisfy { CGRect(x: 0, y: 0, width: 90, height: 30).contains($0.frame) })
}

@Test
@MainActor
func test_debugOverlay_coincidingParentAndChildFramesGetSeparateLabels() async throws {
    // A column whose only child is stretched to the same frame: the child (deeper) keeps the
    // top-left corner, the parent moves to the row below.
    let root = Node()
    root.style.flexDirection = .column
    let child = Node()
    child.style.flexGrow = 1
    root.addSubnode(child)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 120, height: 60), scale: 1))
    await waitForCommits(bridge, 1)
    #expect(child.calculatedFrame == root.calculatedFrame)
    bridge.isDebugOverlayEnabled = true

    let (_, shown) = overlayLabels(on: host)
    #expect(shown.count == 2)
    #expect(noneOverlap(shown))
    let childLabel = try #require(shown.first { $0.text == "\(child.id) 120×60" })
    let rootLabel = try #require(shown.first { $0.text == "\(root.id) 120×60" })
    #expect(childLabel.frame.minY == 0)
    #expect(rootLabel.frame.minY == childLabel.frame.maxY)
}

@Test
@MainActor
func test_debugOverlay_repeatedApplyGivesTheSamePlacement() async throws {
    let root = makeNarrowRow(count: 6)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 80), scale: 2))
    await waitForCommits(bridge, 1)
    bridge.isDebugOverlayEnabled = true
    let first = overlayLabels(on: host).shown

    // A paint-only change redraws the overlay after its commit; geometry is unchanged.
    root.subnodes[0].appearance.background = .color(ThemeColor(red: 1, green: 0, blue: 0))
    await waitForCommits(bridge, 2)
    let second = overlayLabels(on: host).shown

    #expect(first.map(\.text) == second.map(\.text))
    #expect(first.map(\.frame) == second.map(\.frame))
}

@Test
@MainActor
func test_debugOverlay_treeOrderLabelsDoNotDependOnNodeIDs() async throws {
    @MainActor func makeTree() -> Node {
        let root = Node()
        root.style.flexDirection = .column
        let a = Node()
        a.style.width = 40
        a.style.height = 20
        let b = Node()
        b.style.width = 30
        b.style.height = 10
        root.addSubnode(a)
        root.addSubnode(b)
        return root
    }
    @MainActor func labels(_ root: Node, style: DebugOverlayLabelStyle) async -> [String] {
        let host = CALayer()
        let bridge = NodeHostBridge(hostLayer: host)
        bridge.debugOverlayLabelStyle = style
        _ = bridge.attach(root: root, bounds: LayoutFrame(width: 100, height: 100), scale: 2)
        await waitForCommits(bridge, 1)
        bridge.isDebugOverlayEnabled = true
        return overlayLabels(on: host).shown.map(\.text).sorted()
    }

    let first = makeTree()
    // Unrelated allocations in between — another scene, a node added to it — shift every
    // later NodeID.
    for _ in 0..<7 { _ = Node() }
    let second = makeTree()

    let firstOrder = await labels(first, style: .treeOrder)
    let secondOrder = await labels(second, style: .treeOrder)
    #expect(firstOrder == secondOrder)
    #expect(firstOrder == ["n1 100×100", "n2 40×20", "n3 30×10"])

    // The interactive style still shows the runtime identity, which did shift.
    let firstRuntime = await labels(first, style: .runtimeID)
    let secondRuntime = await labels(second, style: .runtimeID)
    #expect(firstRuntime != secondRuntime)
    #expect(firstRuntime.contains("\(first.id) 100×100"))
    #expect(secondRuntime.contains("\(second.id) 100×100"))
}

@Test
@MainActor
func test_debugOverlay_labelStyleSwitchRedrawsWithoutACommit() async throws {
    let root = makeNarrowRow(count: 2)
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 200, height: 80), scale: 2))
    await waitForCommits(bridge, 1)
    bridge.isDebugOverlayEnabled = true
    #expect(overlayLabels(on: host).shown.contains { $0.text == "\(root.id) 200×80" })

    bridge.debugOverlayLabelStyle = .treeOrder

    #expect(bridge.committedCount == 1)
    #expect(overlayLabels(on: host).shown.contains { $0.text == "n1 200×80" })
}

@Test
func test_debugOverlayLabelLayout_isDeterministicAndKeepsLabelsInsideTheCanvas() {
    typealias Candidate = DebugOverlayLabelLayout.Candidate
    let canvas = CGSize(width: 100, height: 40)
    let candidates = [
        // A container at the canvas origin: no "above" row exists for it.
        Candidate(
            outline: CGRect(x: 0, y: 0, width: 100, height: 40),
            depth: 0,
            order: 0,
            fullText: "#1 100×40",
            shortText: "#1"
        ),
        // A narrow node at the right edge: its full text would leave the canvas from every
        // position, so only the short text can be shown.
        Candidate(
            outline: CGRect(x: 90, y: 0, width: 10, height: 40),
            depth: 1,
            order: 1,
            fullText: "#2 10×40 with a long label",
            shortText: "#2"
        ),
    ]

    let first = DebugOverlayLabelLayout.place(candidates, canvas: canvas, fontSize: 9)
    let second = DebugOverlayLabelLayout.place(candidates, canvas: canvas, fontSize: 9)

    #expect(first == second)
    let bounds = CGRect(origin: .zero, size: canvas)
    #expect(first.compactMap { $0 }.allSatisfy { bounds.contains($0.frame) })
    #expect(first[1]?.text == "#2")
    #expect(first[0]?.text == "#1 100×40")
    #expect(first[0]?.frame.minY == 0)
    #expect(noneOverlap(first.compactMap { $0 }.map { ShownLabel(text: $0.text, frame: $0.frame) }))
}
