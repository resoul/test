import Testing

@testable import TrellisCore

// T04 (implementation-plan-4.md §5, D55/D56/D52): TextNode's no-op equality, the
// geometry/display revision split, and that a captured snapshot holds no live Node. Integration
// through RenderCoordinator/NodeHostBridge (flush counts, dispose) is
// Tests/TrellisRenderTests/TextNodeInvalidationTests.swift.

@Test @MainActor
func t04_settingTheSameTextIsANoOp() {
    let node = TextNode(text: "Hello")
    let revisionBefore = node.geometryRevision

    node.text = "Hello"

    #expect(node.geometryRevision == revisionBefore)
}

@Test @MainActor
func t04_settingDifferentTextBumpsGeometryRevisionNotDisplayRevision() {
    let node = TextNode(text: "Hello")
    let geometryBefore = node.geometryRevision
    let displayBefore = node.displayRevision

    node.text = "Goodbye"

    #expect(node.geometryRevision == geometryBefore + 1)
    #expect(node.displayRevision == displayBefore)
}

@Test @MainActor
func t04_colorOnlyStyleChangeBumpsDisplayRevisionNotGeometryRevision() {
    let node = TextNode(text: "Hello")
    let geometryBefore = node.geometryRevision
    let displayBefore = node.displayRevision

    node.textStyle.color = ThemeColor(red: 0, green: 0, blue: 1)

    #expect(node.displayRevision == displayBefore + 1)
    #expect(node.geometryRevision == geometryBefore)
}

@Test @MainActor
func t04_nonColorStyleChangeBumpsGeometryRevisionNotDisplayRevision() {
    let node = TextNode(text: "Hello")
    let geometryBefore = node.geometryRevision
    let displayBefore = node.displayRevision

    node.textStyle.pointSize = 24

    #expect(node.geometryRevision == geometryBefore + 1)
    #expect(node.displayRevision == displayBefore)
}

@Test @MainActor
func t04_settingTheSameStyleColorAgainIsANoOp() {
    let node = TextNode(text: "Hello")
    node.textStyle.color = ThemeColor(red: 0, green: 0, blue: 1)
    let displayBefore = node.displayRevision

    node.textStyle.color = ThemeColor(red: 0, green: 0, blue: 1)

    #expect(node.displayRevision == displayBefore)
}

@Test @MainActor
func t04_maxLinesAndTruncationHaveNoOpEqualityAndBumpGeometryWhenChanged() {
    let node = TextNode(text: "Hello", maxLines: 2, truncation: .tail)
    let geometryBefore = node.geometryRevision

    node.maxLines = 2
    node.truncation = .tail
    #expect(node.geometryRevision == geometryBefore)

    node.maxLines = 3
    #expect(node.geometryRevision == geometryBefore + 1)

    node.truncation = .clip
    #expect(node.geometryRevision == geometryBefore + 2)
}

@Test @MainActor
func t04_snapshotMeasurerDoesNotRetainTheNode() {
    weak var weakNode: TextNode?
    var measurer: (any ContentMeasurer)?

    do {
        let node = TextNode(text: "Hello, Trellis")
        weakNode = node
        measurer = node.layoutContentMetrics(for: SizeConstraint()).measurer
    }

    #expect(weakNode == nil)
    #expect(measurer != nil)
}

@Test @MainActor
func t04_measurerIdentityIsStableAcrossRepeatedSnapshotsOfTheSameNode() {
    let node = TextNode(text: "Hello")

    let first = node.layoutContentMetrics(for: SizeConstraint()).measurer
    let second = node.layoutContentMetrics(for: SizeConstraint(width: .exact(50)))
        .measurer

    #expect(first?.identity == second?.identity)
}

@Test @MainActor
func t04_measurerRevisionAdvancesOnlyAfterAGeometryAffectingChange() {
    let node = TextNode(text: "Hello")
    let before = node.layoutContentMetrics(for: SizeConstraint()).measurer?.revision

    node.textStyle.color = ThemeColor(red: 1, green: 1, blue: 1)
    let afterColorOnly = node.layoutContentMetrics(for: SizeConstraint()).measurer?.revision
    #expect(afterColorOnly == before)

    node.text = "Different text"
    let afterTextChange = node.layoutContentMetrics(for: SizeConstraint()).measurer?.revision
    #expect(afterTextChange != before)
}

@Test @MainActor
func t04_textNodeIntegratesWithTheSolverThroughTheFallbackMeasurer() throws {
    // No TextRendererKey installed (no host) — PortableTextMeasurer is what actually runs,
    // exactly like a real headless-Core or pre-T09 mount. The column's own explicit width is
    // what the leaf's cross constraint is actually bound by (via `availableSpace`), not
    // whatever `measureContainer`'s own top-level `constraint:` argument happens to be.
    let text = String(repeating: "word ", count: 40)

    func height(forColumnWidth width: Double) throws -> Double {
        let node = TextNode(text: text)
        let root = Node()
        root.style.flexDirection = .column
        root.style.width = .points(width)
        root.addSubnode(node)
        return try FlexboxEngine.measureContainer(input: root.makeLayoutInputSnapshot()).parentSize
            .height
    }

    let narrow = try height(forColumnWidth: 120)
    let wide = try height(forColumnWidth: 800)

    #expect(narrow > wide)
}
